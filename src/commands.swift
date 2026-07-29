// Command bodies. Each ends by calling emit/emitText (success) or fail (error), so
// every stdout path respects the output format and every error lands on stderr.

import Cocoa
import ApplicationServices

// MARK: - shared

func actionSuggestion(_ code: String) -> String {
    switch code {
    case "press_failed":
        return "Run `scu actions --ref …` to see supported actions, then `scu perform --action NAME`. If the app ignores AX, try --mode event."
    case "action_failed":
        return "Run `scu actions --ref …` and pass one of the names it lists to --action."
    case "setvalue_failed":
        // Not "click it then type": a background app has no first responder, so keystrokes
        // are swallowed — which is why setvalue exists in the first place.
        // Not --actionable: that filter means "exposes an AX action", which drops the editable
        // text areas in several apps — it would hide the very element the caller needs.
        return "The element refused AXSetValue, so it is read-only or a rendered proxy. "
            + "Run `scu axdump \(targetFlag())` and target the editable field itself "
            + "(role=AXTextField or AXTextArea)."
    case "select_failed", "no_value", "text_not_found":
        return "Confirm the element holds that text with `scu axdump \(targetFlag()) --grep …` before selecting."
    case "unknown_key":
        return "Use a key name such as return, tab, escape, up, or a chord like cmd+shift+a."
    case "no_geometry":
        return "The element has no on-screen position. Target a visible child — see `scu axdump`."
    case "hit_test_failed":
        return "Check the coordinate against `scu axdump`, or target by --query instead."
    case "timeout":
        return "Raise --timeout, or check the current state with `scu axdump --grep …`."
    case "bad_script":
        return "Pass a JSON array of steps, e.g. [{\"do\":\"click\",\"query\":\"role=AXButton;nth=0\"}]."
    case "unknown_step":
        // Naming the vocabulary is the whole fix here: re-stating the array shape sends the
        // caller back to the input they already wrote.
        return "Supported steps are click, setvalue, type, key, scroll, waitfor and sleep. Run selecttext, perform and drag as single commands."
    default:
        return "Run `scu doctor` to verify permissions, then retry."
    }
}

/// UI-state failures are worth retrying after a settle; argument mistakes are not.
func actionExit(_ code: String) -> Exit {
    switch code {
    case "bad_args", "bad_script", "unknown_key", "unknown_step", "text_not_found",
         "no_geometry", "hit_test_failed":
        return .input
    case "secure_field":
        // No wait and no different argument clears a password field, so retry-on-1 would loop.
        return .config
    default:
        return .transient
    }
}

/// A refusal that already knows its own fix and exit code. ActionError has nowhere to put a
/// suggestion, and a generic "check your arguments" is the circular advice this project
/// treats as a bug. Throwing rather than exiting also keeps `batch` able to report how far
/// it got: a preflight that called fail() directly would kill the script mid-run with no
/// record of the steps that already mutated the app.
private struct StepFailure: Error {
    let code: String, message: String, suggestion: String, exit: Exit
    init(_ code: String, _ message: String, _ suggestion: String, _ exit: Exit) {
        self.code = code; self.message = message; self.suggestion = suggestion; self.exit = exit
    }
}

private func badArgs(_ message: String, _ suggestion: String) -> StepFailure {
    StepFailure("bad_args", message, suggestion, .input)
}

/// Raise a refusal the AX layer handed back. `guarded` turns it into the identical message,
/// suggestion and exit code the direct exit produced, while `batch` gets to say how far it
/// had already got.
private func refuse(_ e: CLIError?) throws {
    guard let e = e else { return }
    throw StepFailure(e.code, e.message, e.suggestion, e.exit)
}

/// Translate an action-primitive throw into the CLI error contract.
func guarded<T>(_ body: () throws -> T) -> T {
    do { return try body() }
    catch let e as StepFailure {
        hideAgentCursor(); fail(e.code, e.message, e.suggestion, e.exit)
    }
    catch let e as ActionError {
        guard case let .fail(code, msg) = e else {
            hideAgentCursor(); fail("unknown", "\(e)", "Retry.", .transient)
        }
        hideAgentCursor()
        fail(code, msg, actionSuggestion(code), actionExit(code))
    }
    catch let e as ResolveError {
        hideAgentCursor(); fail(e.code, e.message, resolveSuggestion(e.code), .input)
    }
    catch {
        hideAgentCursor(); fail("unknown", "\(error)", "Run `scu doctor`, then retry.", .transient)
    }
}

/// What a verb did, in the shape both reply formats need.
///
/// `before` is the tree fingerprint taken immediately before the action, so the caller can
/// report `changed`. `afterSettle` carries evidence that is only trustworthy once the app
/// has finished reacting — setvalue's readback, selecttext's selection.
private struct ActionOutcome {
    let before: String?
    var fields: [(String, Any)] = []
    var afterSettle: (() -> [(String, Any)])? = nil
    init(before: String?) { self.before = before }
}

/// Every mutating command ends the same way: drop the cursor, settle, report.
///
/// `changed` is the honest bit. An AX action can return success and do nothing at all —
/// a disabled control, a responder-level menu shortcut sent to a background app, a click
/// on a stale node. Comparing a tree fingerprint across the action tells the caller
/// whether the app actually reacted, instead of leaving them to assume it did.
private func afterAction(_ pid: pid_t, _ o: ActionOutcome) -> Never {
    hideAgentCursor()
    let s = settle(pid)
    var fields: [(String, Any)] = [("ok", true), ("settled", s.0), ("settledMs", s.1)]
    if let b = o.before {
        fields.append(("changed", changeFingerprint(pid) != b))
        fields += changeCoverageFields()
    }
    fields += o.afterSettle?() ?? []
    fields += o.fields
    fields += thenFields(pid)
    emit(fields)
}

/// --then folds the follow-up read into the acting response. An agent that acts and then
/// immediately looks otherwise pays two process launches and two model round-trips for
/// one logical step.
func thenFields(_ pid: pid_t) -> [(String, Any)] {
    var fields: [(String, Any)] = []
    guard let mode = opt("then") else { return fields }
    let b = treeBudget()
    let nodes = collectNodes(pid: pid, maxDepth: b.depth,
                             maxNodes: b.max, includeMenus: flag("menus"))
    switch mode {
    case "dump":
        fields.append(("tree", nodes.map { renderLine($0, showActions: flag("actions")) }
                                    .joined(separator: "\n")))
    case "diff":
        guard let d = diffAgainstCache(pid, nodes) else {
            fields.append(("diff", "(no cached tree for pid \(pid))"))
            break
        }
        fields.append(("diff", (d.added.map { "+ \($0)" } + d.removed.map { "- \($0)" })
                                .joined(separator: "\n")))
    case "focus":
        fields.append(("focus", focusSummary(pid) ?? "none"))
    default:
        break
    }
    return fields
}

