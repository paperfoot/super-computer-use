// Argument access. `args` holds everything after the command name; main.swift fills it.

import Foundation
import CryptoKit

/// Options that consume the next token as their value. The parser has to know these up
/// front: without the list, a payload like `--value "--allow-high-risk"` reads as a flag
/// as well as a value and clears a safety gate. Add a name here when you add an option.
let valueTakingOpts: Set<String> = [
    "action", "app", "button", "code", "count", "cursor", "depth", "direction",
    "from-ref", "from-x", "from-y", "grep", "hold", "index", "json-script", "key",
    "label", "max", "mode", "out", "pages", "path", "pid", "query", "quiet-ms",
    "ref", "script", "text", "then", "timeout", "to-ref", "to-x", "to-y", "value",
    "wait", "wait-max", "window", "x", "y",
]

/// One left-to-right pass over argv, so flags and option values are disjoint by
/// construction. `--` ends option parsing; everything after it is positional.
struct ParsedArgs {
    /// What a token turned out to be. `.option` covers a bare flag and the name half of a
    /// value-taking option alike — main.swift needs it only to tell `--json` the global
    /// flag from `--json` the payload of `--value`.
    enum Kind { case option, value, positional }

    private(set) var kinds: [Kind]
    private(set) var flags: Set<String> = []
    private(set) var values: [String: String] = [:]
    /// Value-taking options given with nothing after them. Silently demoting these to
    /// booleans is how `scu windows --app` came to list every app instead of erroring —
    /// a shell variable that expanded to nothing widened the target rather than failing.
    private(set) var valueless: Set<String> = []

    init(_ argv: [String]) {
        kinds = Array(repeating: .positional, count: argv.count)
        var i = 0
        while i < argv.count {
            let tok = argv[i]
            if tok == "--" { kinds[i] = .option; break }
            guard tok.hasPrefix("-"), tok.count > 1 else { i += 1; continue }
            kinds[i] = .option
            let name = String(tok.drop(while: { $0 == "-" }))
            if valueTakingOpts.contains(name) {
                guard i + 1 < argv.count else { valueless.insert(name); i += 1; continue }
                kinds[i + 1] = .value
                if values[name] == nil { values[name] = argv[i + 1] }  // first spelling wins
                i += 2
                continue
            }
            flags.insert(name)
            i += 1
        }
    }

    /// The command name lives at the first token that is neither an option nor a value.
    var firstPositional: Int? { kinds.firstIndex(of: .positional) }
}

/// Reparsed on assignment, because `skill install` rewrites `args` after dispatch.
var parsedArgs = ParsedArgs([])
var args: [String] = [] { didSet { parsedArgs = ParsedArgs(args) } }

func opt(_ n: String) -> String? { parsedArgs.values[n] }
func flag(_ n: String) -> Bool { parsedArgs.flags.contains(n) }
func intOpt(_ n: String, _ dflt: Int) -> Int { Int(opt(n) ?? "") ?? dflt }

/// Short, stable digest used to build element refs.
func shortHash(_ s: String) -> String {
    let d = Insecure.MD5.hash(data: Data(s.utf8))
    return d.map { String(format: "%02x", $0) }.joined().prefix(6).description
}
