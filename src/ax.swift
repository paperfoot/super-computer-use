// AX layer: tree walking, addressing, settle, cursor, windows.

import Cocoa
import ApplicationServices
import CryptoKit

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

func collectNodes(pid: pid_t, maxDepth: Int = 18, maxNodes: Int = 4000,
                  includeMenus: Bool = false, windowFilter: CGWindowID? = nil) -> [Node] {
    var out: [Node] = []
    // Tracks which window the walk is currently inside, so refs can be scoped to it.
    var currentWindow = ""
    func walk(_ e: AXUIElement, _ depth: Int, _ path: String) {
        if depth > maxDepth || out.count >= maxNodes { return }
        let a = bulkRead(e)
        let role = a.role
        if !includeMenus, role == "AXMenuBar" || role == "AXMenuBarItem" { return }
        let title = a.title, value = a.value, desc = a.desc
        // Entering a window scopes every descendant's ref to it.
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
                            actionable: !acts.isEmpty, window: currentWindow))
        }
        if let kids = axAttr(e, kAXChildrenAttribute as String) as? [AXUIElement] {
            for (i, k) in kids.enumerated() { walk(k, depth + 1, path.isEmpty ? "\(i)" : "\(path).\(i)") }
        }
    }
    let app = AXUIElementCreateApplication(pid)
    unlockAccessibility(app, force: flag("enhanced"))
    walk(app, 0, "")
    return out
}

/// Processes we've already tried to unlock this run.
private var unlockedPids = Set<pid_t>()

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
    if !force && unlockedPids.contains(appPid) { return }
    unlockedPids.insert(appPid)

    let manual = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    var enhanced: AXError = .attributeUnsupported
    if manual != .success || force {
        enhanced = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }
    // Only pay the settle cost when something actually changed.
    if manual == .success || enhanced == .success { usleep(250_000) }
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
        let sub = axStr(n.el, kAXSubroleAttribute as String) ?? ""
        if n.role == "AXSecureTextField" || sub == "AXSecureTextField" {
            return Actionability(ok: false, code: "secure_field",
                reason: "\(n.label.isEmpty ? "This field" : n.label) is a secure text field",
                fix: "Type the password yourself. Secure input deliberately blocks synthetic keystrokes.")
        }
    }
    return Actionability(ok: true, code: "", reason: "", fix: "")
}

/// Cheap fingerprint of the visible tree, used to tell whether an action changed anything.
func changeFingerprint(_ pid: pid_t) -> String {
    treeSignature(pid)
}

func requirePid() -> pid_t {
    if let s = opt("pid"), let p = pid_t(s) { return p }
    // Convenience: --app resolves a display name to a running pid.
    if let name = opt("app") {
        let needle = name.lowercased()
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

    init(_ s: String) {
        for clause in s.split(separator: ";") {
            let c = clause.trimmingCharacters(in: .whitespaces)
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
            else if c.hasPrefix("nth=") { nth = Int(rhs("=") ?? "") }
            else if c == "actionable" { actionableOnly = true }
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
    let nodes = collectNodes(pid: pid, maxDepth: intOpt("depth", 20),
                             maxNodes: intOpt("max", 6000), includeMenus: flag("menus"))
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
    let nodes = collectNodes(pid: pid, maxDepth: intOpt("depth", 20),
                             maxNodes: intOpt("max", 6000), includeMenus: flag("menus"))
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

/// Resolve a target from --ref (preferred, survives reflow) or --index (positional).
func resolveNode(_ pid: pid_t, refOverride: String? = nil, indexOverride: Int? = nil) -> Node {
    if let q = opt("query") {
        do { return try resolveQuery(pid, q) }
        catch let e as ResolveError { fail(e.code, e.message, resolveSuggestion(e.code), .input) }
        catch { fail("unknown", "\(error)", "Re-run with --json for the structured error, then check `scu doctor`.", .transient) }
    }
    let nodes = collectNodes(pid: pid, maxDepth: intOpt("depth", 20),
                             maxNodes: intOpt("max", 6000), includeMenus: flag("menus"))
    if let r = refOverride ?? opt("ref") {
        let hits = nodes.filter { $0.ref == r }
        if hits.isEmpty {
            fail("stale_ref", "ref \(r) no longer present — re-run find/axdump for current state", "Re-run `scu find` or `scu axdump` and use the fresh ref.", .input)
        }
        if hits.count > 1 {
            // Disambiguate by tree path when the caller supplied one.
            if let p = opt("path"), let exact = hits.first(where: { $0.path == p }) { return exact }
            fail("ambiguous_ref", "\(hits.count) elements match \(r)", "Pass --path with one of: \(hits.prefix(4).map { $0.path }.joined(separator: ", ")) — or use --query with nth=.", .input)
        }
        return hits[0]
    }
    guard let idx = indexOverride ?? Int(opt("index") ?? "") else {
        fail("bad_args", "--ref (preferred) or --index required", "Run `scu help` for the command reference, or `scu agent-info` for the machine-readable manifest.", .input)
    }
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

/// Returns (settled, elapsedMs). `--wait N` forces a fixed sleep; `--wait auto` (default)
/// observes. `--wait 0` skips entirely.
@discardableResult
func settle(_ pid: pid_t) -> (Bool, Int) {
    let spec = opt("wait") ?? "auto"
    if spec != "auto", let fixed = Int(spec) {
        if fixed > 0 { usleep(UInt32(fixed * 1000)) }
        return (true, fixed)
    }
    let cap = intOpt("wait-max", 5000)
    let quiet = intOpt("quiet", 250)
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
    for i in 1...8 {
        w.alphaValue = CGFloat(i) / 8
        RunLoop.current.run(until: Date().addingTimeInterval(0.010))
    }
    if hold > 0 { RunLoop.current.run(until: Date().addingTimeInterval(hold)) }
}
func hideAgentCursor() {
    guard let w = cursorWindow else { return }
    for i in stride(from: 6, through: 0, by: -1) {
        w.alphaValue = CGFloat(i) / 6
        RunLoop.current.run(until: Date().addingTimeInterval(0.010))
    }
    w.orderOut(nil); cursorWindow = nil
}
func flash(_ pt: CGPoint?, _ label: String) {
    guard !flag("no-cursor"), let p = pt else { return }
    showAgentCursor(at: p, label: label, hold: Double(opt("hold") ?? "") ?? 0.45)
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
        let a = axActions(n.el).filter { $0 != "AXShowMenu" }
        if !a.isEmpty { acts = " {\(a.map { $0.replacingOccurrences(of: "AX", with: "") }.joined(separator: ","))}" }
    }
    let id = n.ident.isEmpty ? "" : " #\(n.ident)"
    return "[\(n.index)] \(n.ref) \(n.role)\(id)\(loc)\(acts): \(n.text)"
}
