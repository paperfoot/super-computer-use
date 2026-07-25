// Output contract: two audiences, one stdout.
//
// Humans get plain text on a TTY; agents get a JSON envelope when piped or when --json
// is passed. Errors always go to stderr so `scu axdump … | jq` never breaks on an error.

import Foundation

// MARK: - exit codes
//
// The contract an agent branches on. Nothing outside 0-4 is ever returned.

enum Exit: Int32 {
    case ok = 0            // success
    case transient = 1     // retry with backoff (UI busy, capture glitch)
    case config = 2        // fix setup, do not retry (missing permission)
    case input = 3         // fix arguments (bad ref, unknown command)
    case rateLimited = 4   // unused here; reserved by the contract
}

// MARK: - errors

struct CLIError: Error {
    let code: String        // machine-readable, stable
    let message: String     // one human sentence
    let suggestion: String  // a literal instruction the agent can follow
    let exit: Exit

    init(_ code: String, _ message: String, _ suggestion: String, _ exit: Exit = .input) {
        self.code = code; self.message = message; self.suggestion = suggestion; self.exit = exit
    }
}

// MARK: - format detection

enum Format { case json, human }

struct Ctx {
    let format: Format
    let quiet: Bool
    var isJSON: Bool { format == .json }
}

/// Resolved once at startup. Piped output implies an agent is reading.
var ctx = Ctx(format: .human, quiet: false)

func detectFormat(jsonFlag: Bool) -> Format {
    if jsonFlag { return .json }
    return isatty(fileno(stdout)) == 1 ? .human : .json
}

// MARK: - JSON helpers

func jsonEscape(_ s: String) -> String {
    var o = ""
    for c in s.unicodeScalars {
        switch c {
        case "\"": o += "\\\""
        case "\\": o += "\\\\"
        case "\n": o += "\\n"
        case "\r": o += "\\r"
        case "\t": o += "\\t"
        default:
            if c.value < 0x20 { o += String(format: "\\u%04x", c.value) } else { o.unicodeScalars.append(c) }
        }
    }
    return o
}

func jstr(_ s: String) -> String { "\"\(jsonEscape(s))\"" }

/// Render a Swift value as JSON. Keeps call sites terse without pulling in Codable
/// for what are mostly flat dictionaries.
func jval(_ v: Any) -> String {
    switch v {
    case let s as String: return jstr(s)
    case let b as Bool:   return b ? "true" : "false"
    case let i as Int:    return "\(i)"
    case let d as Double: return d == d.rounded() ? "\(Int(d))" : "\(d)"
    // Ordered objects must be tested before [Any]: an array of (String, Any) tuples
    // also satisfies [Any], and would otherwise be stringified element by element.
    case let m as [(String, Any)]:
        return "{" + m.map { "\(jstr($0.0)):\(jval($0.1))" }.joined(separator: ",") + "}"
    case let m as [String: Any]:
        return "{" + m.keys.sorted().map { "\(jstr($0)):\(jval(m[$0]!))" }.joined(separator: ",") + "}"
    case let a as [Any]:  return "[" + a.map(jval).joined(separator: ",") + "]"
    default: return jstr("\(v)")
    }
}

// MARK: - emit

func writeErr(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

/// Success. JSON callers get the envelope; humans get whatever `human` renders.
func emit(_ data: Any, human: (() -> String)? = nil, status: String = "success") -> Never {
    if ctx.isJSON {
        print("{\"version\":\"1\",\"status\":\(jstr(status)),\"data\":\(jval(data))}")
    } else if !ctx.quiet {
        print(human?() ?? jval(data))
    }
    exit(Exit.ok.rawValue)
}

/// Success with pre-rendered text (tree dumps, help) rather than a data object.
func emitText(_ text: String, key: String = "text") -> Never {
    if ctx.isJSON {
        print("{\"version\":\"1\",\"status\":\"success\",\"data\":{\(jstr(key)):\(jstr(text))}}")
    } else if !ctx.quiet {
        print(text)
    }
    exit(Exit.ok.rawValue)
}

/// Failure. Always stderr, always with a suggestion, always a 1-4 exit code.
func fail(_ e: CLIError) -> Never {
    if ctx.isJSON {
        writeErr("{\"version\":\"1\",\"status\":\"error\",\"error\":{\"code\":\(jstr(e.code)),\"message\":\(jstr(e.message)),\"suggestion\":\(jstr(e.suggestion))}}")
    } else {
        writeErr("error [\(e.code)]: \(e.message)\n  → \(e.suggestion)")
    }
    exit(e.exit.rawValue)
}

func fail(_ code: String, _ message: String, _ suggestion: String, _ ex: Exit = .input) -> Never {
    fail(CLIError(code, message, suggestion, ex))
}
