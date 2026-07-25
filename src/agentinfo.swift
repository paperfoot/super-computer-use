// agent-info — the capability manifest.
//
// This is a tested contract, not documentation: every command listed here must be
// routable and every flag must exist. `bgcu contract --selftest` verifies it.

import Foundation

let bgcuVersion = "1.0.0"

/// Command name -> (description, args, options). Options are [name, type, required,
/// default, description] tuples flattened into the manifest shape the framework defines.
struct CmdSpec {
    let name: String
    let desc: String
    let opts: [(String, String, Bool, String, String)]   // name, type, required, default, description
}

/// Options every command accepts; listed once in global_flags rather than repeated.
let globalOpts: [(String, String, Bool, String, String)] = [
    ("--pid", "integer", false, "", "Target process id (or use --app)"),
    ("--app", "string", false, "", "Target app by display name or bundle id"),
    ("--json", "bool", false, "false", "Force JSON output (auto-enabled when piped)"),
    ("--quiet", "bool", false, "false", "Suppress human output"),
    ("--no-cursor", "bool", false, "false", "Do not draw the agent cursor overlay"),
    ("--wait", "string", false, "auto", "Settle mode: auto | milliseconds | 0"),
    ("--wait-max", "integer", false, "5000", "Upper bound on auto settle, ms"),
    ("--quiet-ms", "integer", false, "250", "Quiet period that ends an auto settle, ms"),
]