/// Refuse predictable no-ops before acting, with the fix in the error.
private func preflight(_ n: Node, _ pid: pid_t, typing: Bool = false) throws {
    // --no-check is a convenience flag: it may skip the actionability checks, never the
    // secure-field refusal. A flag whose stated purpose is "act anyway" must not double as
    // permission to write into a password field.
    // Asked directly, not via checkActionable: that returns disabled/hidden/zero-size first,
    // so a zero-frame password field never reached its secure-field branch and fell through
    // to the --no-check escape below.
    if typing, isSecureField(n) {
        throw StepFailure("secure_field",
                          "\(n.label.isEmpty ? "This field" : n.label) is a secure text field",
                          "Type the password yourself. Secure input deliberately blocks synthetic keystrokes.",
                          .config)
    }
    if flag("no-check") { return }
    // Bring the target into its scroll container's viewport first; a row scrolled out of
    // sight has valid geometry but may not react. Harmless where unsupported.
    _ = AXUIElementPerformAction(n.el, "AXScrollToVisible" as CFString)
    let a = checkActionable(n, pid: pid, forTyping: typing)
    if !a.ok { throw StepFailure(a.code, a.reason, a.fix, a.exit) }
}

/// Work out *why* an app produced no usable tree, and fail with the matching fix.
///
/// Observed in testing: Notes and Reminders launched in the background report a valid
/// AXApplication with zero windows, which looks identical to a permissions failure if you
/// only check node count. Blaming Accessibility there sends the caller to System Settings
/// for nothing.
func diagnoseEmptyTree(_ pid: pid_t) -> Never {
    if !AXIsProcessTrusted() {
        fail("permission_denied", "Accessibility is not granted to this terminal",
             "Run `scu doctor` for the exact steps, then restart your terminal.", .config)
    }
    // An exited pid produces exactly the same empty tree as a live app with no window, and
    // every message below would then state it is running and suggest acting on it.
    guard kill(pid, 0) == 0 || errno == EPERM else {
        fail("app_not_running", "no process with pid \(pid)",
             "That process has exited. Run `scu apps` for current pids, or target by name with --app.",
             .input)
    }
    // Checked before anything app-specific: while the screen is locked most apps publish no
    // tree at all, and every message below would blame the app for it.
    if screenIsLocked() {
        fail("screen_locked", "the screen is locked, so apps are not publishing accessibility trees",
             "Unlock the Mac and retry. Nothing about the target app needs changing — this is a "
             + "session state, and no flag works around it.", .transient)
    }
    let app = AXUIElementCreateApplication(pid)
    let wins = (axAttr(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "the app"

    if wins.isEmpty {
        let minimized = listWindows(all: true).filter { $0.pid == pid }
        if !minimized.isEmpty {
            fail("window_minimized", "\(name) has no open window; \(minimized.count) minimized or off-screen",
                 "Try `scu unhide --pid \(pid)`. If that reports cannot_restore, the app hides "
                 + "minimized windows from accessibility and you must click its Dock icon — restoring "
                 + "it any other way would steal focus.", .transient)
        }
        fail("no_window", "\(name) is running but has no open window",
             "Open a window first — e.g. `scu key --pid \(pid) --key cmd+n`, or click its Dock icon. "
             + "Background-launched apps often start with no window.", .transient)
    }
    fail("no_ax_tree", "\(name) exposes a window but no readable accessibility tree",
         "Try `scu axdump --pid \(pid) --enhanced`. If that is still empty, the app does not "
         + "publish AX data — fall back to `scu shot --window …` and read it visually.", .transient)
}

// MARK: - argument source
//
// A verb's arguments come either from argv (single command) or from a `batch` step object.
// Reading both through one type is what stops the two from drifting: every batch defect in
// review — no preflight, no `changed`, a dropped `ref`, a missing required argument — came
// from a step re-implementing a verb that already existed.

private struct StepArgs {
    let step: [String: Any]?
    init() { step = nil }
    init(_ s: [String: Any]) { step = s }

    /// True for the single-command path, which keeps its own resolver so --index and --path
    /// behave exactly as before.
    var isCLI: Bool { step == nil }

    /// The raw token for a key: an argv value, or a JSON scalar rendered as text.
    func str(_ k: String) -> String? {
        guard let s = step else { return opt(k) }
        if let v = s[k] as? String { return v }
        if let n = s[k] as? NSNumber { return n.stringValue }
        return nil
    }

    func bool(_ k: String) -> Bool {
        guard let s = step else { return flag(k) }
        return (s[k] as? Bool) ?? false
    }

    /// Any user-supplied number that reaches usleep, a UInt32 conversion or a loop bound has
    /// to be validated here. Swift traps on NaN and on an out-of-range conversion, and a trap
    /// exits 133 with nothing on stdout or stderr — outside the documented 0-4 contract, so
    /// the caller learns neither what failed nor how far the run got.
    func number(_ k: String, _ dflt: Double, min lo: Double, max hi: Double) throws -> Double {
        guard let r = str(k), !r.isEmpty else { return dflt }
        guard let v = Double(r), v.isFinite, v >= lo, v <= hi else {
            throw badArgs("\(k) must be a number between \(numStr(lo)) and \(numStr(hi)), not '\(r)'",
                        "Pass \(isCLI ? "--\(k) " : "\"\(k)\": ")\(numStr(dflt)) — that is the default.")
        }
        return v
    }

    func int(_ k: String, _ dflt: Int, min lo: Int, max hi: Int) throws -> Int {
        Int(try number(k, Double(dflt), min: Double(lo), max: Double(hi)).rounded(.towardZero))
    }

    /// A screen coordinate: absent is legal, unparseable is not.
    func coord(_ k: String) throws -> Double? {
        guard let r = str(k), !r.isEmpty else { return nil }
        guard let v = Double(r), v.isFinite else {
            throw badArgs("\(k) must be a number, not '\(r)'",
                        "Pass a global screen coordinate, e.g. --\(k) 800. Read one from `scu find`.")
        }
        return v
    }
}

/// Render a numeric bound without a trailing ".0" on whole numbers.
private func numStr(_ d: Double) -> String { d == d.rounded() ? "\(Int(d))" : "\(d)" }

/// Resolve the element a command or step names, throwing so `batch` can report which steps
/// already ran. The single-command path keeps `resolveNode`, which also handles --index and
/// the --path disambiguator.
private func resolveTarget(_ pid: pid_t, _ a: StepArgs) throws -> Node {
    if a.isCLI { return resolveNode(pid) }
    if let q = a.str("query") { return try resolveQuery(pid, q) }
    guard let r = a.str("ref") else {
        throw badArgs("step needs a ref or query",
                    "Add \"query\":\"role=AXButton;nth=0\" or \"ref\":\"Button#3f2a1b\" to the step.")
    }
    return try resolveNodeThrowing(pid, ref: r)
}

private func resolveTarget(_ pid: pid_t, _ a: StepArgs, ref: String) throws -> Node {
    a.isCLI ? resolveNode(pid, refOverride: ref) : try resolveNodeThrowing(pid, ref: ref)
}

/// `flash` reads --hold itself and hands it to a run-loop deadline, so validate it before
/// any verb draws the cursor rather than letting an infinite hold block forever. The bound
/// must stay the one `cursorHold` enforces: anything this accepts and that refuses would
/// exit from inside `flash`, past the throw that lets `batch` report its completed steps.
private func flashAt(_ pt: CGPoint?, _ label: String) throws {
    _ = try StepArgs().number("hold", 0.45, min: 0, max: 30)
    flash(pt, label)
}

// MARK: - read

func cmdWindows() -> Never {
    let f = opt("app")?.lowercased()
    let wins = listWindows(all: flag("all")).filter {
        guard let f = f else { return true }
        return $0.owner.lowercased().contains(f)
    }
    let data: [Any] = wins.map { w in
        [("id", Int(w.id) as Any), ("pid", Int(w.pid) as Any), ("owner", w.owner as Any),
         ("name", w.name as Any), ("x", Int(w.rect.origin.x) as Any), ("y", Int(w.rect.origin.y) as Any),
         ("w", Int(w.rect.width) as Any), ("h", Int(w.rect.height) as Any),
         ("layer", w.layer as Any)] as [(String, Any)]
    }
    emit([("windows", data as Any), ("count", wins.count as Any)] as [(String, Any)]) {
        wins.isEmpty ? "(no matching windows)" :
        wins.map { "\($0.id)\t\($0.pid)\t\($0.owner)\t\(Int($0.rect.width))x\(Int($0.rect.height))\t\($0.name)" }
            .joined(separator: "\n")
    }
}

func cmdApps() -> Never {
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    let data: [Any] = apps.map { a in
        [("pid", Int(a.processIdentifier) as Any), ("name", (a.localizedName ?? "?") as Any),
         ("bundle", (a.bundleIdentifier ?? "") as Any), ("hidden", a.isHidden as Any),
         ("active", a.isActive as Any)] as [(String, Any)]
    }
    emit([("apps", data as Any), ("count", apps.count as Any)] as [(String, Any)]) {
        apps.map { "\($0.processIdentifier)\t\($0.localizedName ?? "?")\t\($0.bundleIdentifier ?? "")" }
            .joined(separator: "\n")
    }
}

/// The --diff baseline, rendered the one canonical way.
///
/// --grep, --actionable and --actions each change what a dump line looks like, and caching
/// whichever variant ran last made the next --diff report the entire tree as newly added.
/// The cache is a baseline, so it never depends on how this invocation was filtered.
private func cacheRender(_ nodes: [Node]) -> [String] {
    nodes.map { renderLine($0, showActions: false) }
}

/// Diff the canonical render against the cached baseline and replace it. Returns nil when
/// there is no usable baseline, so the caller can say so instead of printing the whole tree
/// as additions — an empty cache file reads as "everything is new" otherwise.
private func diffAgainstCache(_ pid: pid_t, _ nodes: [Node]) -> (added: [String], removed: [String])? {
    let url = cacheURL(pid)
    let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let lines = cacheRender(nodes)
    try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    guard !previous.isEmpty else { return nil }
    let prev = previous.components(separatedBy: "\n").filter { !$0.isEmpty }
    // Compare on everything after the volatile leading index.
    func key(_ l: String) -> String {
        guard let r = l.range(of: "] ") else { return l }
        return String(l[r.upperBound...])
    }
    let prevKeys = Set(prev.map(key)), nowKeys = Set(lines.map(key))
    return (lines.filter { !prevKeys.contains(key($0)) },
            prev.filter { !nowKeys.contains(key($0)) })
}

func cmdAxdump() -> Never {
    let pid = requirePid()
    let b = treeBudget()
    let nodes = collectNodes(pid: pid, maxDepth: b.depth,
                             maxNodes: b.max, includeMenus: flag("menus"))
    // An empty or near-empty tree has three very different causes; naming the right one
    // saves the caller from chasing a permissions problem that isn't there.
    if nodes.count <= 1 { diagnoseEmptyTree(pid) }
    let needle = opt("grep")?.lowercased()
    let showActions = flag("actions")
    var lines: [String] = []
    for n in nodes {
        if flag("actionable") && !n.actionable { continue }
        if let g = needle, !n.text.lowercased().contains(g) { continue }
        lines.append(renderLine(n, showActions: showActions))
    }

    if flag("diff") {
        guard let d = diffAgainstCache(pid, nodes) else {
            emitText("(no cached tree for pid \(pid); full dump follows)\n" + lines.joined(separator: "\n"))
        }
        // The comparison covers the whole tree so a filtered dump cannot poison it, but the
        // caller still asked for a subset — filter what is printed, not what is compared.
        let keep: (String) -> Bool = { l in needle.map { l.lowercased().contains($0) } ?? true }
        let added = d.added.filter(keep), removed = d.removed.filter(keep)
        if added.isEmpty && removed.isEmpty { emitText("(no change)") }
        emitText((added.map { "+ \($0)" } + removed.map { "- \($0)" }).joined(separator: "\n"))
    }

    try? cacheRender(nodes).joined(separator: "\n")
        .write(to: cacheURL(pid), atomically: true, encoding: .utf8)
    // Prepend what the tree alone cannot say: what has focus, what is selected, and which
    // page a browser window is on. Suppress with --no-context for a bare tree.
    var header: [String] = []
    if !flag("no-context") {
        if let u = urlSummary(pid) { header.append(u) }
        if let f = focusSummary(pid) { header.append(f) }
    }
    let body = lines.joined(separator: "\n")
    emitText(header.isEmpty ? body : header.joined(separator: "\n") + "\n" + body)
}

func cmdFind() -> Never {
    let pid = requirePid()
    guard let needle = opt("text")?.lowercased(), !needle.isEmpty else {
        // Swift's contains("") is false, so an empty needle would silently match nothing.
        fail("bad_args", "--text must be a non-empty string",
             "Example: scu find --app Notes --text \"Shopping\". To list everything, use `scu axdump`.", .input)
    }
    let b = treeBudget()
    let nodes = collectNodes(pid: pid, maxDepth: b.depth,
                             maxNodes: b.max, includeMenus: flag("menus"))
    let hits = nodes.filter {
        $0.text.lowercased().contains(needle) && (!flag("actionable") || $0.actionable)
    }
    let data: [Any] = hits.map { n in
        [("index", n.index as Any), ("ref", n.ref as Any), ("role", n.role as Any),
         ("text", String(n.text.prefix(200)) as Any), ("path", n.path as Any),
         ("centreX", (n.centre.map { Int($0.x) } ?? -1) as Any),
         ("centreY", (n.centre.map { Int($0.y) } ?? -1) as Any),
         ("actions", n.actions as Any)] as [(String, Any)]
    }
    emit([("matches", data as Any), ("count", hits.count as Any)] as [(String, Any)]) {
        hits.isEmpty ? "(no match for '\(needle)')" : hits.map { n in
            let c = n.centre.map { " centre=\(Int($0.x)),\(Int($0.y))" } ?? ""
            let a = n.actions.map { $0.replacingOccurrences(of: "AX", with: "") }.joined(separator: ",")
            return "[\(n.index)] \(n.ref) \(n.role)\(c) path=\(n.path) actions=\(a)\n      \(n.text.prefix(180))"
        }.joined(separator: "\n")
    }
}

func cmdActions() -> Never {
    let pid = requirePid()
    let n = resolveNode(pid)
    let acts = axActions(n.el)
    emit([("ref", n.ref as Any), ("index", n.index as Any), ("role", n.role as Any),
          ("actions", acts as Any)] as [(String, Any)]) {
        "\(n.ref) \(n.role): \(acts.isEmpty ? "(none)" : acts.joined(separator: ", "))"
    }
}

// MARK: - verb bodies, shared by the CLI and `batch`
//
// One implementation per verb, so a guard added here applies to both entry points. The two
// callers differ only in where arguments come from and how the reply is shaped.

/// Route a synthetic click to the window the point is actually inside. Stamping the
/// frontmost window's number on a click aimed at a background window makes AppKit
/// reinterpret the coordinates in that other window, landing the press somewhere else.
private func eventWindowID(pid: pid_t, at p: CGPoint) -> CGWindowID? {
    let mine = listWindows(all: false).filter { $0.pid == pid }
    return (mine.first { $0.rect.contains(p) } ?? mine.first)?.id
}

private func runClick(_ pid: pid_t, _ a: StepArgs) throws -> ActionOutcome {
    var node: Node?
    var pt: CGPoint?
    var label = "click"
    if a.str("ref") != nil || a.str("index") != nil || a.str("query") != nil {
        let n = try resolveTarget(pid, a); node = n; pt = n.centre; label = n.label
    } else if let x = try a.coord("x"), let y = try a.coord("y") {
        pt = CGPoint(x: x, y: y)
    } else {
        throw badArgs("no target given",
                    "Pass --query 'role=AXButton;nth=0', or --ref from `scu find`, or --x/--y.")
    }
    if let n = node { try preflight(n, pid) }
    var out = ActionOutcome(before: changeFingerprint(pid))
    try flashAt(pt, label)

    let mode = a.str("mode") ?? "ax"
    if mode == "ax" {
        if let n = node {
            try pressElement(n)
        } else if let p = pt {
            var found: AXUIElement?
            let e = AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid),
                                                     Float(p.x), Float(p.y), &found)
            guard e == .success, let f = found else {
                throw ActionError.fail("hit_test_failed",
                    "No element at \(Int(p.x)),\(Int(p.y)) (AX error \(e.rawValue))")
            }
            try pressElement(Node(el: f, index: -1,
                role: axStr(f, kAXRoleAttribute as String) ?? "?", ident: "", title: "", value: "",
                desc: "", pos: nil, size: nil, path: "", actionable: true, window: ""))
        }
    } else {
        guard let p = pt else {
            throw badArgs("event mode needs a point",
                        "Pass --x and --y, or use the default ax mode with --query.")
        }
        synthClick(pid: pid, at: p, button: a.str("button") ?? "left",
                   count: try a.int("count", 1, min: 1, max: 10),
                   windowID: eventWindowID(pid: pid, at: p))
    }
    out.fields = [("mode", mode as Any)]
    return out
}

