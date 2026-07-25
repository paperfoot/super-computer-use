// Command bodies. Each ends by calling emit/emitText (success) or fail (error), so
// every stdout path respects the output format and every error lands on stderr.

import Cocoa
import ApplicationServices

// MARK: - shared

func actionSuggestion(_ code: String) -> String {
    switch code {
    case "press_failed":
        return "Run `bgcu actions --ref …` to see supported actions, then `bgcu perform --action NAME`. If the app ignores AX, try --mode event."
    case "setvalue_failed":
        return "The element is probably read-only. Click it first, then use `bgcu type --text …`."
    case "select_failed", "no_value", "text_not_found":
        return "Confirm the element holds that text with `bgcu axdump --grep …` before selecting."
    case "unknown_key":
        return "Use a key name such as return, tab, escape, up, or a chord like cmd+shift+a."
    case "no_geometry":
        return "The element has no on-screen position. Target a visible child — see `bgcu axdump`."
    case "timeout":
        return "Raise --timeout, or verify the expected text with `bgcu axdump --grep …`."
    case "bad_script", "unknown_step":
        return "Pass a JSON array of steps, e.g. [{\"do\":\"click\",\"query\":\"role=AXButton;nth=0\"}]."
    default:
        return "Run `bgcu doctor` to verify permissions, then retry."
    }
}

/// UI-state failures are worth retrying after a settle; argument mistakes are not.
func actionExit(_ code: String) -> Exit {
    switch code {
    case "bad_args", "bad_script", "unknown_key", "unknown_step", "text_not_found", "no_geometry":
        return .input
    default:
        return .transient
    }
}

/// Translate an action-primitive throw into the CLI error contract.
func guarded<T>(_ body: () throws -> T) -> T {
    do { return try body() }
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
        hideAgentCursor(); fail("unknown", "\(error)", "Run `bgcu doctor`, then retry.", .transient)
    }
}

