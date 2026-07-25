// scu — background macOS UI automation.
//
// Entry point only: parse global flags, detect output format, dispatch, exit.
// Command bodies live in commands.swift; the AX layer in ax.swift.

import Cocoa
import ApplicationServices

// MARK: - argv

var rawArgs = Array(CommandLine.arguments.dropFirst())

// Global flags are stripped before command parsing so they work everywhere,
// including on help, version, and error paths.
let wantJSON = rawArgs.contains("--json")
let wantQuiet = rawArgs.contains("--quiet")
ctx = Ctx(format: detectFormat(jsonFlag: wantJSON), quiet: wantQuiet)

// `--help`/`-h`/`--version`/`-V` are informational requests, never errors.
if rawArgs.contains("--help") || rawArgs.contains("-h") || rawArgs.first == "help" {
    emitText(helpText, key: "usage")
}
if rawArgs.contains("--version") || rawArgs.contains("-V") || rawArgs.first == "version" {
    if ctx.isJSON { emit([("name", "scu"), ("version", scuVersion)] as [(String, Any)]) }
    emitText("scu \(scuVersion)")
}

guard let cmd = rawArgs.first, !cmd.hasPrefix("-") else {
    fail("bad_args", "No command given",
         "Run `scu help` for the command reference, or `scu agent-info` for the manifest.", .input)
}

// Everything after the command name; `opt`/`flag` in args.swift read this.
args = Array(rawArgs.dropFirst())

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
