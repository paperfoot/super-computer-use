// AX layer: tree walking, addressing, settle, cursor, windows.

import Cocoa
import ApplicationServices
import CryptoKit
import Carbon.HIToolbox

// MARK: - AX primitives

func axAttr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}
func axStr(_ e: AXUIElement, _ n: String) -> String? {
    guard let v = axAttr(e, n) else { return nil }
    if let s = v as? String { return s }
    if let num = v as? NSNumber { return num.stringValue }
    return nil
}
func axBool(_ e: AXUIElement, _ n: String) -> Bool? { (axAttr(e, n) as? NSNumber)?.boolValue }
func axPoint(_ e: AXUIElement) -> CGPoint? {
    guard let v = axAttr(e, kAXPositionAttribute as String) else { return nil }
    var p = CGPoint.zero; AXValueGetValue(v as! AXValue, .cgPoint, &p); return p
}
func axSize(_ e: AXUIElement) -> CGSize? {
    guard let v = axAttr(e, kAXSizeAttribute as String) else { return nil }
    var s = CGSize.zero; AXValueGetValue(v as! AXValue, .cgSize, &s); return s
}
func axActions(_ e: AXUIElement) -> [String] {
    var n: CFArray?
    guard AXUIElementCopyActionNames(e, &n) == .success, let l = n as? [String] else { return [] }
    return l
}

struct Node {
    let el: AXUIElement
    let index: Int
    let role: String
    let ident: String
    let title: String
    let value: String
    let desc: String
    let pos: CGPoint?
    let size: CGSize?
    let path: String        // child-index path from the app root, e.g. "0.3.2.7"
    let actionable: Bool
    let window: String      // owning window's title, or its index when untitled
    /// AX action names, captured during the walk. Re-reading them per render costs a second
    /// IPC round-trip on every node, and `--actions` over a 4000-node tree pays it for all
    /// of them.
    var actions: [String] = []

    var text: String { [title, value, desc].filter { !$0.isEmpty }.joined(separator: " | ") }

    /// Stable handle that survives both reflow and content edits.
    ///
    /// AXValue is deliberately excluded from the identity key: typing into a field would
    /// otherwise change that field's own ref, so a script could never write to the same
    /// element twice. Identity comes from developer-assigned attributes (AXIdentifier,
    /// title, description) which persist across edits. Only when an element exposes none
    /// of those do we fall back to its tree path.
    var ref: String {
        // The owning window is part of the identity. Without it, two documents in the same
        // app produce identical refs — both TextEdit windows expose an AXTextArea with the
        // same role, identifier and (empty) title — and every ref lookup becomes ambiguous.
        var key = "\(window)|\(role)|\(ident)|\(title)|\(desc)"
        if ident.isEmpty && title.isEmpty && desc.isEmpty {
            // Value-only elements (static text) are identified by their content;
            // structural ones by position in the tree.
            key += value.isEmpty ? "|path:\(path)" : "|val:\(value.prefix(60))"
        }
        return "\(role.replacingOccurrences(of: "AX", with: ""))#\(shortHash(key))"
    }
    var centre: CGPoint? {
        guard let p = pos, let s = size, s.width > 0, s.height > 0 else { return nil }
        return CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
    }
    /// Short caption for the agent-cursor badge.
    var label: String {
        text.isEmpty ? role.replacingOccurrences(of: "AX", with: "") : String(text.prefix(26))
    }
}

/// Walk the AX tree in a fixed pre-order so indices are reproducible within a state.
/// Menu bars are skipped by default: Recent Items alone can be hundreds of nodes and
/// would exhaust the budget before reaching the window.
/// Attributes fetched per node, in one IPC round-trip instead of six.
/// Measured on a 738-node Chrome tree: 183ms one-at-a-time vs 55ms batched (3.3x).
private let bulkAttrs = [kAXRoleAttribute, kAXTitleAttribute, kAXValueAttribute,
                         kAXDescriptionAttribute, "AXIdentifier" as CFString,
                         kAXPositionAttribute, kAXSizeAttribute] as CFArray

private func bulkRead(_ e: AXUIElement) -> (role: String, title: String, value: String,
                                            desc: String, ident: String, pos: CGPoint?, size: CGSize?) {
    var out: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(e, bulkAttrs,
            AXCopyMultipleAttributeOptions(rawValue: 0), &out) == .success,
          let vals = out as? [Any], vals.count >= 7 else {
        // Fall back to individual reads if the app rejects the bulk call.
        return (axStr(e, kAXRoleAttribute as String) ?? "?",
                axStr(e, kAXTitleAttribute as String) ?? "",
                axStr(e, kAXValueAttribute as String) ?? "",
                axStr(e, kAXDescriptionAttribute as String) ?? "",
                axStr(e, "AXIdentifier") ?? "", axPoint(e), axSize(e))
    }
    func s(_ i: Int) -> String {
        if let str = vals[i] as? String { return str }
        if let n = vals[i] as? NSNumber { return n.stringValue }
        return ""
    }
    var p: CGPoint? = nil, sz: CGSize? = nil
    if CFGetTypeID(vals[5] as CFTypeRef) == AXValueGetTypeID() {
        var q = CGPoint.zero
        if AXValueGetValue(vals[5] as! AXValue, .cgPoint, &q) { p = q }
    }
    if CFGetTypeID(vals[6] as CFTypeRef) == AXValueGetTypeID() {
        var q = CGSize.zero
        if AXValueGetValue(vals[6] as! AXValue, .cgSize, &q) { sz = q }
    }
    return (s(0).isEmpty ? "?" : s(0), s(1), s(2), s(3), s(4), p, sz)
}

/// Set by the most recent walk when it stopped short of the whole tree — the node budget ran
/// out, or a real subtree continued below maxDepth. Read it straight after a walk: anything
/// that reports on what the tree contains has to be able to say when it saw only part of it.
private(set) var lastWalkTruncated = false