/// Every mutating command ends the same way: drop the cursor, settle, report.
func afterAction(_ pid: pid_t, _ extra: [(String, Any)] = []) -> Never {
    hideAgentCursor()
    let s = settle(pid)
    emit([("ok", true as Any), ("settled", s.0 as Any), ("settledMs", s.1 as Any)] + extra)
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
             "Run `bgcu doctor` for the exact steps, then restart your terminal.", .config)
    }
    let app = AXUIElementCreateApplication(pid)
    let wins = (axAttr(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "the app"

    if wins.isEmpty {
        let minimized = listWindows(all: true).filter { $0.pid == pid }
        if !minimized.isEmpty {
            fail("window_minimized", "\(name) has no open window; \(minimized.count) minimized or off-screen",
                 "Run `bgcu unhide --pid \(pid)` to restore it, then retry.", .transient)
        }
        fail("no_window", "\(name) is running but has no open window",
             "Open a window first — e.g. `bgcu key --pid \(pid) --key cmd+n`, or click its Dock icon. "
             + "Background-launched apps often start with no window.", .transient)
    }
    fail("no_ax_tree", "\(name) exposes a window but no readable accessibility tree",
         "Try `bgcu axdump --pid \(pid) --enhanced`. If that is still empty, the app does not "
         + "publish AX data — fall back to `bgcu shot --window …` and read it visually.", .transient)
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

func cmdAxdump() -> Never {
    let pid = requirePid()
    let nodes = collectNodes(pid: pid, maxDepth: intOpt("depth", 16),
                             maxNodes: intOpt("max", 4000), includeMenus: flag("menus"))
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
        let url = cacheURL(pid)
        let prev = (try? String(contentsOf: url, encoding: .utf8))?.components(separatedBy: "\n") ?? []
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        if prev.isEmpty {
            emitText("(no cached tree for pid \(pid); full dump follows)\n" + lines.joined(separator: "\n"))
        }
        // Compare on everything after the volatile leading index.
        func key(_ l: String) -> String {
            guard let r = l.range(of: "] ") else { return l }
            return String(l[r.upperBound...])
        }
        let prevKeys = Set(prev.map(key)), nowKeys = Set(lines.map(key))
        let added = lines.filter { !prevKeys.contains(key($0)) }
        let removed = prev.filter { !$0.isEmpty && !nowKeys.contains(key($0)) }
        if added.isEmpty && removed.isEmpty { emitText("(no change)") }
        emitText((added.map { "+ \($0)" } + removed.map { "- \($0)" }).joined(separator: "\n"))
    }

    try? lines.joined(separator: "\n").write(to: cacheURL(pid), atomically: true, encoding: .utf8)
    emitText(lines.joined(separator: "\n"))
}

func cmdFind() -> Never {
    let pid = requirePid()
    guard let needle = opt("text")?.lowercased(), !needle.isEmpty else {
        // Swift's contains("") is false, so an empty needle would silently match nothing.
        fail("bad_args", "--text must be a non-empty string",
             "Example: bgcu find --app Notes --text \"Shopping\". To list everything, use `bgcu axdump`.", .input)
    }
    let nodes = collectNodes(pid: pid, maxDepth: intOpt("depth", 20),
                             maxNodes: intOpt("max", 6000), includeMenus: flag("menus"))
    let hits = nodes.filter {
        $0.text.lowercased().contains(needle) && (!flag("actionable") || $0.actionable)
    }
    let data: [Any] = hits.map { n in
        [("index", n.index as Any), ("ref", n.ref as Any), ("role", n.role as Any),
         ("text", String(n.text.prefix(200)) as Any), ("path", n.path as Any),
         ("centreX", (n.centre.map { Int($0.x) } ?? -1) as Any),
         ("centreY", (n.centre.map { Int($0.y) } ?? -1) as Any),
         ("actions", axActions(n.el) as Any)] as [(String, Any)]
    }
    emit([("matches", data as Any), ("count", hits.count as Any)] as [(String, Any)]) {
        hits.isEmpty ? "(no match for '\(needle)')" : hits.map { n in
            let c = n.centre.map { " centre=\(Int($0.x)),\(Int($0.y))" } ?? ""
            let a = axActions(n.el).map { $0.replacingOccurrences(of: "AX", with: "") }.joined(separator: ",")
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

// MARK: - act

func cmdClick() -> Never {
    let pid = requirePid()
    var pt: CGPoint?
    var node: Node?
    var label = "click"
    if opt("ref") != nil || opt("index") != nil || opt("query") != nil {
        let n = resolveNode(pid); node = n; pt = n.centre; label = n.label
    } else if let x = Double(opt("x") ?? ""), let y = Double(opt("y") ?? "") {
        pt = CGPoint(x: x, y: y)
    } else {
        fail("bad_args", "No target given",
             "Pass --query 'role=AXButton;nth=0', or --ref from `bgcu find`, or --x/--y.", .input)
    }
    flash(pt, label)

    let mode = opt("mode") ?? "ax"
    if mode == "ax" {
        if let n = node {
            guarded { try pressElement(n) }
        } else if let p = pt {
            var found: AXUIElement?
            let e = AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid),
                                                     Float(p.x), Float(p.y), &found)
            guard e == .success, let f = found else {
                hideAgentCursor()
                fail("hit_test_failed", "No element at \(Int(p.x)),\(Int(p.y)) (AX error \(e.rawValue))",
                     "Check the coordinate against `bgcu axdump`, or target by --query instead.", .input)
            }
            guarded { try pressElement(Node(el: f, index: -1,
                role: axStr(f, kAXRoleAttribute as String) ?? "?", ident: "", title: "", value: "",
                desc: "", pos: nil, size: nil, path: "", actionable: true)) }
        }
    } else {
        guard let p = pt else {
            hideAgentCursor()
            fail("bad_args", "event mode needs a point",
                 "Pass --x and --y, or use the default ax mode with --query.", .input)
        }
        synthClick(pid: pid, at: p, button: opt("button") ?? "left", count: intOpt("count", 1))
    }
    afterAction(pid, [("mode", mode as Any)])
}

func cmdSetValue() -> Never {
    let pid = requirePid()
    guard let v = opt("value") else {
        fail("bad_args", "--value is required",
             "Example: bgcu setvalue --query 'role=AXTextField;nth=0' --value hello", .input)
    }
    let n = resolveNode(pid)
    flash(n.centre, "set value")
    guarded { try setValue(n, v) }
    afterAction(pid, [("ref", n.ref as Any)])
}

func cmdSelectText() -> Never {
    let pid = requirePid()
    guard let t = opt("text") else {
        fail("bad_args", "--text is required",
             "Example: bgcu selecttext --query 'role=AXTextArea' --text hello", .input)
    }
    let n = resolveNode(pid)
    flash(n.centre, "select")
    guarded { try selectText(n, needle: t, mode: opt("cursor") ?? "select") }
    hideAgentCursor()
    emit([("ok", true as Any), ("ref", n.ref as Any)] as [(String, Any)])
}

func cmdType() -> Never {
    let pid = requirePid()
    guard let t = opt("text") else {
        fail("bad_args", "--text is required", "Example: bgcu type --app Notes --text \"hello\"", .input)
    }
    typeText(pid: pid, text: t)
    afterAction(pid)
}

func cmdKey() -> Never {
    let pid = requirePid()
    guard let k = opt("key") else {
        fail("bad_args", "--key is required",
             "Example: bgcu key --key return, or --key cmd+shift+a", .input)
    }
    guarded { try sendKey(pid: pid, chord: k) }
    afterAction(pid)
}

func cmdScroll() -> Never {
    let pid = requirePid()
    guard let dir = opt("direction") else {
        fail("bad_args", "--direction is required",
             "Pass --direction up, down, left, or right.", .input)
    }
    let n = resolveNode(pid)
    guard let c = n.centre else {
        fail("no_geometry", "Element \(n.ref) has no on-screen position",
             "Target a visible child instead — see `bgcu axdump`.", .input)
    }
    flash(c, "scroll \(dir)")
    // An element's own AX scroll action is more reliable than wheel events in the background.
    let want = "AXScroll" + dir.prefix(1).uppercased() + dir.dropFirst()
    if axActions(n.el).contains(want) {
        _ = AXUIElementPerformAction(n.el, want as CFString)
    } else {
        scrollAt(pid: pid, p: c, dir: dir, pages: intOpt("pages", 1))
    }
    afterAction(pid)
}

func cmdDrag() -> Never {
    let pid = requirePid()
    var from: CGPoint?, to: CGPoint?
    if let fr = opt("from-ref") { from = resolveNode(pid, refOverride: fr).centre }
    else if let x = Double(opt("from-x") ?? ""), let y = Double(opt("from-y") ?? "") {
        from = CGPoint(x: x, y: y)
    }
    if let tr = opt("to-ref") { to = resolveNode(pid, refOverride: tr).centre }
    else if let x = Double(opt("to-x") ?? ""), let y = Double(opt("to-y") ?? "") {
        to = CGPoint(x: x, y: y)
    }
    guard let f = from, let t = to else {
        fail("bad_args", "drag needs a source and a destination",
             "Pass --from-ref A --to-ref B, or --from-x/--from-y with --to-x/--to-y.", .input)
    }
    flash(f, "drag")
    dragFromTo(pid: pid, from: f, to: t)
    afterAction(pid)
}

func cmdPerform() -> Never {
    let pid = requirePid()
    guard let a = opt("action") else {
        fail("bad_args", "--action is required",
             "Run `bgcu actions --query …` to list what the element supports.", .input)
    }
    let n = resolveNode(pid)
    flash(n.centre, a.replacingOccurrences(of: "AX", with: ""))
    let e = AXUIElementPerformAction(n.el, a as CFString)
    if e != .success {
        hideAgentCursor()
        let avail = axActions(n.el)
        fail("action_failed", "\(a) rejected by \(n.ref) (AX error \(e.rawValue))",
             avail.isEmpty ? "This element exposes no actions; target a different one via `bgcu axdump --actionable`."
                           : "Supported here: \(avail.joined(separator: ", ")). Pick one of those.", .transient)
    }
    afterAction(pid)
}

// MARK: - flow

func cmdWaitFor() -> Never {
    let pid = requirePid()
    let timeout = Double(opt("timeout") ?? "") ?? 10
    let wantGone = flag("gone")
    let needle = opt("text")?.lowercased()
    let wantRef = opt("ref")
    if needle == nil && wantRef == nil {
        fail("bad_args", "waitfor needs --text or --ref",
             "Example: bgcu waitfor --app Safari --text \"Sign in\" --timeout 15", .input)
    }
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        let nodes = collectNodes(pid: pid, maxDepth: intOpt("depth", 18), maxNodes: intOpt("max", 4000))
        let hit = wantRef != nil ? nodes.first { $0.ref == wantRef! }
                                 : nodes.first { $0.text.lowercased().contains(needle!) }
        if (hit != nil) != wantGone {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            var d: [(String, Any)] = [("ok", true), ("waitedMs", ms), ("gone", wantGone)]
            if let h = hit {
                d += [("ref", h.ref as Any), ("index", h.index as Any),
                      ("text", String(h.text.prefix(160)) as Any)]
            }
            emit(d)
        }
        usleep(250_000)
    }
    fail("timeout", "Condition not met within \(Int(timeout))s",
         wantGone ? "The element is still present. Raise --timeout, or check with `bgcu axdump --grep …`."
                  : "Raise --timeout, or verify the expected text with `bgcu axdump --grep …`.", .transient)
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
        // Reading a piped script is not an interactive prompt.
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
        func node() throws -> Node {
            if let q = step["query"] as? String { return try resolveQuery(pid, q) }
            guard let r = step["ref"] as? String else {
                throw ActionError.fail("bad_args", "step \(i) needs a ref or query")
            }
            return try resolveNodeThrowing(pid, ref: r)
        }
        do {
            switch act {
            case "click":
                let n = try node(); flash(n.centre, n.label); try pressElement(n); hideAgentCursor()
            case "setvalue":
                let n = try node(); flash(n.centre, "set value")
                try setValue(n, (step["value"] as? String) ?? ""); hideAgentCursor()
            case "type":
                typeText(pid: pid, text: (step["text"] as? String) ?? "")
            case "key":
                try sendKey(pid: pid, chord: (step["key"] as? String) ?? "")
            case "scroll":
                let n = try node()
                guard let c = n.centre else {
                    throw ActionError.fail("no_geometry", "step \(i): element has no position")
                }
                flash(c, "scroll")
                scrollAt(pid: pid, p: c, dir: (step["direction"] as? String) ?? "down",
                         pages: (step["pages"] as? Int) ?? 1)
                hideAgentCursor()
            case "waitfor":
                let needle = ((step["text"] as? String) ?? "").lowercased()
                let gone = (step["gone"] as? Bool) ?? false
                let to = (step["timeout"] as? Double) ?? 10
                let t0 = Date(); var met = false
                while Date().timeIntervalSince(t0) < to {
                    let present = collectNodes(pid: pid, maxDepth: 18, maxNodes: 4000)
                        .contains { $0.text.lowercased().contains(needle) }
                    if present != gone { met = true; break }
                    usleep(250_000)
                }
                if !met {
                    throw ActionError.fail("timeout",
                        "step \(i): '\(needle)' never became \(gone ? "absent" : "present")")
                }
            case "sleep":
                usleep(UInt32(((step["ms"] as? Int) ?? 500) * 1000))
            default:
                throw ActionError.fail("unknown_step", "step \(i): unsupported action '\(act)'")
            }
            let s = settle(pid)
            results.append([("step", i as Any), ("do", act as Any), ("ok", true as Any),
                            ("settledMs", s.1 as Any)] as [(String, Any)])
        } catch {
            var code = "unknown", msg = "\(error)"
            if case let ActionError.fail(c, m) = error { code = c; msg = m }
            if let r = error as? ResolveError { code = r.code; msg = r.message }
            hideAgentCursor()
            // Report which steps already ran so the agent knows where it stopped.
            if ctx.isJSON {
                writeErr("{\"version\":\"1\",\"status\":\"error\",\"error\":{\"code\":\(jstr(code)),"
                    + "\"message\":\(jstr(msg)),\"suggestion\":\(jstr(actionSuggestion(code))),"
                    + "\"failedStep\":\(i),\"completedSteps\":\(i),\"results\":\(jval(results))}}")
            } else {
                writeErr("error [\(code)] at step \(i): \(msg)\n  → \(actionSuggestion(code))\n"
                    + "  \(i) step(s) completed before the failure.")
            }
            exit(actionExit(code).rawValue)
        }
    }
    emit([("steps", results as Any), ("completed", results.count as Any)] as [(String, Any)]) {
        "\(results.count) step(s) completed"
    }
}