private func runSetValue(_ pid: pid_t, _ a: StepArgs) throws -> ActionOutcome {
    guard let v = a.str("value") else {
        throw badArgs("value is required",
                    "Example: scu setvalue --query 'role=AXTextField;nth=0' --value hello")
    }
    let n = try resolveTarget(pid, a)
    try preflight(n, pid, typing: true)
    var out = ActionOutcome(before: changeFingerprint(pid))
    try flashAt(n.centre, "set value")
    try setValue(n, v)
    out.fields = [("ref", n.ref as Any)]
    // A field can be read back directly, so verify exactly rather than inferring from a
    // tree fingerprint: some controls accept AXSetValue and then reformat or reject it.
    // The readback waits for the settle, or it races the app's own reformatting.
    out.afterSettle = {
        guard let readback = axStr(n.el, kAXValueAttribute as String) else {
            return [("verified", "unknown" as Any)]
        }
        // A real boolean: "false" as a string is truthy in jq, JS and Python, so the one
        // field designed to catch a rejected write would have read as success.
        var f: [(String, Any)] = [("verified", (readback == v) as Any)]
        if readback != v { f.append(("actualValue", String(readback.prefix(200)) as Any)) }
        return f
    }
    return out
}

private func runSelectText(_ pid: pid_t, _ a: StepArgs) throws -> ActionOutcome {
    guard let t = a.str("text"), !t.isEmpty else {
        throw badArgs("text is required",
                    "Example: scu selecttext --query 'role=AXTextArea' --text hello")
    }
    let n = try resolveTarget(pid, a)
    try preflight(n, pid)
    let mode = a.str("cursor") ?? "select"
    var out = ActionOutcome(before: changeFingerprint(pid))
    try flashAt(n.centre, "select")
    try selectText(n, needle: t, mode: mode)
    out.fields = [("ref", n.ref as Any)]
    // Selecting moves no node's role, text or position, so the tree fingerprint cannot see
    // it and `changed` alone would always read false. Read the selection back instead —
    // an app can accept AXSelectedTextRange and then clamp or discard it.
    out.afterSettle = {
        guard let sel = axStr(n.el, kAXSelectedTextAttribute as String) else {
            return [("verified", "unknown" as Any)]
        }
        if mode == "select" {
            var f: [(String, Any)] = [("verified", (sel == t) as Any)]
            if sel != t { f.append(("selectedText", String(sel.prefix(200)) as Any)) }
            return f
        }
        // before/after place a caret, so an empty selection is the success condition.
        return [("verified", sel.isEmpty as Any)]
    }
    return out
}