func collectNodes(pid: pid_t, maxDepth: Int = 18, maxNodes: Int = 4000,
                  includeMenus: Bool = false, windowFilter: CGWindowID? = nil) -> [Node] {
    var out: [Node] = []
    var truncated = false
    // Tracks which window the walk is currently inside, so refs can be scoped to it.
    var currentWindow = ""
    // The elements on the current recursion path, for cycle detection. Observed live:
    // Finder's AXApplication lists *itself* as its own first child, so an undefended walk
    // re-enters the app once per level and burns the whole node budget emitting the same
    // node — a tree of 6000 duplicates returned as a success. Comparing against ancestors
    // only (not everything seen) leaves legitimate repeated siblings alone.
    var ancestors: [AXUIElement] = []
    func walk(_ e: AXUIElement, _ depth: Int, _ path: String) {
        if depth > maxDepth || out.count >= maxNodes { truncated = true; return }
        if ancestors.contains(where: { CFEqual($0, e) }) { return }
        ancestors.append(e)
        defer { ancestors.removeLast() }
        let a = bulkRead(e)
        let role = a.role
        if !includeMenus, role == "AXMenuBar" || role == "AXMenuBarItem" { return }
        let title = a.title, value = a.value, desc = a.desc
        // Entering a window scopes every descendant's ref to it, and leaving restores the
        // outer scope. Without the restore, everything walked after a window subtree — the
        // whole menu bar in apps that list windows first, every sibling after a sheet — is
        // keyed to a window it does not belong to, so closing that window silently
        // invalidates refs it never contained.
        let enclosing = currentWindow
        defer { currentWindow = enclosing }
        if role == "AXWindow" || role == "AXSheet" || role == "AXDrawer" {
            currentWindow = title.isEmpty ? "win:\(path)" : title
        }
        let acts = axActions(e)
        // Index anything with text OR anything interactive: an empty text field carries
        // no text but must still be targetable.
        if !title.isEmpty || !value.isEmpty || !desc.isEmpty || !acts.isEmpty {
            out.append(Node(el: e, index: out.count, role: role, ident: a.ident,
                            title: title, value: value, desc: desc,
                            pos: a.pos, size: a.size, path: path,
                            actionable: !acts.isEmpty, window: currentWindow, actions: acts))
        }
        if let kids = axAttr(e, kAXChildrenAttribute as String) as? [AXUIElement] {
            for (i, k) in kids.enumerated() { walk(k, depth + 1, path.isEmpty ? "\(i)" : "\(path).\(i)") }
        }
    }
    let app = AXUIElementCreateApplication(pid)
    unlockAccessibility(app, force: flag("enhanced"))
    walk(app, 0, "")
    lastWalkTruncated = truncated
    return out
}

/// Processes we've already tried to unlock this run.
private var unlockedPids = Set<pid_t>()

/// What each unlock attribute held before we wrote it, so exit can put it back.
private var unlockRestores: [(app: AXUIElement, attr: String, prior: CFTypeRef?)] = []
private var unlockRestoreArmed = false

/// Hand every app we touched back in the state we found it in.
///
/// Registered with atexit, which exit() runs — and emit()/fail() both end in exit(), so
/// there is no path where a read-only `axdump` leaves an app permanently in enhanced
/// accessibility mode. That flip changes how some apps render, and nobody asked for it.
private func restoreUnlockAttributes() {
    for r in unlockRestores {
        let prior: CFTypeRef = r.prior ?? kCFBooleanFalse
        _ = AXUIElementSetAttributeValue(r.app, r.attr as CFString, prior)
    }
    unlockRestores.removeAll()
}

/// Turn one unlock attribute on, remembering what it held first.
///
/// `on` says the attribute is now set, `changed` says this call is what set it. An app that
/// already had it — a VoiceOver user, or another tool — is left alone: it costs no settle
/// and, crucially, is not turned back off on our way out.
private func setUnlockAttribute(_ app: AXUIElement, _ attr: String) -> (on: Bool, changed: Bool) {
    let prior = axAttr(app, attr)
    if (prior as? NSNumber)?.boolValue == true { return (true, false) }
    // The status of this write is not evidence that it did nothing. Both attributes are
    // side channels AppKit intercepts rather than real attributes, and a write that takes
    // effect still answers kAXErrorNotImplemented (-25208) — measured against a running app,
    // where the value read back true immediately afterwards. Requiring .success here meant
    // the undo was never recorded, so every "read-only" dump left the app flipped for good,
    // and the unlock never got its settle either. kAXErrorAttributeUnsupported is the one
    // honest answer: the app has no such attribute, so nothing was written to put back.
    let err = AXUIElementSetAttributeValue(app, attr as CFString, kCFBooleanTrue)
    if err == .attributeUnsupported { return (false, false) }
    unlockRestores.append((app, attr, prior))
    if !unlockRestoreArmed {
        unlockRestoreArmed = true
        atexit { restoreUnlockAttributes() }
    }
    // Chromium publishes AXManualAccessibility write-only, so an unreadable attribute is
    // not proof of failure — but it is not proof of success either, and reporting `on`
    // optimistically would skip the AXEnhancedUserInterface fallback those apps still need.
    return (on: (axAttr(app, attr) as? NSNumber)?.boolValue == true, changed: true)
}

/// Ask an app to publish a full accessibility tree.
///
/// Chromium and Electron apps (Slack, VS Code, Discord) ship a title-bar-only tree until
/// `AXManualAccessibility` is set; some Catalyst and iWork apps want
/// `AXEnhancedUserInterface` instead. Both are no-ops returning
/// kAXErrorAttributeUnsupported (-25205) on apps that don't recognise them, so setting
/// them costs one call and can be the difference between 50 nodes and a full tree.
func unlockAccessibility(_ app: AXUIElement, force: Bool = false) {
    var appPid: pid_t = 0
    AXUIElementGetPid(app, &appPid)
    // Once per app per process, --enhanced included. A single action walks the tree half a
    // dozen times, and forcing the write on every walk re-paid the 250ms settle each time.
    if unlockedPids.contains(appPid) { return }
    unlockedPids.insert(appPid)

    let manual = setUnlockAttribute(app, "AXManualAccessibility")
    var enhanced = (on: false, changed: false)
    if !manual.on || force {
        enhanced = setUnlockAttribute(app, "AXEnhancedUserInterface")
    }
    // Only pay the settle cost when something actually changed.
    if manual.changed || enhanced.changed { usleep(250_000) }
}