// MARK: - capture and utilities

func cmdShot() -> Never {
    guard let outPath = opt("out") else {
        fail("bad_args", "--out is required", "Example: bgcu shot --window 1234 --out /tmp/win.png", .input)
    }
    guard let idStr = opt("window"), let id = UInt32(idStr) else {
        fail("bad_args", "--window is required", "Run `bgcu windows` to list window ids.", .input)
    }
    if !CGPreflightScreenCaptureAccess() {
        fail("permission_denied", "Screen Recording is not granted",
             "Run `bgcu doctor` for the exact steps: System Settings > Privacy & Security > "
             + "Screen & System Audio Recording, enable your terminal, then quit and reopen it.", .config)
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", String(id), outPath]
    try? p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: outPath) else {
        fail("capture_failed", "screencapture produced no image for window \(id)",
             "Confirm the id with `bgcu windows --all`. A minimized window can return a stale frame; "
             + "run `bgcu unhide` first.", .transient)
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
        fail("app_not_running", "No process with pid \(pid)", "Run `bgcu apps` to list running apps.", .input)
    }
    let wasHidden = r.isHidden
    if !r.unhide() {
        _ = AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid),
                                         kAXHiddenAttribute as CFString, kCFBooleanFalse)
    }
    var unminimized = 0
    if let wins = axAttr(AXUIElementCreateApplication(pid), kAXWindowsAttribute as String) as? [AXUIElement] {
        for w in wins where axBool(w, kAXMinimizedAttribute as String) == true {
            _ = AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            unminimized += 1
        }
    }
    usleep(400_000)
    emit([("ok", true as Any), ("wasHidden", wasHidden as Any),
          ("unminimized", unminimized as Any)] as [(String, Any)])
}

