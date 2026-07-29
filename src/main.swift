// scu — background macOS UI automation.
//
// Entry point only: parse global flags, detect output format, dispatch, exit.
// Command bodies live in commands.swift; the AX layer in ax.swift.

import Cocoa
import ApplicationServices

// MARK: - argv

let rawArgs = Array(CommandLine.arguments.dropFirst())

// One value-aware parse of the whole line, so a token that is the value of an option is
// never also read as a flag — `--value "--json"` is a payload, not an output switch.
let argvParse = ParsedArgs(rawArgs)
let cmdIndex = argvParse.firstPositional
let cmdName = cmdIndex.map { rawArgs[$0] }

// Global flags are stripped before command parsing so they work everywhere: before or
// after the command name, and on help, version, and error paths.
let wantJSON = argvParse.flags.contains("json")
let wantQuiet = argvParse.flags.contains("quiet")
ctx = Ctx(format: detectFormat(jsonFlag: wantJSON), quiet: wantQuiet)

// Everything except the command name and the globals; `opt`/`flag` in args.swift read this.
args = rawArgs.indices.filter { i in
    if i == cmdIndex { return false }
    return !(argvParse.kinds[i] == .option && (rawArgs[i] == "--json" || rawArgs[i] == "--quiet"))
}.map { rawArgs[$0] }

// `--help`/`-h`/`--version`/`-V` are informational requests, never errors.
if argvParse.flags.contains("help") || argvParse.flags.contains("h") || cmdName == "help" {
    emitText(helpText, key: "usage")
}
if argvParse.flags.contains("version") || argvParse.flags.contains("V") || cmdName == "version" {
    if ctx.isJSON { emit([("name", "scu"), ("version", scuVersion)] as [(String, Any)]) }
    emitText("scu \(scuVersion)")
}

guard let cmd = cmdName else {
    fail("bad_args", "No command given",
         "Run `scu help` for the command reference, or `scu agent-info` for the manifest.", .input)
}

// Checked after help/version so `scu --help` still works, but before any command runs: an
// option that takes a value and was given none used to degrade into a boolean, which widened
// the target instead of failing. Say which one, because an empty shell variable is invisible.
if let orphan = argvParse.valueless.sorted().first {
    fail("bad_args", "--\(orphan) needs a value and was given none",
         "Write `--\(orphan) <value>`. If it came from a shell variable, that variable is empty.",
         .input)
}

// MARK: - dispatch
//
// Two-word commands are matched first so `skill install` does not collide with `skill`.

let twoWord = args.first.map { "\(cmd) \($0)" } ?? cmd

switch twoWord {
case "skill install":
    args = Array(args.dropFirst())
    runSkillInstall()
default:
    break
}

switch cmd {
case "agent-info", "info":     emitAgentInfo()
case "doctor":                 runDoctor()
case "contract":               runContractHook()      // hidden: conformance probe
case "windows":                cmdWindows()
case "apps":                   cmdApps()
case "axdump":                 cmdAxdump()
case "find":                   cmdFind()
case "actions":                cmdActions()
case "click":                  cmdClick()
case "setvalue":               cmdSetValue()
case "selecttext":             cmdSelectText()
case "type":                   cmdType()
case "key":                    cmdKey()
case "scroll":                 cmdScroll()
case "drag":                   cmdDrag()
case "perform":                cmdPerform()
case "waitfor":                cmdWaitFor()
case "batch":                  cmdBatch()
case "settle":                 cmdSettle()
case "shot":                   cmdShot()
case "unhide":                 cmdUnhide()
case "launch":                 cmdLaunch()
case "cursor":                 cmdCursor()
case "skill":
    fail("bad_args", "`skill` needs a subcommand", "Run `scu skill install`.", .input)
default:
    fail("unknown_command", "No such command '\(cmd)'",
         "Run `scu help` for the command list, or `scu agent-info` for the machine-readable manifest.",
         .input)
}
