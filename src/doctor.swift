// doctor — diagnose the two macOS permissions bgcu cannot work without.
//
// This is the single most valuable command in the tool. Without Accessibility, every
// action fails with an opaque AX error code; without Screen Recording, `shot` silently
// produces a desktop-wallpaper image instead of the window. Both are granted to the
// *terminal application running bgcu*, not to bgcu itself, which is the part everyone
// gets wrong.

import Cocoa
import ApplicationServices

struct Check {
    let name: String
    let ok: Bool
    let detail: String
    let fix: String
}

/// Identify the process that owns our TTY, since that is the app the user must grant.
func hostApplicationName() -> String {
    // TERM_PROGRAM is set by every mainstream terminal; fall back to the parent process.
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
        fix: "Open System Settings > Privacy & Security > Accessibility, enable \(host), then restart it. "
           + "Shortcut: open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'"))

    // 2. Screen Recording — only needed for `shot`, so a miss is a warning not a failure.
    let screenOK = CGPreflightScreenCaptureAccess()
    checks.append(Check(
        name: "screen_recording",
        ok: screenOK,
        detail: screenOK ? "granted to \(host)" : "NOT granted to \(host) — `shot` will not capture window content",
        fix: "Open System Settings > Privacy & Security > Screen & System Audio Recording, enable \(host), then quit and reopen it. "
           + "Shortcut: open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'"))

    // 3. screencapture binary — the capture path shells out to it.
    let capExists = FileManager.default.isExecutableFile(atPath: "/usr/sbin/screencapture")
    checks.append(Check(
        name: "screencapture_binary",
        ok: capExists,
        detail: capExists ? "/usr/sbin/screencapture present" : "missing",
        fix: "Reinstall macOS command line tools; /usr/sbin/screencapture ships with the OS."))

    // 4. Prove the AX pipeline end-to-end against a real app rather than trusting the flag.
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

    // 5. Cache directory must be writable for --diff.
    let cache = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/bgcu", isDirectory: true)
    try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let cacheOK = FileManager.default.isWritableFile(atPath: cache.path)
    checks.append(Check(
        name: "cache_writable",
        ok: cacheOK,
        detail: cacheOK ? cache.path : "cannot write \(cache.path)",
        fix: "Run: mkdir -p ~/Library/Caches/bgcu && chmod u+rwx ~/Library/Caches/bgcu"))

    // Accessibility and the live probe are hard requirements; the rest degrade gracefully.
    let blocking = checks.filter { !$0.ok && ($0.name == "accessibility" || $0.name == "ax_live_probe") }
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
        print("bgcu doctor — permissions are granted to: \(host)\n")
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