// MARK: - actionability
//
// Playwright refuses to click until an element is visible, stable, enabled and able to
// receive the event. AX will happily "succeed" on a disabled or zero-size element and
// change nothing, which reads to an agent as a working click. These checks turn that
// silent no-op into an error with a fix.

struct Actionability {
    let ok: Bool
    let code: String
    let reason: String
    let fix: String
    /// Most refusals describe a UI state that will clear, so exit 1 (retry) is right. A
    /// secure text field is not one of them: no wait and no different argument changes it,
    /// and an agent honouring retry-on-1 would loop on the refusal forever.
    var exit: Exit = .transient
}

/// A password field, by role or subrole.
///
/// Checked on its own rather than only through `checkActionable`, whose earlier
/// disabled/hidden/zero-size returns mask it: a secure field with a zero AX frame is exactly
/// what a browser publishes for an off-screen password input, and that path let `--no-check`
/// carry a write into one.
func isSecureField(_ n: Node) -> Bool {
    let sub = axStr(n.el, kAXSubroleAttribute as String) ?? ""
    return n.role == "AXSecureTextField" || sub == "AXSecureTextField"
}

func checkActionable(_ n: Node, pid: pid_t, forTyping: Bool = false) -> Actionability {
    if axBool(n.el, "AXEnabled") == false {
        return Actionability(ok: false, code: "element_disabled",
            reason: "\(n.role) '\(n.label)' is disabled",
            fix: "Whatever enables it has not happened yet. Use `scu waitfor` on the precondition, then retry.")
    }
    if axBool(n.el, kAXHiddenAttribute as String) == true {
        return Actionability(ok: false, code: "element_hidden",
            reason: "\(n.role) '\(n.label)' is marked hidden",
            fix: "Reveal it first — expand its container or scroll it into view — then re-run `scu find`.")
    }
    // Zero-size elements are usually collapsed rows or off-screen virtual cells; AXPress
    // on them reports success and does nothing.
    if let s = n.size, s.width <= 1 || s.height <= 1 {
        // A closed menu reports all its items at 0x0; scrolling would not help there,
        // so give the fix that matches the element rather than a generic one.
        let isMenu = n.role.hasPrefix("AXMenu")
        return Actionability(ok: false, code: "element_not_visible",
            reason: "\(n.role) '\(n.label)' has no on-screen size (\(Int(s.width))x\(Int(s.height)))",
            fix: isMenu
                ? "Items in a closed menu report 0x0. Note that menu commands routed through the "
                + "first responder do nothing in a background app — prefer a direct action such as "
                + "`scu setvalue`, or pass --no-check to try anyway and read \"changed\"."
                : "Scroll it into view with `scu scroll`, or target a visible ancestor from `scu axdump`.")
    }
    if forTyping {
        // Refuse to push keystrokes at a password field. Secure input also blocks the
        // events at the OS level, so this would fail anyway — but silently.
        if isSecureField(n) {
            return Actionability(ok: false, code: "secure_field",
                reason: "\(n.label.isEmpty ? "This field" : n.label) is a secure text field",
                fix: "Type the password yourself. Secure input deliberately blocks synthetic keystrokes.",
                exit: .config)
        }
    }
    return Actionability(ok: true, code: "", reason: "", fix: "")
}

/// True once a fingerprint walk has been truncated, i.e. `changed` was decided from part of
/// the tree rather than all of it.
private(set) var fingerprintPartial = false

/// Fingerprint of the tree an action can reach, used to tell whether the action changed
/// anything.
///
/// `changed` is this tool's whole answer to silent success, so it walks the budget `axdump`
/// walks rather than settle's cheap poll sample. The old depth-10/220-node sample hid 88% of
/// a Chrome tree and every row of a Finder file list, so a click that genuinely mutated the
/// UI reported changed:false and an agent following the contract did it a second time.
func changeFingerprint(_ pid: pid_t) -> String {
    // The axdump budget, and never less: a caller who widened --depth/--max to reach a deep
    // element widens this too, because that element is exactly what has to be compared.
    let nodes = collectNodes(pid: pid, maxDepth: max(16, intOpt("depth", 16)),
                             maxNodes: max(4000, intOpt("max", 4000)), includeMenus: true)
    if lastWalkTruncated { fingerprintPartial = true }
    var s = ""
    for n in nodes {
        // Whole text, not a prefix: an edit past character 40 of a document is exactly the
        // mutation the caller is asking about.
        s += "\(n.role)|\(n.ident)|\(n.text)|"
        if let p = n.pos { s += "\(Int(p.x)),\(Int(p.y))" }
        if let z = n.size { s += " \(Int(z.width))x\(Int(z.height))" }
        s += "\n"
    }
    return shortHash(s)
}

/// Coverage caveat for the action envelope. A truncated fingerprint walk means changed:false
/// can still be a false negative, so say so rather than let the caller assume the whole tree
/// was compared.
func changeCoverageFields() -> [(String, Any)] {
    [("changedCoverage", fingerprintPartial ? "partial" : "full")]
}

/// Whether the login session's screen is locked.
///
/// A locked screen does not stop AX calls from succeeding — it stops apps publishing a real
/// tree. Every symptom then points at the app: an empty dump, a `no_ax_tree` error, a
/// suggestion to retry with `--enhanced`. None of that is true or actionable, and `doctor`
/// reports healthy throughout. Verified live on a locked Mac, where TextEdit exposed a
/// window and no tree.
func screenIsLocked() -> Bool {
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    if let n = d["CGSSessionScreenIsLocked"] as? NSNumber { return n.boolValue }
    return false
}