private func runType(_ pid: pid_t, _ a: StepArgs) throws -> ActionOutcome {
    guard let t = a.str("text") else {
        throw badArgs("text is required", "Example: scu type --app Notes --text \"hello\"")
    }
    // The raw input path takes no element, so it needs its own guards; without these it
    // was the one way to push keystrokes at a password field.
    try refuse(enforceSecureInput("typing"))
    try refuse(enforceFocusedFieldSafety(pid))
    let out = ActionOutcome(before: changeFingerprint(pid))
    typeText(pid: pid, text: t)
    return out
}

private func runKey(_ pid: pid_t, _ a: StepArgs) throws -> ActionOutcome {
    guard let k = a.str("key") else {
        throw badArgs("key is required", "Example: scu key --key return, or --key cmd+shift+a")
    }
    // `key` is a character-entry path too — every letter and digit is in the keycode table —
    // so it needs the focused-field refusal that `type` has, not just the global
    // secure-input one, which macOS only engages for the frontmost app.
    try refuse(enforceSecureInput("key presses"))
    try refuse(enforceFocusedFieldSafety(pid))
    var out = ActionOutcome(before: changeFingerprint(pid))
    try sendKey(pid: pid, chord: k)
    out.fields = [("note", chordNote(k) as Any)]
    return out
}

