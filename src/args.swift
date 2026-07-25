// Argument access. `args` holds everything after the command name; main.swift fills it.

import Foundation
import CryptoKit

var args: [String] = []

func opt(_ n: String) -> String? {
    guard let i = args.firstIndex(of: "--\(n)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ n: String) -> Bool { args.contains("--\(n)") }
func intOpt(_ n: String, _ dflt: Int) -> Int { Int(opt(n) ?? "") ?? dflt }

/// Short, stable digest used to build element refs.
func shortHash(_ s: String) -> String {
    let d = Insecure.MD5.hash(data: Data(s.utf8))
    return d.map { String(format: "%02x", $0) }.joined().prefix(6).description
}