let commandSpecs: [CmdSpec] = [
    CmdSpec(name: "windows", desc: "List on-screen windows", opts: [
        ("--all", "bool", false, "false", "Include minimized and off-screen windows"),
    ]),
    CmdSpec(name: "apps", desc: "List running applications with pids", opts: []),
    CmdSpec(name: "axdump", desc: "Print the indexed accessibility tree", opts: [
        ("--grep", "string", false, "", "Only lines containing this text"),
        ("--diff", "bool", false, "false", "Only what changed since the last dump"),
        ("--actions", "bool", false, "false", "Annotate each node with its AX actions"),
        ("--actionable", "bool", false, "false", "Only nodes that expose an action"),
        ("--menus", "bool", false, "false", "Include the menu bar subtree"),
        ("--enhanced", "bool", false, "false", "Set AXEnhancedUserInterface first (some Catalyst apps)"),
        ("--max", "integer", false, "4000", "Node budget"),
        ("--depth", "integer", false, "16", "Maximum tree depth"),
    ]),
    CmdSpec(name: "find", desc: "Locate elements by text; returns ref, index, centre, actions", opts: [
        ("--text", "string", true, "", "Substring to match, case-insensitive"),
    ]),
    CmdSpec(name: "actions", desc: "List the AX actions an element supports", opts: [
        ("--ref", "string", false, "", "Element fingerprint from find/axdump"),
        ("--query", "string", false, "", "Selector, e.g. role=AXButton;text~=send;nth=0"),
        ("--index", "integer", false, "", "Positional index (fragile; prefer ref/query)"),
    ]),
    CmdSpec(name: "click", desc: "Press an element or a point", opts: [
        ("--ref", "string", false, "", "Element fingerprint"),
        ("--query", "string", false, "", "Selector"),
        ("--index", "integer", false, "", "Positional index"),
        ("--x", "number", false, "", "Global x coordinate"),
        ("--y", "number", false, "", "Global y coordinate"),
        ("--mode", "string", false, "ax", "ax (AXPress) or event (synthetic click)"),
        ("--button", "string", false, "left", "left | right | middle"),
        ("--count", "integer", false, "1", "Click count for double/triple"),
    ]),
    CmdSpec(name: "setvalue", desc: "Write a value into an element", opts: [
        ("--value", "string", true, "", "Replacement value"),
        ("--ref", "string", false, "", "Element fingerprint"),
        ("--query", "string", false, "", "Selector"),
    ]),
    CmdSpec(name: "selecttext", desc: "Select a substring inside an editable element", opts: [
        ("--text", "string", true, "", "Substring to select"),
        ("--cursor", "string", false, "select", "select | before | after"),
        ("--ref", "string", false, "", "Element fingerprint"),
        ("--query", "string", false, "", "Selector"),
    ]),
    CmdSpec(name: "type", desc: "Type text into the target process", opts: [
        ("--text", "string", true, "", "Text to type"),
    ]),
    CmdSpec(name: "key", desc: "Press a key or chord", opts: [
        ("--key", "string", true, "", "Chord, e.g. return or cmd+shift+a"),
    ]),
    CmdSpec(name: "scroll", desc: "Scroll an element", opts: [
        ("--direction", "string", true, "", "up | down | left | right"),
        ("--pages", "integer", false, "1", "Pages to scroll"),
        ("--ref", "string", false, "", "Element fingerprint"),
        ("--query", "string", false, "", "Selector"),
    ]),
    CmdSpec(name: "drag", desc: "Drag between two elements or points", opts: [
        ("--from-ref", "string", false, "", "Source element"),
        ("--to-ref", "string", false, "", "Destination element"),
        ("--from-x", "number", false, "", "Source x"), ("--from-y", "number", false, "", "Source y"),
        ("--to-x", "number", false, "", "Destination x"), ("--to-y", "number", false, "", "Destination y"),
    ]),
    CmdSpec(name: "perform", desc: "Invoke a named AX action on an element", opts: [
        ("--action", "string", true, "", "Action name, e.g. AXShowMenu"),
        ("--ref", "string", false, "", "Element fingerprint"),
        ("--query", "string", false, "", "Selector"),
    ]),
    CmdSpec(name: "waitfor", desc: "Block until an element appears or disappears", opts: [
        ("--text", "string", false, "", "Text to wait for"),
        ("--ref", "string", false, "", "Ref to wait for"),
        ("--gone", "bool", false, "false", "Wait for absence instead of presence"),
        ("--timeout", "number", false, "10", "Seconds before giving up"),
    ]),
    CmdSpec(name: "batch", desc: "Run a JSON action script in one process", opts: [
        ("--script", "string", false, "", "Path to a JSON array of steps"),
        ("--json-script", "string", false, "", "Inline JSON array of steps"),
    ]),
    CmdSpec(name: "settle", desc: "Wait until the UI stops changing", opts: []),
    CmdSpec(name: "shot", desc: "Capture one window, even when occluded", opts: [
        ("--window", "integer", true, "", "Window id from `windows`"),
        ("--out", "string", true, "", "Output PNG path"),
    ]),
    CmdSpec(name: "unhide", desc: "Un-hide and un-minimize without activating", opts: []),
    CmdSpec(name: "launch", desc: "Launch an app without stealing focus", opts: []),
    CmdSpec(name: "cursor", desc: "Show the agent cursor at a point", opts: [
        ("--x", "number", true, "", "Global x"), ("--y", "number", true, "", "Global y"),
        ("--label", "string", false, "", "Badge text"),
        ("--hold", "number", false, "0.75", "Seconds to hold"),
    ]),
    CmdSpec(name: "doctor", desc: "Check permissions and dependencies", opts: []),
    CmdSpec(name: "agent-info", desc: "This manifest", opts: []),
    CmdSpec(name: "skill install", desc: "Install the skill file to agent platforms", opts: [
        ("--path", "string", false, "", "Override install directory"),
    ]),
    CmdSpec(name: "version", desc: "Print the version", opts: []),
    CmdSpec(name: "help", desc: "Full command reference", opts: []),
]

private func optJSON(_ o: (String, String, Bool, String, String)) -> String {
    var parts = ["\"name\":\(jstr(o.0))", "\"type\":\(jstr(o.1))", "\"required\":\(o.2)"]
    if !o.3.isEmpty { parts.append("\"default\":\(jstr(o.3))") }
    parts.append("\"description\":\(jstr(o.4))")
    return "{" + parts.joined(separator: ",") + "}"
}