private func runScroll(_ pid: pid_t, _ a: StepArgs) throws -> ActionOutcome {
    guard let dir = a.str("direction")?.lowercased() else {
        throw badArgs("direction is required", "Pass --direction up, down, left, or right.")
    }
    guard ["up", "down", "left", "right"].contains(dir) else {
        throw badArgs("unknown direction '\(dir)'", "Pass --direction up, down, left, or right.")
    }
    let n = try resolveTarget(pid, a)
    guard let c = n.centre else {
        throw ActionError.fail("no_geometry", "Element \(n.ref) has no on-screen position")
    }
    try preflight(n, pid)
    let pages = try a.int("pages", 1, min: 1, max: 100)
    var out = ActionOutcome(before: changeFingerprint(pid))
    try flashAt(c, "scroll \(dir)")
    // An element's own AX scroll action is more reliable than wheel events in the
    // background. AppKit publishes them as NSAccessibilityScroll<Dir>ByPageAction — there is
    // no bare AXScrollDown, so the unsuffixed name this used to build matched nothing and
    // every scroll silently took the wheel-event path.
    let want = "AXScroll" + dir.prefix(1).uppercased() + dir.dropFirst() + "ByPage"
    if axActions(n.el).contains(want) {
        for _ in 0..<pages { _ = AXUIElementPerformAction(n.el, want as CFString) }
        out.fields = [("via", "ax" as Any)]
    } else {
        scrollAt(pid: pid, p: c, dir: dir, pages: pages)
        out.fields = [("via", "event" as Any)]
    }
    return out
}

private func runDrag(_ pid: pid_t, _ a: StepArgs) throws -> ActionOutcome {
    /// Resolve one end of the drag. An element that resolved but has no geometry is a
    /// different failure from a missing argument, and saying "pass --from-ref" to someone
    /// who just passed --from-ref is the circular advice this project treats as a bug.
    func end(_ refKey: String, _ xKey: String, _ yKey: String, _ what: String) throws -> CGPoint {
        if let r = a.str(refKey) {
            let n = try resolveTarget(pid, a, ref: r)
            guard let c = n.centre else {
                throw ActionError.fail("no_geometry",
                    "drag \(what) \(n.ref) has no on-screen position")
            }
            return c
        }
        if let x = try a.coord(xKey), let y = try a.coord(yKey) { return CGPoint(x: x, y: y) }
        throw badArgs("drag needs a \(what)",
                      "Pass --\(refKey) REF from `scu find`, or --\(xKey) and --\(yKey).")
    }
    let f = try end("from-ref", "from-x", "from-y", "source")
    let t = try end("to-ref", "to-x", "to-y", "destination")
    let out = ActionOutcome(before: changeFingerprint(pid))
    try flashAt(f, "drag")
    dragFromTo(pid: pid, from: f, to: t)
    return out
}

private func runPerform(_ pid: pid_t, _ a: StepArgs) throws -> ActionOutcome {
    guard let act = a.str("action") else {
        throw badArgs("action is required",
                      "Run `scu actions --query …` to list what the element supports.")
    }
    let n = try resolveTarget(pid, a)
    try preflight(n, pid)
    var out = ActionOutcome(before: changeFingerprint(pid))
    try flashAt(n.centre, act.replacingOccurrences(of: "AX", with: ""))
    let e = AXUIElementPerformAction(n.el, act as CFString)
    if e != .success {
        let avail = axActions(n.el)
        throw ActionError.fail("action_failed",
            "\(act) rejected by \(n.ref) (AX error \(e.rawValue)); supported here: "
            + (avail.isEmpty ? "nothing — target a different element via `scu axdump --actionable`"
                             : avail.joined(separator: ", ")))
    }
    out.fields = [("ref", n.ref as Any)]
    return out
}

/// Single-quote a value so a suggested command survives being pasted verbatim. A needle with
/// a space silently greps only its first word otherwise, which is worse than no example.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The target as the caller expressed it. A suggestion naming `scu axdump` without one is not
/// runnable — it exits bad_args, which is the same wrong-suggestion class it was meant to fix.
func targetFlag() -> String {
    if let p = opt("pid"), !p.isEmpty { return "--pid \(p)" }
    if let a = opt("app"), !a.isEmpty { return "--app \(shellQuote(a))" }
    return "--app <app>"
}

/// waitfor's recovery depends on what was actually waited for. Telling a caller who waited
/// on a ref to check their text — the text they never supplied — is the wrong-suggestion
/// class this project rates a P0.
private func waitSuggestion(_ a: StepArgs) -> String {
    let gone = a.bool("gone")
    // A ref, when present, is what was matched on — so it is what the advice must name.
    if let r = a.str("ref"), !r.isEmpty {
        return gone
            ? "\(r) is still in the tree. Raise the timeout, or confirm you are watching the right element with `scu axdump \(targetFlag())`."
            // waitfor polls deeper than axdump's default, so an element it never saw may simply
            // sit below the budget rather than be gone. Name that before blaming the ref.
            : "Run `scu axdump \(targetFlag()) --depth 20 --max 6000` and check \(r) is still the "
            + "current ref — a ref changes with its title, identifier, description or window title. "
            + "If it is absent there too, raise --depth/--max or switch to --query."
    }
    let t = a.str("text") ?? ""
    return gone
        ? "'\(t)' is still present. Raise the timeout, or check the current state with `scu axdump \(targetFlag()) --grep \(shellQuote(t))`."
        : "Raise the timeout, or verify the expected text with `scu axdump \(targetFlag()) --grep \(shellQuote(t))`."
}

/// The recovery for a failed step, phrased for the artifact that produced it. The standalone
/// wording names `--mode event` and `scu perform`, neither of which a step can express, so an
/// agent reading it inside the script it is already running has nowhere to put the fix.
private func stepSuggestion(_ code: String, _ a: StepArgs) -> String {
    switch code {
    case "timeout":
        return waitSuggestion(a)
    case "press_failed":
        return "Run `scu actions --ref …` for the supported actions, then either add "
             + "\"mode\":\"event\" to this step or run it on its own as `scu perform --action "
             + "NAME` — batch shares click's keys but has no perform step."
    default:
        return actionSuggestion(code)
    }
}

