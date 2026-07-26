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
        fix: "Open System Settings > Privacy & Security > Screen & System Audio Recording, enable \(host), then quit and reopen it. "
           + "Shortcut: open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'"))

    // 3. A GUI session must exist at all. Over SSH with nobody logged in at the console
    //    there is no window server, so every AX and capture call fails no matter what TCC
    //    says. Worth naming explicitly, because the symptom looks like a permission bug.
    let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any]
    let onConsole = (sessionDict?["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue ?? false
    let guiOK = sessionDict != nil && onConsole
    checks.append(Check(
        name: "gui_session",
        ok: guiOK,
        detail: sessionDict == nil
            ? "no window server session — nothing on screen to read or drive"
            : (onConsole ? "logged in at the console as \((sessionDict?["kCGSSessionUserNameKey"] as? String) ?? "?")"
                         : "a session exists but is not on the console (screen locked, or fast-user-switched away)"),
        fix: sessionDict == nil
            ? "Log in at the physical machine, or use a VNC/Screen Sharing session. scu drives real "
            + "on-screen UI, so it cannot work headless."
            : "Unlock the screen or switch back to this user at the console, then retry."))

    // 4. screencapture binary — the capture path shells out to it.
    let capExists = FileManager.default.isExecutableFile(atPath: "/usr/sbin/screencapture")
    checks.append(Check(
        name: "screencapture_binary",
        ok: capExists,
        detail: capExists ? "/usr/sbin/screencapture present" : "missing",
        fix: "Reinstall macOS command line tools; /usr/sbin/screencapture ships with the OS."))

    // 5. Prove the AX pipeline end-to-end against a real app rather than trusting the flag.
    var probeOK = false
    var probeDetail = "no running app to probe"
    if let target = NSWorkspace.shared.runningApplications.first(where: {
        $0.activationPolicy == .regular && $0.processIdentifier != getpid()
    }) {
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
        fix: "If Accessibility shows granted but this fails, the grant is stale: toggle \(host) off and on in "
           + "System Settings > Privacy & Security > Accessibility, then fully quit and reopen \(host)."))

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

    // Accessibility and the live probe are hard requirements; the rest degrade gracefully.
    let blocking = checks.filter {
        !$0.ok && ($0.name == "accessibility" || $0.name == "ax_live_probe" || $0.name == "gui_session")
    }
    let healthy = checks.allSatisfy { $0.ok }

    if ctx.isJSON {
        let arr: [Any] = checks.map { c in
            [("name", c.name as Any), ("ok", c.ok as Any),
             ("detail", c.detail as Any), ("fix", c.fix as Any)] as [(String, Any)]
        }
        let payload: [(String, Any)] = [
            ("healthy", healthy), ("host_application", host), ("checks", arr),
        ]
        print("{\"version\":\"1\",\"status\":\(jstr(healthy ? "success" : "partial_success")),\"data\":\(jval(payload))}")
    } else {
        print("scu doctor — permissions are granted to: \(host)\n")
        for c in checks {
            print("  \(c.ok ? "✓" : "✗") \(c.name): \(c.detail)")
            if !c.ok { print("      fix: \(c.fix)") }
        }
        print("")
        print(healthy ? "All checks passed." : "\(checks.filter { !$0.ok }.count) check(s) need attention.")
    }
    // Exit 2 (config) only when something blocking is wrong — an agent reads that as
    // "fix setup, do not retry".
    exit(blocking.isEmpty ? Exit.ok.rawValue : Exit.config.rawValue)
}
