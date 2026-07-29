// doctor — diagnose the two macOS permissions scu cannot work without.
//
// This is the single most valuable command in the tool. Without Accessibility, every
// action fails with an opaque AX error code; without Screen Recording, `shot` silently
// produces a desktop-wallpaper image instead of the window. Both are granted to the
// *application running scu*, not to scu itself, which is the part everyone gets wrong —
// and over SSH that application is sshd, not a terminal.
//
// It also checks that a GUI session exists at all. Headless and remote runs fail for a
// reason that looks exactly like a permission problem but is not.

import Cocoa
import ApplicationServices

struct Check {
    let name: String
    let ok: Bool
    let detail: String
    let fix: String
}

/// True when this process arrived over SSH, which changes who owns the TCC grant.
func isRemoteSession() -> Bool {
    let env = ProcessInfo.processInfo.environment
    return env["SSH_CONNECTION"] != nil || env["SSH_TTY"] != nil || env["SSH_CLIENT"] != nil
}

func hostApplicationName() -> String {
    // Over SSH the responsible process is sshd, not a terminal app — TCC attributes the
    // grant to whatever launched us, and naming the wrong app sends people to the wrong
    // row in System Settings.
    if isRemoteSession() { return "sshd (this is an SSH session)" }
    // TERM_PROGRAM is set by every mainstream terminal.
    if let t = ProcessInfo.processInfo.environment["TERM_PROGRAM"], !t.isEmpty {
        switch t {
        case "iTerm.app": return "iTerm"
        case "Apple_Terminal": return "Terminal"
        case "vscode": return "Visual Studio Code"
        default: return t.replacingOccurrences(of: ".app", with: "")
        }
    }
    return "your terminal application"
}