private func runWaitFor(_ pid: pid_t, _ a: StepArgs) throws -> ActionOutcome {
    let needle = a.str("text")?.lowercased()
    let wantRef = a.str("ref")
    // An empty needle can never match — Swift's contains("") is false — so it would burn the
    // whole timeout and then advise raising it. Refuse it up front, in both entry points.
    let hasText = !(needle ?? "").isEmpty
    let hasRef = !(wantRef ?? "").isEmpty
    guard hasText || hasRef else {
        throw badArgs("waitfor needs a non-empty text or ref",
                      "Example: scu waitfor --app Safari --text \"Sign in\" --timeout 15")
    }
    let wantGone = a.bool("gone")
    let timeout = try a.number("timeout", 10, min: 0, max: 86_400)
    // Only `batch` reports `changed` per step; a standalone wait is a read, and the extra
    // tree walk would double the cost of a wait that returns immediately.
    let before: String? = a.isCLI ? nil : changeFingerprint(pid)

    let start = Date()
    repeat {
        let wb = treeBudget()
        let nodes = collectNodes(pid: pid, maxDepth: wb.depth, maxNodes: wb.max)
        let hit = hasRef ? nodes.first { $0.ref == wantRef! }
                         : nodes.first { $0.text.lowercased().contains(needle!) }
        if (hit != nil) != wantGone {
            var out = ActionOutcome(before: before)
            out.fields = [("waitedMs", Int(Date().timeIntervalSince(start) * 1000) as Any),
                          ("gone", wantGone as Any)]
            if let h = hit {
                out.fields += [("ref", h.ref as Any), ("index", h.index as Any),
                               ("text", String(h.text.prefix(160)) as Any)]
            }
            return out
        }
        usleep(250_000)
    } while Date().timeIntervalSince(start) < timeout

    throw ActionError.fail("timeout",
        "\(hasRef ? wantRef! : "'\(needle ?? "")'") never became "
        + "\(wantGone ? "absent" : "present") within \(numStr(timeout))s")
}

// MARK: - act

func cmdClick() -> Never {
    let pid = requirePid()
    afterAction(pid, guarded { try runClick(pid, StepArgs()) })
}

func cmdSetValue() -> Never {
    let pid = requirePid()
    afterAction(pid, guarded { try runSetValue(pid, StepArgs()) })
}

func cmdSelectText() -> Never {
    let pid = requirePid()
    afterAction(pid, guarded { try runSelectText(pid, StepArgs()) })
}

func cmdType() -> Never {
    let pid = requirePid()
    afterAction(pid, guarded { try runType(pid, StepArgs()) })
}

func cmdKey() -> Never {
    let pid = requirePid()
    afterAction(pid, guarded { try runKey(pid, StepArgs()) })
}

func cmdScroll() -> Never {
    let pid = requirePid()
    afterAction(pid, guarded { try runScroll(pid, StepArgs()) })
}

func cmdDrag() -> Never {
    let pid = requirePid()
    afterAction(pid, guarded { try runDrag(pid, StepArgs()) })
}

func cmdPerform() -> Never {
    let pid = requirePid()
    afterAction(pid, guarded { try runPerform(pid, StepArgs()) })
}

// MARK: - flow

func cmdWaitFor() -> Never {
    let pid = requirePid()
    let a = StepArgs()
    do {
        let out = try runWaitFor(pid, a)
        emit([("ok", true as Any)] + out.fields)
    } catch let e as StepFailure {
        fail(e.code, e.message, e.suggestion, e.exit)
    } catch let e as ActionError {
        guard case let .fail(code, msg) = e else { fail("unknown", "\(e)", "Retry.", .transient) }
        // The timeout advice is built from what this call actually waited on.
        fail(code, msg, code == "timeout" ? waitSuggestion(a) : actionSuggestion(code), actionExit(code))
    } catch let e as ResolveError {
        fail(e.code, e.message, resolveSuggestion(e.code), .input)
    } catch {
        fail("unknown", "\(error)", "Run `scu doctor`, then retry.", .transient)
    }
}

func cmdSettle() -> Never {
    let pid = requirePid()
    let s = settle(pid)
    emit([("ok", s.0 as Any), ("settledMs", s.1 as Any)] as [(String, Any)])
}