/// Raw JSON, never wrapped in the envelope: the manifest *is* the schema.
func emitAgentInfo() -> Never {
    var cmds: [String] = []
    for c in commandSpecs {
        let opts = c.opts.map(optJSON).joined(separator: ",")
        cmds.append("\(jstr(c.name)):{\"description\":\(jstr(c.desc)),\"args\":[],\"options\":[\(opts)]}")
    }
    let globals = globalOpts.map { o in
        "\(jstr(o.0)):{\"description\":\(jstr(o.4)),\"type\":\(jstr(o.1)),\"default\":\(o.3.isEmpty ? "null" : jstr(o.3))}"
    }.joined(separator: ",")

    print("""
    {"name":"bgcu","version":\(jstr(bgcuVersion)),\
    "description":"Background macOS UI automation: read and drive apps without stealing focus or moving the pointer",\
    "commands":{\(cmds.joined(separator: ","))},\
    "global_flags":{\(globals)},\
    "exit_codes":{"0":"Success","1":"Transient error (UI busy, capture failed) -- retry",\
    "2":"Config error (missing macOS permission) -- fix setup",\
    "3":"Bad input (unknown command, stale ref, no match) -- fix arguments",\
    "4":"Rate limited -- wait and retry"},\
    "envelope":{"version":"1","success":"{ version, status, data }",\
    "error":"{ version, status, error: { code, message, suggestion } }"},\
    "config":{"path":"~/Library/Caches/bgcu","env_prefix":"BGCU_"},\
    "auto_json_when_piped":true}
    """)
    exit(Exit.ok.rawValue)
}

let helpText = """
bgcu \(bgcuVersion) — background macOS UI automation

Reads and drives one app through the Accessibility API without bringing it to the
front or moving your pointer. Each action flashes a teal agent cursor so you can see
what it touched.

USAGE
  bgcu <command> [--pid P | --app NAME] [options]

READ
  windows [--all]                  list windows; --all includes minimized
  apps                             running apps with pids
  axdump [--grep T] [--diff]       indexed AX tree ([N] Ref Role @x,y: text)
  find --text T                    locate elements: ref, index, centre, actions
  actions --query Q                actions an element supports
  shot --window ID --out F         capture a window, even occluded

ACT
  click --query Q                  AXPress (default) or --mode event
  setvalue --query Q --value V     write into a field
  selecttext --query Q --text T    select a substring
  type --text T                    type into the focused element
  key --key "cmd+shift+a"          key or chord
  scroll --query Q --direction down
  drag --from-ref A --to-ref B
  perform --query Q --action AXShowMenu

FLOW
  waitfor --text T [--gone]        block until a condition holds
  batch [--script F]               run a JSON step list in one process
  settle                           wait for the UI to stop changing

UTIL
  doctor                           check permissions (run this first)
  unhide                           un-hide + un-minimize, no activation
  launch --app NAME                launch without stealing focus
  cursor --x X --y Y --label T     show the agent cursor
  agent-info                       machine-readable capability manifest
  skill install                    install the skill file for agents

TARGETING — prefer query over ref over index
  --query 'role=AXButton;text~=send;nth=0'   readable, portable
  --ref 'Button#3f2a1b'                      exact fingerprint from find
  --index 42                                 positional; breaks on reflow
  Query keys: role= id= text~= text== title= nth= actionable

Tips:
  Run `bgcu doctor` first — permissions are the number one failure mode, and they are
    granted to your terminal application, not to bgcu.
  Prefer `axdump`/`find` over `shot`: reading the tree takes ~35ms and is exact,
    while a screenshot costs a vision round-trip.
  Use `batch` for anything multi-step. Model round-trips dominate cost, not execution.
  Use `waitfor` instead of guessing a sleep.
  `setvalue` beats `type` for background apps — keystrokes follow real focus.
  If a Catalyst app shows a shallow tree, retry `axdump --enhanced`.
  Minimized windows cannot receive clicks: run `unhide` first.

Examples:
  bgcu doctor
  bgcu apps
  bgcu find --app Notes --text "Shopping"
  bgcu click --app Notes --query 'role=AXButton;text~=New Note'
  bgcu setvalue --app Notes --query 'role=AXTextArea;nth=0' --value "milk, eggs"
  bgcu waitfor --app Safari --text "Sign in" --timeout 15
  echo '[{"do":"setvalue","query":"role=AXTextField;nth=0","value":"hi"},
        {"do":"key","key":"return"},
        {"do":"waitfor","text":"Sent"}]' | bgcu batch --app Messages

EXIT CODES
  0 success   1 transient, retry   2 config/permission, fix setup
  3 bad input, fix arguments       4 rate limited

Errors are JSON on stderr with a code and a suggestion; stdout stays clean for pipes.
"""