func runDoctor() -> Never {
    let host = hostApplicationName()
    var checks: [Check] = []

    // 1. Accessibility — required for reading the AX tree and for every action.
    let axTrusted = AXIsProcessTrusted()
    checks.append(Check(
        name: "accessibility",
        ok: axTrusted,
        detail: axTrusted ? "granted to \(host)" : "NOT granted to \(host)",
        fix: isRemoteSession()
            ? "Over SSH the grant belongs to sshd, not to a terminal app. Add "
            + "/usr/libexec/sshd-keygen-wrapper (or sshd) under System Settings > Privacy & Security > "
            + "Accessibility on the Mac being controlled. Consider whether you want every SSH user to "
            + "have full UI control before doing that — running scu in a local session avoids the question."
            : "Open System Settings > Privacy & Security > Accessibility, enable \(host), then restart it. "
            + "Shortcut: open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'"))

    // 2. Screen Recording — only needed for `shot`, so a miss is a warning not a failure.
    let screenOK = CGPreflightScreenCaptureAccess()
    checks.append(Check(
        name: "screen_recording",
        ok: screenOK,
        detail: screenOK ? "granted to \(host)" : "NOT granted to \(host) — `shot` will not capture window content",
        // Same SSH split as accessibility: there is no sshd window to "quit and reopen",
        // and the row to tick is the sshd binary, not a terminal.
        fix: isRemoteSession()
            ? "Over SSH the grant belongs to sshd, not to a terminal app. Add "
            + "/usr/libexec/sshd-keygen-wrapper (or sshd) under System Settings > Privacy & Security > "
            + "Screen & System Audio Recording on the Mac being controlled, then reconnect."
            : "Open System Settings > Privacy & Security > Screen & System Audio Recording, enable \(host), then quit and reopen it. "
            + "Shortcut: open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'"))

    // 3. A GUI session must exist at all. Over SSH with nobody logged in at the console
    //    there is no window server, so every AX and capture call fails no matter what TCC
    //    says. Worth naming explicitly, because the symptom looks like a permission bug.
    let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any]
    let onConsole = (sessionDict?["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue ?? false
    // A locked screen keeps `kCGSSessionOnConsoleKey` true, so checking the console alone
    // reported healthy on a machine where no app would publish a tree. Verified live: with
    // the screen locked, TextEdit exposed a window and no AX tree while doctor was all-green.
    let locked = screenIsLocked()
    let guiOK = sessionDict != nil && onConsole && !locked
    checks.append(Check(
        name: "gui_session",
        ok: guiOK,
        detail: sessionDict == nil
            ? "no window server session — nothing on screen to read or drive"
            : locked ? "the screen is locked, so apps publish little or no accessibility data"
            : (onConsole ? "logged in at the console as \((sessionDict?["kCGSSessionUserNameKey"] as? String) ?? "?")"
                         : "a session exists but is not on the console (fast-user-switched away)"),
        fix: sessionDict == nil
            ? "Log in at the physical machine, or use a VNC/Screen Sharing session. scu drives real "
            + "on-screen UI, so it cannot work headless."
            : "Unlock the screen or switch back to this user at the console, then retry."))

    // 4. screencapture binary — the capture path shells out to it.
    let capExists = FileManager.default.isExecutableFile(atPath: "/usr/sbin/screencapture")
    checks.append(Check(
        name: "screencapture_binary",
        ok: capExists,
        detail: capExists ? "/usr/sbin/screencapture present" : "missing or not executable",
        // It lives on the sealed system volume, so Command Line Tools cannot put it back —
        // sending people to xcode-select would waste their time.
        fix: "Check with: ls -l /usr/sbin/screencapture. It ships on the sealed system volume, so "
           + "Command Line Tools cannot restore it: reinstall macOS from Recovery, or restore the "
           + "system volume from a backup."))

    // 5. Prove the AX pipeline end-to-end against a real app rather than trusting the flag.
    var probeOK = false
    var probeDetail = "no running app to probe"
    var probed = false
    if let target = NSWorkspace.shared.runningApplications.first(where: {
        $0.activationPolicy == .regular && $0.processIdentifier != getpid()
    }) {
        probed = true
        let el = AXUIElementCreateApplication(target.processIdentifier)
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
        probeOK = (err == .success)
        let name = target.localizedName ?? "?"
        probeDetail = probeOK
            ? "read AX role from \(name) (pid \(target.processIdentifier))"
            : "AXUIElementCopyAttributeValue on \(name) returned \(err.rawValue)"
    }
    checks.append(Check(
        name: "ax_live_probe",
        ok: probeOK,
        detail: probeDetail,
        // "Toggle the grant" is wrong advice when there was no app to probe in the first place.
        fix: probed
            ? "If Accessibility shows granted but this fails, the grant is stale: toggle \(host) off and on in "
            + "System Settings > Privacy & Security > Accessibility, then fully quit and reopen \(host)."
            : "No regular app was running to probe. Log in at the console, open any app (Finder counts), "
            + "then run `scu doctor` again."))

    // 6. Cache directory must be writable for --diff.
    let cache = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/scu", isDirectory: true)
    try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let cacheOK = FileManager.default.isWritableFile(atPath: cache.path)
    checks.append(Check(
        name: "cache_writable",
        ok: cacheOK,
        detail: cacheOK ? cache.path : "cannot write \(cache.path)",
        fix: "Run: mkdir -p ~/Library/Caches/scu && chmod u+rwx ~/Library/Caches/scu"))

    // Accessibility, the live probe and a console session are hard requirements; the rest
    // degrade gracefully — only `shot` needs Screen Recording, only --diff needs the cache.
    let blocking = checks.filter {
        !$0.ok && ($0.name == "accessibility" || $0.name == "ax_live_probe" || $0.name == "gui_session")
    }
    let healthy = checks.allSatisfy { $0.ok }
    // One verdict drives the status string, the stderr envelope and the exit code, so an
    // agent branching on any of the three gets the same answer. A non-blocking miss stays
    // a success with `healthy:false` in the data — degraded, but every command still works.
    var verdict: CLIError?
    if let first = blocking.first {
        verdict = CLIError("setup_incomplete",
                           "blocking checks failed: " + blocking.map { $0.name }.joined(separator: ", "),
                           first.fix, .config)
    }

    if ctx.isJSON {
        let arr: [Any] = checks.map { c in
            [("name", c.name as Any), ("ok", c.ok as Any),
             ("detail", c.detail as Any), ("fix", c.fix as Any)] as [(String, Any)]
        }
        let payload: [(String, Any)] = [
            ("healthy", healthy), ("host_application", host), ("checks", arr),
        ]
        // The report is the useful output even when the verdict is an error, so it stays on
        // stdout; the envelope then carries the documented error object alongside it.
        var envelope = "{\"version\":\"1\",\"status\":\(jstr(verdict == nil ? "success" : "error"))"
            + ",\"data\":\(jval(payload))"
        if let v = verdict { envelope += ",\"error\":\(jerr(v))" }
        print(envelope + "}")
    } else if !ctx.quiet {
        print("scu doctor — permissions are granted to: \(host)\n")
        for c in checks {
            print("  \(c.ok ? "✓" : "✗") \(c.name): \(c.detail)")
            if !c.ok { print("      fix: \(c.fix)") }
        }
        print("")
        print(healthy ? "All checks passed." : "\(checks.filter { !$0.ok }.count) check(s) need attention.")
    }
    // Exit 2 (config) only when something blocking is wrong — an agent reads that as
    // "fix setup, do not retry". Routed through fail() so the nonzero exit also leaves a
    // code and a suggestion on stderr, like every other command in the tool.
    if let v = verdict { fail(v) }
    exit(Exit.ok.rawValue)
}
