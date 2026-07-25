import Cocoa
import ApplicationServices

// Action primitives, shared by the CLI dispatch and by `batch`.

// MARK: - action primitives, reused by both the CLI and `batch`

enum ActionError: Error { case fail(String, String) }

/// Actions that mean "activate this", in preference order.
///
/// The fallback list is deliberately closed. Music's sidebar rows, for example, expose
/// only AXShowDefaultUI/AXShowAlternateUI — firing the first available action there would
/// toggle chrome rather than select the row, and on other elements could hit something
/// destructive. If none of these exist we fail with the real action list instead of
/// guessing.
private let activationActions = [
    kAXPressAction as String,
    kAXConfirmAction as String,
    kAXPickAction as String,
    "AXOpen",
]

func pressElement(_ n: Node) throws {
    let avail = axActions(n.el)
    for candidate in activationActions where avail.contains(candidate) {
        if AXUIElementPerformAction(n.el, candidate as CFString) == .success { return }
    }
    // Nothing activation-like worked. AXPress may still exist but be refused.
    let err = AXUIElementPerformAction(n.el, kAXPressAction as CFString)
    if err == .success { return }
    throw ActionError.fail("press_failed",
        "no activation action succeeded on \(n.role) (AXPress error \(err.rawValue)); "
        + "exposed actions: \(avail.isEmpty ? "none" : avail.joined(separator: ", "))")
}

/// Synthetic clicks. `postToPid` keeps the event out of the global stream so the user's
/// focus is untouched — but Catalyst/Electron apps frequently drop them, which is why
/// AXPress is the default path.
func synthClick(pid: pid_t, at p: CGPoint, button: String, count: Int) {
    let (dn, up): (CGEventType, CGEventType) = button == "right"
        ? (.rightMouseDown, .rightMouseUp)
        : (button == "middle" ? (.otherMouseDown, .otherMouseUp) : (.leftMouseDown, .leftMouseUp))
    let b: CGMouseButton = button == "right" ? .right : (button == "middle" ? .center : .left)
    for i in 1...max(1, count) {
        guard let d = CGEvent(mouseEventSource: nil, mouseType: dn, mouseCursorPosition: p, mouseButton: b),
              let u = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: p, mouseButton: b)
        else { return }
        // clickState drives double/triple-click recognition in AppKit.
        d.setIntegerValueField(.mouseEventClickState, value: Int64(i))
        u.setIntegerValueField(.mouseEventClickState, value: Int64(i))
        d.postToPid(pid); usleep(40_000); u.postToPid(pid)
        if i < count { usleep(60_000) }
    }
}

/// Key chords like "cmd+shift+a" or bare names like "return".
let keyCodes: [String: CGKeyCode] = [
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
    "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34,
    "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15,
    "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
    "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "comma": 43, "period": 47, "slash": 44, "minus": 27, "equal": 24,
]
func sendKey(pid: pid_t, chord: String) throws {
    var flags: CGEventFlags = []
    var key = ""
    for part in chord.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
        switch part {
        case "cmd", "command", "super", "meta": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "alt", "option", "opt": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        case "fn", "function": flags.insert(.maskSecondaryFn)
        default: key = part
        }
    }
    guard let code = keyCodes[key] else {
        throw ActionError.fail("unknown_key", "no keycode for '\(key)' in chord '\(chord)'")
    }
    guard let d = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
          let u = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
        throw ActionError.fail("event_failed", "could not create key event")
    }
    d.flags = flags; u.flags = flags
    d.postToPid(pid); usleep(25_000); u.postToPid(pid)
}

func typeText(pid: pid_t, text: String) {
    for ch in text {
        var u = Array(String(ch).utf16)
        guard let d = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
        d.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
        up.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
        d.postToPid(pid); usleep(6_000); up.postToPid(pid); usleep(6_000)
    }
}

func setValue(_ n: Node, _ v: String) throws {
    let err = AXUIElementSetAttributeValue(n.el, kAXValueAttribute as CFString, v as CFString)
    if err != .success {
        throw ActionError.fail("setvalue_failed",
            "AXSetValue rejected (\(err.rawValue)) — element may be read-only; try click+type")
    }
}

/// Select a substring inside an editable element via AXSelectedTextRange.
func selectText(_ n: Node, needle: String, mode: String) throws {
    guard let full = axStr(n.el, kAXValueAttribute as String) else {
        throw ActionError.fail("no_value", "element exposes no AXValue to search")
    }
    guard let r = full.range(of: needle) else {
        throw ActionError.fail("text_not_found", "'\(needle)' not present in element value")
    }
    let start = full.distance(from: full.startIndex, to: r.lowerBound)
    let len = needle.count
    var cf: CFRange
    switch mode {
    case "before": cf = CFRange(location: start, length: 0)
    case "after":  cf = CFRange(location: start + len, length: 0)
    default:       cf = CFRange(location: start, length: len)
    }
    guard let val = AXValueCreate(.cfRange, &cf) else {
        throw ActionError.fail("axvalue_failed", "could not build range")
    }
    let err = AXUIElementSetAttributeValue(n.el, kAXSelectedTextRangeAttribute as CFString, val)
    if err != .success {
        throw ActionError.fail("select_failed", "AXSelectedTextRange rejected (\(err.rawValue))")
    }
}

func scrollAt(pid: pid_t, p: CGPoint, dir: String, pages: Int) {
    let mag: Int32 = 6
    let dy: Int32 = dir == "up" ? mag : (dir == "down" ? -mag : 0)
    let dx: Int32 = dir == "left" ? mag : (dir == "right" ? -mag : 0)
    for _ in 0..<max(1, pages * 3) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                              wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { break }
        e.location = p
        e.postToPid(pid)
        usleep(35_000)
    }
}

func dragFromTo(pid: pid_t, from: CGPoint, to: CGPoint) {
    guard let d = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)
    else { return }
    d.postToPid(pid); usleep(80_000)
    // Interpolate: apps that track drags need intermediate moves, not a teleport.
    let steps = 14
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        if let m = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left) {
            m.postToPid(pid); usleep(16_000)
        }
    }
    if let u = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left) {
        u.postToPid(pid)
    }
}