func cmdBatch() -> Never {
    let pid = requirePid()
    var raw: String
    if let f = opt("script") {
        guard let s = try? String(contentsOfFile: f, encoding: .utf8) else {
            fail("bad_script", "Cannot read \(f)", "Check the path exists and is readable.", .input)
        }
        raw = s
    } else if let inline = opt("json-script") {
        raw = inline
    } else {
        // Reading a piped script is not an interactive prompt — reading a terminal is.
        // Without this guard a forgotten --script blocked forever with nothing on either
        // stream, where every other command answers a missing argument with bad_args.
        guard isatty(fileno(stdin)) == 0 else {
            fail("bad_args", "batch needs a script on stdin, --script FILE, or --json-script JSON",
                 "Example: scu batch --app Notes --json-script '[{\"do\":\"waitfor\",\"text\":\"Done\"}]'",
                 .input)
        }
        raw = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    guard let parsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else {
        fail("bad_script", "Script is not a JSON array of step objects",
             "Example: [{\"do\":\"click\",\"query\":\"role=AXButton;nth=0\"},{\"do\":\"waitfor\",\"text\":\"Done\"}]",
             .input)
    }

    var results: [Any] = []
    for (i, step) in parsed.enumerated() {
        let act = (step["do"] as? String) ?? ""
        let a = StepArgs(step)
        do {
            // Every step runs the same body as the equivalent single command, so the
            // preflight, the secure-field refusal and the `changed` fingerprint cannot be
            // present on one path and missing on the other.
            let out: ActionOutcome
            switch act {
            case "click":     out = try runClick(pid, a)
            case "setvalue":  out = try runSetValue(pid, a)
            case "type":      out = try runType(pid, a)
            case "key":       out = try runKey(pid, a)
            case "scroll":    out = try runScroll(pid, a)
            case "waitfor":   out = try runWaitFor(pid, a)
            case "sleep":
                let ms = try a.int("ms", 500, min: 0, max: 3_600_000)
                out = ActionOutcome(before: changeFingerprint(pid))
                if ms > 0 { usleep(UInt32(ms * 1000)) }
            default:
                throw ActionError.fail("unknown_step", "unsupported action '\(act)'")
            }
            hideAgentCursor()
            let s = settle(pid)
            var fields: [(String, Any)] = [("step", i as Any), ("do", act as Any),
                                           ("ok", true as Any), ("settledMs", s.1 as Any)]
            if let b = out.before { fields.append(("changed", changeFingerprint(pid) != b)) }
            fields += out.afterSettle?() ?? []
            fields += out.fields
            results.append(fields)
        } catch {
            var code = "unknown", msg = "\(error)"
            var suggestion = "Run `scu doctor`, then retry."
            var ex = Exit.transient
            if let e = error as? StepFailure {
                code = e.code; msg = e.message; suggestion = e.suggestion; ex = e.exit
            } else if case let ActionError.fail(c, m) = error {
                code = c; msg = m; ex = actionExit(c); suggestion = stepSuggestion(c, a)
            } else if let r = error as? ResolveError {
                // A resolver failure is a bad selector, not a flaky UI. Routing it through
                // the action mappers answered a stale ref with "run scu doctor" and exit 1,
                // which tells a conforming agent to retry the dead ref forever.
                code = r.code; msg = r.message; suggestion = resolveSuggestion(r.code); ex = .input
            }
            hideAgentCursor()
            // Report which steps already ran so the agent knows where it stopped.
            if ctx.isJSON {
                writeErr("{\"version\":\"1\",\"status\":\"error\",\"error\":{\"code\":\(jstr(code)),"
                    + "\"message\":\(jstr("step \(i): \(msg)")),\"suggestion\":\(jstr(suggestion)),"
                    + "\"failedStep\":\(i),\"completedSteps\":\(i),\"results\":\(jval(results))}}")
            } else {
                writeErr("error [\(code)] at step \(i): \(msg)\n  → \(suggestion)\n"
                    + "  \(i) step(s) completed before the failure.")
            }
            exit(ex.rawValue)
        }
    }
    emit([("steps", results as Any), ("completed", results.count as Any)]
         + changeCoverageFields()) {
        "\(results.count) step(s) completed"
    }
}

// MARK: - capture and utilities

/// Owning process of a window id, read straight from the window server so the lookup also
/// covers windows `listWindows` filters out for being small — the policy gate must not have
/// a hole the size of an authentication panel.
private func windowOwner(_ id: CGWindowID) -> (pid: pid_t, name: String)? {
    func owner(_ d: [String: Any]) -> (pid: pid_t, name: String)? {
        guard let pid = d[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        return (pid, d[kCGWindowOwnerName as String] as? String ?? "?")
    }
    if let raw = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
       let d = raw.first, let o = owner(d) { return o }
    // `.optionIncludingWindow` resolves only windows that are currently on screen: a minimized
    // window, one on another Space, or a background panel comes back empty, which turned the
    // gate into a refusal for most of what `scu windows --all` prints. That list is `.optionAll`,
    // so search it too — an id the caller just read from us always resolves.
    guard let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]],
          let d = all.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == id })
    else { return nil }
    return owner(d)
}

func cmdShot() -> Never {
    guard let outPath = opt("out") else {
        fail("bad_args", "--out is required", "Example: scu shot --window 1234 --out /tmp/win.png", .input)
    }
    guard let idStr = opt("window") else {
        fail("bad_args", "--window is required", "Run `scu windows` to list window ids.", .input)
    }
    // Distinguish absent from malformed: "--window is required" for a --window that is
    // present just sends the caller round the same loop.
    guard let id = UInt32(idStr) else {
        fail("bad_args", "--window must be a numeric window id, not '\(idStr)'",
             "Run `scu windows --all` to list the current window ids.", .input)
    }
    // Photographing a window is a strictly larger capability than driving it, so it goes
    // through the same policy gate. Addressing a window id instead of a pid used to walk
    // straight past it — a 1Password item or a SecurityAgent prompt was one id away.
    guard let owner = windowOwner(id) else {
        fail("bad_args", "No window with id \(id)",
             "Run `scu windows --all` to list the current window ids.", .input)
    }
    let ownerApp = NSRunningApplication(processIdentifier: owner.pid)
    enforceBundlePolicy(ownerApp?.bundleIdentifier ?? "", ownerApp?.localizedName ?? owner.name)

    if !CGPreflightScreenCaptureAccess() {
        fail("permission_denied", "Screen Recording is not granted",
             "Run `scu doctor` for the exact steps: System Settings > Privacy & Security > "
             + "Screen & System Audio Recording, enable your terminal, then quit and reopen it.", .config)
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", String(id), outPath]
    // screencapture writes its own diagnostics. Inherited, they interleave raw text with the
    // JSON error envelope on stderr and break the `2>&1 | jq` an agent is told to rely on.
    let errPipe = Pipe()
    p.standardError = errPipe
    p.standardOutput = Pipe()
    do {
        try p.run()
    } catch {
        // Reading terminationStatus on a Process that never launched raises an ObjC
        // exception and dies outside the 0-4 contract with no envelope at all.
        fail("capture_failed", "could not run /usr/sbin/screencapture: \(error.localizedDescription)",
             "Run `scu doctor` — it checks that the capture tool is present and executable.", .transient)
    }
    let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    p.waitUntilExit()
    guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: outPath) else {
        fail("capture_failed",
             "screencapture produced no image for window \(id)\(errText.isEmpty ? "" : ": \(errText)")",
             // screencapture usually says why. Prescribing an unhide over the top of "cannot
             // write file" sends the caller to mutate an app over a path mistake.
             errText.isEmpty
                 ? "Confirm the id with `scu windows --all`. A minimized window can return a stale "
                 + "frame; run `scu unhide --pid \(owner.pid)` first, then retry."
                 : "screencapture reported: \(errText). Fix that first — check --out names a "
                 + "writable directory, and confirm the id with `scu windows --all`.", .transient)
    }
    let attrs = try? FileManager.default.attributesOfItem(atPath: outPath)
    let bytes = (attrs?[.size] as? Int) ?? 0
    var d: [(String, Any)] = [("ok", true), ("path", outPath), ("bytes", bytes)]
    // Emit the transform an agent needs to map image pixels back to global points:
    //   globalX = originX + pixelX / scale
    if let w = listWindows(all: true).first(where: { $0.id == id }) {
        var scale = 1.0
        if let img = NSImage(contentsOfFile: outPath), let rep = img.representations.first, w.rect.width > 0 {
            scale = Double(rep.pixelsWide) / Double(w.rect.width)
        }
        d += [("originX", Int(w.rect.origin.x) as Any), ("originY", Int(w.rect.origin.y) as Any),
              ("pointW", Int(w.rect.width) as Any), ("pointH", Int(w.rect.height) as Any),
              ("scale", scale as Any)]
    }
    emit(d)
}