/// One budget for every walk whose numbering an agent can see.
///
/// `[N]` printed by axdump has to address the same element when it comes back as `--index`,
/// so the producing and the consuming walk must be the same walk. They were 16/4000 and
/// 20/6000: an index copied straight out of a dump pressed a different control, and the
/// index_out_of_range error quoted a bound from a tree the caller had never been shown.
func treeBudget() -> (depth: Int, max: Int) {
    (intOpt("depth", 20), intOpt("max", 6000))
}

func requirePid() -> pid_t {
    let pid = resolvePid()
    enforceTargetPolicy(pid)
    return pid
}

private func resolvePid() -> pid_t {
    // A supplied-but-unparseable value must not fall through to "--pid or --app required":
    // that tells the caller a flag is missing when it is right there in argv, and an agent
    // following it re-sends the same malformed value forever.
    if let s = opt("pid") {
        guard let p = pid_t(s) else {
            fail("bad_args", "--pid must be a process id, not '\(s)'",
                 "Run `scu apps` to list running apps with their pids, or target by name with --app.",
                 .input)
        }
        // Liveness is deliberately NOT checked here: a malformed --timeout is the caller's
        // mistake either way, and resolving the target first would report a dead pid instead
        // of the argument error they can actually fix. diagnoseEmptyTree does the check, at
        // the point where an absent tree would otherwise be blamed on a live app.
        return p
    }
    // Convenience: --app resolves a display name to a running pid.
    if let name = opt("app") {
        let needle = name.lowercased()
        // Every string contains the empty string, so an empty --app matched the first
        // background daemon NSWorkspace happened to list.
        guard !needle.isEmpty else {
            fail("bad_args", "--app was given an empty name",
                 "Pass the app's display name, e.g. --app Finder. Run `scu apps` to list them.", .input)
        }
        let running = NSWorkspace.shared.runningApplications
        // Exact name or bundle id wins; fall back to a substring match.
        var hit = running.first { app -> Bool in
            let n = (app.localizedName ?? "").lowercased()
            let b = (app.bundleIdentifier ?? "").lowercased()
            return n == needle || b == needle
        }
        if hit == nil {
            hit = running.first { app -> Bool in
                (app.localizedName ?? "").lowercased().contains(needle)
            }
        }
        if let h = hit { return h.processIdentifier }
        fail("app_not_running", "no running app matches \(name)", "Run `scu apps` to list running apps, or `scu launch --app NAME` to start it.", .input)
    }
    fail("bad_args", "--pid or --app required", "Run `scu help` for the command reference, or `scu agent-info` for the machine-readable manifest.", .input)
}

/// Reasons a target could not be resolved. Kept separate from `die` so `batch` can
/// report which steps already succeeded instead of exiting mid-script.
struct ResolveError: Error { let code: String; let message: String }

/// Recovery instruction for each resolver failure. Agents follow these literally, so
/// they name the exact command to run rather than describing a direction.
func resolveSuggestion(_ code: String) -> String {
    switch code {
    case "stale_ref":        return "Re-run `scu find` or `scu axdump` and use the fresh ref."
    case "ambiguous_ref":    return "Pass --path with one of the listed candidates, or use --query with nth=."
    case "no_match":         return "Run `scu axdump` to see available elements, then widen the query."
    case "ambiguous_query":  return "Add nth=N to pick one, or add role=/id= to narrow the query."
    case "nth_out_of_range": return "Lower nth, or drop it to see how many elements matched."
    case "bad_query":        return "Valid clauses are role=, id=, title=, text~= (contains), "
                                  + "text== (exact), win=, nth=N and actionable. Note there is no bare `text=`."
    default:                 return "Run `scu axdump` for current state, then retry."
    }
}

/// Semantic selector: `role=AXButton;text~=Send;nth=0`.
///
/// Preferred over refs in scripts a human will read or re-run later — a query says what
/// it means, survives app updates that shuffle hashes, and is portable between machines.
/// Supported keys: role, id (AXIdentifier), text~= (contains), text== (exact),
/// title, nth (0-based pick among matches), actionable.
struct Query {
    var role: String?, ident: String?, contains: String?, exact: String?
    var title: String?, nth: Int?, actionableOnly = false
    /// Restrict matches to one window, by title substring. Essential for multi-window
    /// apps where every document exposes an identically-shaped element.
    var window: String?
    /// Clauses whose key we do not recognise, kept so the resolver can refuse the query.
    /// Dropped silently, `text=Send` (one character off `text~=Send`) resolved against
    /// `role=` alone and pressed whatever that matched, reporting ok:true.
    var unknown: [String] = []