func cmdLaunch() -> Never {
    guard let name = opt("app") else {
        fail("bad_args", "--app is required", "Example: bgcu launch --app Notes", .input)
    }
    let ws = NSWorkspace.shared
    let candidates = ["/Applications/\(name).app", "/System/Applications/\(name).app",
                      "/System/Applications/Utilities/\(name).app"]
    guard let url = ws.urlForApplication(withBundleIdentifier: name)
            ?? candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
                .map({ URL(fileURLWithPath: $0) })
    else {
        fail("app_not_found", "Cannot locate an app named '\(name)'",
             "Pass the exact display name (e.g. \"Notes\") or a bundle id (e.g. com.apple.Notes).", .input)
    }
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
             "Check whether it opened with `bgcu apps`; some apps exceed 15s on first run.", .transient)
    }
    emit([("ok", true as Any), ("pid", Int(got) as Any), ("path", url.path as Any)] as [(String, Any)])
}

func cmdCursor() -> Never {
    guard let x = Double(opt("x") ?? ""), let y = Double(opt("y") ?? "") else {
        fail("bad_args", "--x and --y are required",
             "Example: bgcu cursor --x 800 --y 400 --label \"here\"", .input)
    }
    showAgentCursor(at: CGPoint(x: x, y: y), label: opt("label") ?? "",
                    hold: Double(opt("hold") ?? "") ?? 0.75)
    hideAgentCursor()
    emit([("ok", true as Any)] as [(String, Any)])
}