func cmdUnhide() -> Never {
    let pid = requirePid()
    guard let r = NSRunningApplication(processIdentifier: pid) else {
        fail("app_not_running", "No process with pid \(pid)", "Run `scu apps` to list running apps.", .input)
    }
    let wasHidden = r.isHidden
    if !r.unhide() {
        _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid),
                                         kAXHiddenAttribute as CFString, kCFBooleanFalse)
    }
    let axWins = (axAttr(AXUIElementCreateApplication(pid), kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    let minimized = axWins.filter { axBool($0, kAXMinimizedAttribute as String) == true }
    for w in minimized {
        _ = AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
    usleep(400_000)

    // Read the state back rather than counting attempts. An app can accept the AXMinimized
    // write, return success and stay minimized — measured on real apps — and reporting a
    // restore that did not happen sends the caller on to click into nothing.
    let stillMinimized = minimized.filter { axBool($0, kAXMinimizedAttribute as String) == true }.count
    let stillHidden = NSRunningApplication(processIdentifier: pid)?.isHidden ?? false

    // Some apps — Electron ones especially — drop a minimized window out of AXWindows
    // entirely. There is then no handle to clear AXMinimized on, and reporting success
    // would send the caller back into the same failure. Restoring it needs the window
    // server, which means activating the app, and activating is the one thing this tool
    // exists not to do. Say so plainly instead.
    let stillGone = axWins.isEmpty && !listWindows(all: true).filter { $0.pid == pid }.isEmpty
    if stillGone || (!minimized.isEmpty && stillMinimized == minimized.count) || (wasHidden && stillHidden) {
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "the app"
        fail("cannot_restore", "\(name) did not come back: \(stillMinimized) window(s) still "
             + "minimized\(stillHidden ? ", app still hidden" : "")\(stillGone ? ", and it hides them from accessibility" : "")",
             "Nothing here can restore it without activating the app, which would steal focus. "
             + "Click its Dock icon, or run: osascript -e 'tell application \"\(name)\" to activate'. "
             + "Reading still works once a window is on screen.", .transient)
    }
    emit([("ok", true as Any), ("wasHidden", wasHidden as Any), ("hidden", stillHidden as Any),
          ("unminimized", (minimized.count - stillMinimized) as Any),
          ("stillMinimized", stillMinimized as Any),
          ("axWindows", axWins.count as Any)] as [(String, Any)])
}

func cmdLaunch() -> Never {
    guard let name = opt("app") else {
        fail("bad_args", "--app is required", "Example: scu launch --app Notes", .input)
    }
    let ws = NSWorkspace.shared
    // LaunchServices resolves any installed app by bundle id, wherever it lives; the path
    // list only covers display names, so it names every directory an .app is normally in.
    let candidates = ["/Applications/\(name).app", "/Applications/Utilities/\(name).app",
                      "/System/Applications/\(name).app", "/System/Applications/Utilities/\(name).app",
                      "/System/Library/CoreServices/\(name).app",
                      NSHomeDirectory() + "/Applications/\(name).app"]
    guard let url = ws.urlForApplication(withBundleIdentifier: name)
            ?? candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
                .map({ URL(fileURLWithPath: $0) })
    else {
        // The old advice was "pass the exact display name" — which is what the caller just
        // did. A bundle id is the only form that resolves from any install location.
        fail("app_not_found", "Cannot locate an app named '\(name)'",
             "Get its bundle id with `osascript -e 'id of app \"\(name)\"'`, then re-run "
             + "`scu launch --app <that id>`.", .input)
    }
    // Starting a credential manager is itself the risky act; gating only what happens next
    // left `scu launch --app \"Keychain Access\"` ungated.
    enforceBundlePolicy(Bundle(url: url)?.bundleIdentifier ?? "", name)

    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = false          // the whole point: start it without stealing focus
    cfg.addsToRecentItems = false
    let sem = DispatchSemaphore(value: 0)
    var got: pid_t = -1
    ws.openApplication(at: url, configuration: cfg) { app, _ in
        got = app?.processIdentifier ?? -1
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 15)
    usleep(600_000)
    if got <= 0 {
        fail("launch_failed", "Launch of '\(name)' did not report a pid",
             "Check whether it opened with `scu apps`; some apps exceed 15s on first run.", .transient)
    }
    emit([("ok", true as Any), ("pid", Int(got) as Any), ("path", url.path as Any)] as [(String, Any)])
}

func cmdCursor() -> Never {
    let a = StepArgs()
    let (x, y) = guarded { () -> (Double, Double) in
        guard let x = try a.coord("x"), let y = try a.coord("y") else {
            throw badArgs("--x and --y are required",
                          "Example: scu cursor --x 800 --y 400 --label \"here\"")
        }
        return (x, y)
    }
    // The same reader every other verb's overlay uses, so --hold is refused with one
    // message and one bound wherever it appears; only the default differs here.
    showAgentCursor(at: CGPoint(x: x, y: y), label: opt("label") ?? "", hold: cursorHold(0.75))
    hideAgentCursor()
    emit([("ok", true as Any)] as [(String, Any)])
}

// MARK: - skill install

/// The skill ships inside the binary so the tool stays self-contained.
func runSkillInstall() -> Never {
    let explicit = opt("path")
    let targets = explicit.map { [$0] } ?? [
        NSHomeDirectory() + "/.claude/skills/scu",
        NSHomeDirectory() + "/.config/opencode/skills/scu",
    ]
    var written: [Any] = []
    for dir in targets {
        // Only populate a *default* platform directory whose parent already exists, so we
        // don't scatter config for tools the user hasn't installed. An explicit --path is a
        // request rather than a guess, so it is created outright — skipping it silently and
        // then advising "pass --path" told the caller to do what they had just done.
        if explicit == nil {
            let parent = (dir as NSString).deletingLastPathComponent
            let grand = (parent as NSString).deletingLastPathComponent
            guard FileManager.default.fileExists(atPath: grand) else { continue }
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/SKILL.md"
        do {
            try embeddedSkill.write(toFile: path, atomically: true, encoding: .utf8)
            written.append(path)
        } catch {
            fail("write_failed", "Could not write \(path)",
                 "Check permissions on \(dir), or pass --path to choose another directory.", .config)
        }
    }
    if written.isEmpty {
        fail("no_targets", "No agent platform directories found",
             "Pass --path explicitly, e.g. scu skill install --path ~/.claude/skills/scu", .config)
    }
    emit([("ok", true as Any), ("installed", written as Any)] as [(String, Any)]) {
        "Installed skill to:\n" + written.map { "  \($0)" }.joined(separator: "\n")
    }
}

// MARK: - hidden conformance hook

/// Lets the framework conformance script probe each exit code without side effects.
func runContractHook() -> Never {
    // The framework's probe calls `scu contract <code>` positionally.
    switch args.first ?? opt("code") ?? "0" {
    case "1": fail("transient_probe", "Simulated transient failure", "Retry with backoff.", .transient)
    case "2": fail("config_probe", "Simulated config failure", "Run `scu doctor`.", .config)
    case "3": fail("input_probe", "Simulated bad input", "Fix the arguments.", .input)
    case "4": fail("rate_probe", "Simulated rate limit", "Wait, then retry.", .rateLimited)
    default:  emit([("ok", true as Any)] as [(String, Any)])
    }
}