    init(_ s: String) {
        for clause in s.split(separator: ";") {
            let c = clause.trimmingCharacters(in: .whitespaces)
            if c.isEmpty { continue }
            func rhs(_ sep: String) -> String? {
                guard let r = c.range(of: sep) else { return nil }
                return String(c[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if c.hasPrefix("role=") { role = rhs("=") }
            else if c.hasPrefix("id=") { ident = rhs("=") }
            else if c.hasPrefix("text~=") { contains = rhs("~=")?.lowercased() }
            else if c.hasPrefix("text==") { exact = rhs("==") }
            else if c.hasPrefix("title=") { title = rhs("=") }
            else if c.hasPrefix("win=") { window = rhs("=")?.lowercased() }
            else if c.hasPrefix("nth=") {
                // A non-numeric nth left the pick unset and turned an error into a
                // silent "any match will do".
                guard let n = Int(rhs("=") ?? "") else { unknown.append(c); continue }
                nth = n
            }
            else if c == "actionable" { actionableOnly = true }
            else { unknown.append(c) }
        }
    }

    func matches(_ n: Node) -> Bool {
        if let r = role, n.role != r, n.role != "AX" + r { return false }
        if let i = ident, n.ident != i { return false }
        if let t = title, n.title != t { return false }
        if let w = window, !n.window.lowercased().contains(w) { return false }
        if let c = contains, !n.text.lowercased().contains(c) { return false }
        if let e = exact, n.text != e { return false }
        if actionableOnly && !n.actionable { return false }
        return true
    }
}

func resolveQuery(_ pid: pid_t, _ spec: String) throws -> Node {
    let q = Query(spec)
    if !q.unknown.isEmpty {
        throw ResolveError(code: "bad_query",
            message: "query '\(spec)' has unrecognised clause(s): \(q.unknown.joined(separator: "; "))")
    }
    let b = treeBudget()
    let nodes = collectNodes(pid: pid, maxDepth: b.depth,
                             maxNodes: b.max, includeMenus: flag("menus"))
    let hits = nodes.filter { q.matches($0) }
    if hits.isEmpty {
        throw ResolveError(code: "no_match", message: "query '\(spec)' matched nothing")
    }
    if let n = q.nth {
        guard n >= 0 && n < hits.count else {
            throw ResolveError(code: "nth_out_of_range", message: "nth=\(n) but only \(hits.count) matches")
        }
        return hits[n]
    }
    if hits.count > 1 {
        throw ResolveError(code: "ambiguous_query",
            message: "query '\(spec)' matched \(hits.count) elements — add nth=N or narrow it (first: \(hits.prefix(3).map { $0.label }.joined(separator: " / ")))")
    }
    return hits[0]
}

func resolveNodeThrowing(_ pid: pid_t, ref: String) throws -> Node {
    let b = treeBudget()
    let nodes = collectNodes(pid: pid, maxDepth: b.depth,
                             maxNodes: b.max, includeMenus: flag("menus"))
    let hits = nodes.filter { $0.ref == ref }
    if hits.isEmpty {
        throw ResolveError(code: "stale_ref",
            message: "ref \(ref) no longer present — re-run find/axdump for current state")
    }
    if hits.count > 1 {
        if let p = opt("path"), let exact = hits.first(where: { $0.path == p }) { return exact }
        throw ResolveError(code: "ambiguous_ref",
            message: "\(hits.count) elements match \(ref) — pass --path (candidates: \(hits.prefix(4).map { $0.path }.joined(separator: ",")))")
    }
    return hits[0]
}

/// Turn a resolver throw into the CLI error contract. One place, so the same dead ref
/// reports the same message, the same suggestion and the same exit code whether it came
/// from `scu click --ref` or from a batch step.
func failResolve(_ error: Error) -> Never {
    if let e = error as? ResolveError {
        fail(e.code, e.message, resolveSuggestion(e.code), .input)
    }
    fail("unknown", "\(error)",
         "Re-run with --json for the structured error, then check `scu doctor`.", .transient)
}

/// Resolve a target from --query (portable), --ref (survives reflow) or --index (positional).
func resolveNode(_ pid: pid_t, refOverride: String? = nil, indexOverride: Int? = nil) -> Node {
    if let q = opt("query") {
        do { return try resolveQuery(pid, q) } catch { failResolve(error) }
    }
    if let r = refOverride ?? opt("ref") {
        do { return try resolveNodeThrowing(pid, ref: r) } catch { failResolve(error) }
    }
    if indexOverride == nil, let s = opt("index"), Int(s) == nil {
        fail("bad_args", "--index must be a whole number, not '\(s)'",
             "Run `scu axdump` and use the number in the leading [N], or prefer --query.", .input)
    }
    guard let idx = indexOverride ?? Int(opt("index") ?? "") else {
        // Name every addressing mode this resolver actually accepts, in the order the docs
        // recommend them. Omitting --query sent the caller to the two forms the same docs
        // tell them to avoid.
        fail("bad_args", "--query (preferred), --ref or --index required",
             "Example: --query 'role=AXButton;text~=Send;nth=0'. Run `scu find` for a ref, "
             + "or `scu help` for the command reference.", .input)
    }
    let b = treeBudget()
    let nodes = collectNodes(pid: pid, maxDepth: b.depth,
                             maxNodes: b.max, includeMenus: flag("menus"))
    guard idx >= 0 && idx < nodes.count else {
        fail("index_out_of_range", "index \(idx) not in 0..<\(nodes.count) — UI likely changed; re-dump", "The tree changed. Re-run `scu axdump` and use a current index, or switch to --query.", .input)
    }
    return nodes[idx]
}

// MARK: - settle
//
// A short-lived CLI cannot keep an AXObserver run loop alive across invocations, so we
// poll a cheap signature instead. Two identical consecutive samples means the UI has
// stopped moving. A visible progress indicator forces us to keep waiting.

/// Deliberately cheap and deliberately bounded: settle samples this in a loop, so it trades
/// coverage for speed. `changed` does not — see changeFingerprint.
func treeSignature(_ pid: pid_t) -> String {
    let nodes = collectNodes(pid: pid, maxDepth: 10, maxNodes: 220)
    var s = ""
    for n in nodes {
        s += n.role
        s += n.text.prefix(40)
        if let p = n.pos { s += "\(Int(p.x)),\(Int(p.y))" }
    }
    return shortHash(s)
}

func isBusy(_ pid: pid_t) -> Bool {
    for n in collectNodes(pid: pid, maxDepth: 12, maxNodes: 400) {
        if n.role == "AXProgressIndicator", let s = n.size, s.width > 1 { return true }
        if axBool(n.el, "AXElementBusy") == true { return true }
    }
    return false
}

/// AX notifications that indicate the UI is still changing. Registering for these lets us
/// wait on a push signal instead of re-walking the tree on a timer.
private let settleNotifications: [String] = [
    kAXValueChangedNotification as String,
    kAXTitleChangedNotification as String,
    kAXLayoutChangedNotification as String,
    kAXFocusedUIElementChangedNotification as String,
    kAXFocusedWindowChangedNotification as String,
    kAXWindowCreatedNotification as String,
    kAXUIElementDestroyedNotification as String,
    kAXCreatedNotification as String,
    kAXSheetCreatedNotification as String,
    kAXMenuOpenedNotification as String,
    kAXMenuClosedNotification as String,
    kAXRowCountChangedNotification as String,
    kAXSelectedChildrenChangedNotification as String,
    "AXElementBusyChanged",
]

/// Timestamp of the most recent AX notification, written from the observer callback.
private var lastAXEvent = Date.distantPast

/// Observer-based settle: block until the app stops emitting AX notifications for a
/// quiet period, then confirm nothing is still marked busy.
///
/// This beats polling on both accuracy and cost — a 110ms poll loop re-walks the whole
/// tree (~35ms each) and can still miss a change that lands between samples, whereas the
/// observer sees every event. Falls back to polling if the app refuses an observer.
private func settleByObserver(_ pid: pid_t, quietMs: Int, capMs: Int) -> (Bool, Int)? {
    var observer: AXObserver?
    let cb: AXObserverCallback = { _, _, _, _ in lastAXEvent = Date() }
    guard AXObserverCreate(pid, cb, &observer) == .success, let obs = observer else { return nil }

    let app = AXUIElementCreateApplication(pid)
    var registered = 0
    for n in settleNotifications {
        if AXObserverAddNotification(obs, app, n as CFString, nil) == .success { registered += 1 }
    }
    // No notifications accepted means this app won't tell us anything; use the fallback.
    guard registered > 0 else { return nil }

    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
    defer {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        for n in settleNotifications { AXObserverRemoveNotification(obs, app, n as CFString) }
    }

    let start = Date()
    lastAXEvent = Date()
    let quiet = Double(quietMs) / 1000.0
    while Date().timeIntervalSince(start) * 1000 < Double(capMs) {
        // Pump the run loop briefly so the callback can fire.
        CFRunLoopRunInMode(.defaultMode, 0.05, true)
        if Date().timeIntervalSince(lastAXEvent) >= quiet {
            if !isBusy(pid) { return (true, Int(Date().timeIntervalSince(start) * 1000)) }
            lastAXEvent = Date()   // still busy: keep waiting
        }
    }
    return (false, capMs)
}

/// A millisecond argument, checked before it can reach usleep or a UInt32 conversion.
/// `--wait 9000000` used to trap on the conversion, and a trap exits 133 with nothing on
/// either stream — outside the 0-4 contract an agent branches on.
private func settleMs(_ name: String, _ raw: String) -> Int {
    guard let n = Int(raw), n >= 0, n <= 3_600_000 else {
        fail("bad_args",
             "--\(name) takes whole milliseconds from 0 to 3600000, not '\(raw)'",
             // The auto-settle hint belongs only to --wait: suggesting it to someone who is
             // already in auto mode and mistyped --quiet-ms names a switch they have on.
             "Pass a number of milliseconds, e.g. --\(name) 500."
             + (name == "wait" ? " `--wait auto` observes the app instead of sleeping for a "
                               + "fixed time." : ""), .input)
    }
    return n
}

/// Returns (settled, elapsedMs). `--wait N` forces a fixed sleep; `--wait auto` (default)
/// observes. `--wait 0` skips entirely.
@discardableResult
func settle(_ pid: pid_t) -> (Bool, Int) {
    let spec = opt("wait") ?? "auto"
    if spec != "auto" {
        let fixed = settleMs("wait", spec)
        if fixed > 0 { usleep(UInt32(fixed) * 1000) }
        return (true, fixed)
    }
    let cap = settleMs("wait-max", opt("wait-max") ?? "5000")
    // --quiet-ms, not --quiet: --quiet is the global boolean that suppresses human output,
    // and reading the settle period from it meant tuning the wait blanked the result.
    let quiet = settleMs("quiet-ms", opt("quiet-ms") ?? "250")
    if let r = settleByObserver(pid, quietMs: quiet, capMs: cap) { return r }

    // Fallback: poll a cheap tree signature until it stops changing.
    let start = Date()
    var last = ""
    var stable = 0
    while Int(Date().timeIntervalSince(start) * 1000) < cap {
        let sig = treeSignature(pid)
        if sig == last {
            stable += 1
            if stable >= 2 && !isBusy(pid) {
                return (true, Int(Date().timeIntervalSince(start) * 1000))
            }
        } else {
            stable = 0
            last = sig
        }
        usleep(110_000)
    }
    return (false, cap)
}

// MARK: - agent cursor
//
// Click-through, non-activating overlay drawn at the action point. The user's real
// pointer never moves, so this is the only way for them to see what is being touched.

final class CursorView: NSView {
    var label = ""
    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let teal = NSColor(calibratedRed: 0, green: 0.78, blue: 0.72, alpha: 1)
        ctx.setFillColor(teal.withAlphaComponent(0.18).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 34, y: c.y - 34, width: 68, height: 68))
        ctx.setStrokeColor(teal.withAlphaComponent(0.95).cgColor); ctx.setLineWidth(3)
        ctx.strokeEllipse(in: CGRect(x: c.x - 20, y: c.y - 20, width: 40, height: 40))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: CGRect(x: c.x - 21.5, y: c.y - 21.5, width: 43, height: 43))
        ctx.setFillColor(teal.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
        ctx.setStrokeColor(teal.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(2)
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
            ctx.move(to: CGPoint(x: c.x + dx * 24, y: c.y + dy * 24))
            ctx.addLine(to: CGPoint(x: c.x + dx * 32, y: c.y + dy * 32))
        }
        ctx.strokePath()
        guard !label.isEmpty else { return }
        let t = NSAttributedString(string: " \(label) ", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let sz = t.size()
        let box = CGRect(x: c.x - sz.width / 2, y: c.y + 38, width: sz.width, height: sz.height + 3)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        t.draw(at: CGPoint(x: box.minX, y: box.minY + 1))
    }
}

var cursorWindow: NSWindow?
/// Whether the visible cursor was faded in, so the fade-out matches it.
private var cursorFaded = true

/// `cg` is a global CoreGraphics point (top-left origin, as AX and CGWindowList report).
/// Cocoa windows are bottom-left origin and per-screen, so pick the screen that actually
/// contains the point — using screens.first breaks on secondary displays.
func showAgentCursor(at cg: CGPoint, label: String, hold: Double = 0.6) {
    NSApplication.shared.setActivationPolicy(.accessory)
    // Both coordinate spaces are anchored to the primary screen — CG at its top-left with
    // y growing downward, Cocoa at its bottom-left with y growing upward — so this single
    // flip is correct for points on any display, including negative coordinates.
    guard let primary = NSScreen.screens.first else { return }
    let cocoaY = primary.frame.maxY - cg.y
    let side: CGFloat = 160
    let frame = NSRect(x: cg.x - side / 2, y: cocoaY - side / 2, width: side, height: side)

    let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
    w.ignoresMouseEvents = true
    w.level = .screenSaver
    w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    let v = CursorView(frame: NSRect(origin: .zero, size: frame.size))
    v.label = label
    w.contentView = v
    w.alphaValue = 0
    w.orderFrontRegardless()
    cursorWindow = w
    // The 15 fade frames are ~150ms of blocking run loop on top of the hold, paid on every
    // flashed step of a batch. `--hold 0` asks for the cheapest possible flash, so it gets
    // one: appear, no dwell, no fade either end.
    cursorFaded = hold > 0
    guard cursorFaded else { w.alphaValue = 1; return }
    for i in 1...8 {
        w.alphaValue = CGFloat(i) / 8
        RunLoop.current.run(until: Date().addingTimeInterval(0.010))
    }
    RunLoop.current.run(until: Date().addingTimeInterval(hold))
}
func hideAgentCursor() {
    guard let w = cursorWindow else { return }
    if cursorFaded {
        for i in stride(from: 6, through: 0, by: -1) {
            w.alphaValue = CGFloat(i) / 6
            RunLoop.current.run(until: Date().addingTimeInterval(0.010))
        }
    }
    w.orderOut(nil); cursorWindow = nil
}

/// `--hold` in seconds. NaN, Inf and negatives all reach RunLoop.run(until:) as a nonsense
/// deadline, so they are refused rather than silently ignored.
func cursorHold(_ dflt: Double = 0.45) -> Double {
    guard let raw = opt("hold") else { return dflt }
    guard let h = Double(raw), h.isFinite, h >= 0, h <= 30 else {
        fail("bad_args", "--hold takes seconds from 0 to 30, not '\(raw)'",
             "Pass seconds, e.g. --hold 0.2, or --hold 0 for the fastest flash. "
             + "Use --no-cursor to suppress the overlay entirely.", .input)
    }
    return h
}

func flash(_ pt: CGPoint?, _ label: String) {
    guard !flag("no-cursor"), let p = pt else { return }
    showAgentCursor(at: p, label: label, hold: cursorHold())
}

// MARK: - windows

struct WinInfo {
    let id: CGWindowID, pid: pid_t, owner: String, name: String, rect: CGRect, layer: Int
}
func listWindows(all: Bool) -> [WinInfo] {
    let o: CGWindowListOption = all ? [.optionAll, .excludeDesktopElements]
                                    : [.optionOnScreenOnly, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(o, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return raw.compactMap { d in
        guard let id = d[kCGWindowNumber as String] as? CGWindowID,
              let pid = d[kCGWindowOwnerPID as String] as? pid_t,
              let bd = d[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bd as CFDictionary) else { return nil }
        if rect.width < 40 || rect.height < 40 { return nil }
        return WinInfo(id: id, pid: pid,
                       owner: d[kCGWindowOwnerName as String] as? String ?? "?",
                       name: d[kCGWindowName as String] as? String ?? "",
                       rect: rect, layer: d[kCGWindowLayer as String] as? Int ?? 0)
    }
}

// MARK: - tree cache (for --diff)

func cacheDir() -> URL {
    let u = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/scu", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
func cacheURL(_ pid: pid_t) -> URL { cacheDir().appendingPathComponent("\(pid).tree") }

func renderLine(_ n: Node, showActions: Bool) -> String {
    var loc = ""
    if let p = n.pos, let s = n.size { loc = " @\(Int(p.x)),\(Int(p.y)) \(Int(s.width))x\(Int(s.height))" }
    var acts = ""
    if showActions {
        let a = n.actions.filter { $0 != "AXShowMenu" }
        if !a.isEmpty { acts = " {\(a.map { $0.replacingOccurrences(of: "AX", with: "") }.joined(separator: ","))}" }
    }
    let id = n.ident.isEmpty ? "" : " #\(n.ident)"
    return "[\(n.index)] \(n.ref) \(n.role)\(id)\(loc)\(acts): \(n.text)"
}

// MARK: - safety boundaries
//
// The element preflight refuses to type into an AXSecureTextField, but `type` and `key`
// take no element, so they bypassed it entirely — the safe path and the raw input path had
// different guarantees. These checks close that, and add the two policy layers Sky
// enforces: a hard denylist for system security surfaces, and an opt-in gate for
// credential managers.

/// Bundle ids that must never be driven. Authenticating on someone's behalf, or dismissing
/// a system security prompt, is not a thing an agent should be able to do.
private let forbiddenBundles: Set<String> = [
    "com.apple.SecurityAgent",
    "com.apple.LocalAuthenticationRemoteService",
    "com.apple.UserNotificationCenter",
    "com.apple.systempreferences.PasswordsPane",
]

/// Credential stores. Reading them is plausible; driving them blind is not, so they
/// require an explicit --allow-high-risk on every invocation.
private let highRiskBundles: Set<String> = [
    "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword",
    "com.bitwarden.desktop", "com.dashlane.dashlanephonefinal",
    "com.lastpass.LastPass", "com.nordpass.macos", "me.proton.pass.electron",
    "com.apple.keychainaccess",
]

/// The policy itself, addressed by bundle id.
///
/// Split out from enforceTargetPolicy because not every entry point has a pid to check:
/// `shot` captures a window it never resolves an app for, and `launch` decides whether to
/// start something that is not running yet. Both need this same denylist.
func enforceBundlePolicy(_ bundle: String, _ name: String) {
    if forbiddenBundles.contains(bundle) {
        fail("forbidden_target", "\(name) is a system security surface",
             "Authentication prompts and security dialogs must be handled by you directly. "
             + "There is no override for this.", .config)
    }
    if highRiskBundles.contains(bundle) && !flag("allow-high-risk") {
        fail("high_risk_target", "\(name) is a credential manager",
             "Pass --allow-high-risk if you genuinely intend to drive it, and never let "
             + "on-screen text decide to do so.", .config)
    }
}

/// Refuse targets that should never be automated, before anything is read or pressed.
func enforceTargetPolicy(_ pid: pid_t) {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return }
    enforceBundlePolicy(app.bundleIdentifier ?? "", app.localizedName ?? "that app")
}

/// Block synthetic keystrokes while macOS has secure input engaged.
///
/// While a password field is focused anywhere on the system, the OS drops synthetic key
/// events. Without this check `type` reports success and silently sends nothing — and in
/// the worse case the caller believes a credential was entered.
///
/// Returns the refusal instead of exiting: a guard that called fail() directly killed a
/// `batch` mid-script with no failedStep/completedSteps envelope, so the caller could not
/// tell which earlier steps had already mutated the app. The caller decides how to raise it.
func enforceSecureInput(_ what: String) -> CLIError? {
    guard IsSecureEventInputEnabled() else { return nil }
    return CLIError("secure_input_active", "macOS secure input is active, so \(what) cannot be delivered",
                    "A password field has focus somewhere on the system. Dismiss it, then retry. "
                    + "Type credentials yourself — synthetic input is deliberately blocked here.", .transient)
}

/// The element that currently has keyboard focus, which is where `type` will land.
func focusedElement(_ pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    guard let f = axAttr(app, kAXFocusedUIElementAttribute as String) else { return nil }
    return (f as! AXUIElement)
}

/// Refuse to push keystrokes at a password field even when no element was named.
/// Returns the refusal rather than exiting, for the same reason as enforceSecureInput.
func enforceFocusedFieldSafety(_ pid: pid_t) -> CLIError? {
    guard let f = focusedElement(pid) else { return nil }
    let role = axStr(f, kAXRoleAttribute as String) ?? ""
    let sub = axStr(f, kAXSubroleAttribute as String) ?? ""
    guard role == "AXSecureTextField" || sub == "AXSecureTextField" else { return nil }
    return CLIError("secure_field", "The focused element is a secure text field",
                    "Type the password yourself. Synthetic keystrokes into password fields are refused.",
                    .config)
}

// MARK: - context beyond the tree
//
// A flat role/title dump answers "what controls exist" but not "what is the user looking
// at". Sky returns focus, selection and document context as first-class fields; without
// them an agent has to guess which control it is about to act on.

/// Whatever currently holds keyboard focus, rendered for the dump header.
func focusSummary(_ pid: pid_t) -> String? {
    guard let f = focusedElement(pid) else { return nil }
    let role = axStr(f, kAXRoleAttribute as String) ?? "?"
    let label = [axStr(f, kAXTitleAttribute as String), axStr(f, kAXDescriptionAttribute as String)]
        .compactMap { $0 }.first { !$0.isEmpty } ?? ""
    let value = (axStr(f, kAXValueAttribute as String) ?? "").prefix(60)
    var line = "focus: \(role)"
    if !label.isEmpty { line += " '\(label)'" }
    if !value.isEmpty { line += " = \(value)" }
    if let sel = axStr(f, kAXSelectedTextAttribute as String), !sel.isEmpty {
        line += "  selected: '\(sel.prefix(60))'"
    }
    return line
}

/// First URL published in a window subtree. Browser windows otherwise look like any other
/// titled window, so an agent cannot tell which page it is operating on.
///
/// Breadth-first and budgeted. This runs on every axdump, and browsers publish AXURL on the
/// window or on its web area a level or two down — whereas a depth-first walk with only a
/// depth cap costs two AX round-trips per node all the way down, and on a three-window
/// Finder took ~20s to decide there was no URL at all.
func windowURL(_ window: AXUIElement, budget: inout Int) -> String? {
    var frontier = [window]
    var depth = 0
    while !frontier.isEmpty, depth <= 6, budget > 0 {
        var next: [AXUIElement] = []
        for e in frontier {
            if budget <= 0 { break }
            budget -= 1
            if let u = axAttr(e, "AXURL") {
                if let url = u as? NSURL { return url.absoluteString }
                if let s = u as? String { return s }
            }
            if let kids = axAttr(e, kAXChildrenAttribute as String) as? [AXUIElement] { next += kids }
        }
        frontier = next
        depth += 1
    }
    return nil
}

func urlSummary(_ pid: pid_t) -> String? {
    let app = AXUIElementCreateApplication(pid)
    guard let wins = axAttr(app, kAXWindowsAttribute as String) as? [AXUIElement] else { return nil }
    // One budget across every window: an app that publishes no URL anywhere must not cost
    // more than the tree dump this single header line decorates.
    var budget = 200
    for w in wins {
        if let u = windowURL(w, budget: &budget) {
            let title = axStr(w, kAXTitleAttribute as String) ?? ""
            return "url: \(u)\(title.isEmpty ? "" : "   (\(title.prefix(60)))")"
        }
    }
    return nil
}