// MARK: - skill install

/// The skill ships inside the binary so the tool stays self-contained.
func runSkillInstall() -> Never {
    let targets = opt("path").map { [$0] } ?? [
        NSHomeDirectory() + "/.claude/skills/bgcu",
        NSHomeDirectory() + "/.config/opencode/skills/bgcu",
    ]
    var written: [Any] = []
    for dir in targets {
        // Only populate a platform directory whose parent already exists, so we don't
        // scatter config for tools the user hasn't installed.
        let parent = (dir as NSString).deletingLastPathComponent
        let grand = (parent as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: grand) else { continue }
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
             "Pass --path explicitly, e.g. bgcu skill install --path ~/.claude/skills/bgcu", .config)
    }
    emit([("ok", true as Any), ("installed", written as Any)] as [(String, Any)]) {
        "Installed skill to:\n" + written.map { "  \($0)" }.joined(separator: "\n")
    }
}

// MARK: - hidden conformance hook

/// Lets the framework conformance script probe each exit code without side effects.
func runContractHook() -> Never {
    // The framework's probe calls `bgcu contract <code>` positionally.
    switch args.first ?? opt("code") ?? "0" {
    case "1": fail("transient_probe", "Simulated transient failure", "Retry with backoff.", .transient)
    case "2": fail("config_probe", "Simulated config failure", "Run `bgcu doctor`.", .config)
    case "3": fail("input_probe", "Simulated bad input", "Fix the arguments.", .input)
    case "4": fail("rate_probe", "Simulated rate limit", "Wait, then retry.", .rateLimited)
    default:  emit([("ok", true as Any)] as [(String, Any)])
    }
}
