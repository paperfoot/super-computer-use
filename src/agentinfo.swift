// agent-info — the capability manifest.
//
// This is a tested contract, not documentation: every command listed here must be
// routable and every flag must exist. `scu contract --selftest` verifies it.

import Foundation

let scuVersion = "1.0.0"

/// Command name -> (description, args, options). Options are [name, type, required,
/// default, description] tuples flattened into the manifest shape the framework defines.
struct CmdSpec {
    let name: String
    let desc: String
    let opts: [(String, String, Bool, String, String)]   // name, type, required, default, description
}

/// Options every command accepts; listed once in global_flags rather than repeated.
/// The tree-budget flags belong here rather than under axdump: every walk reads them,
/// including the one a ref or query is resolved against.
let globalOpts: [(String, String, Bool, String, String)] = [
    ("--pid", "integer", false, "", "Target process id (or use --app)"),
    ("--app", "string", false, "", "Target app by display name or bundle id"),
    ("--json", "bool", false, "false", "Force JSON output (auto-enabled when piped)"),
    ("--quiet", "bool", false, "false", "Suppress human output; no effect on JSON or on settle timing"),
    ("--no-cursor", "bool", false, "false", "Do not draw the agent cursor overlay"),
    ("--hold", "number", false, "0.45",
     "Seconds (0-30) the agent cursor overlay stays up; the cursor command holds 0.75"),
    ("--no-check", "bool", false, "false",
     "Skip the actionability preflight (disabled, hidden, zero-size) and act anyway. "
     + "It never skips the secure-text-field refusal."),
    ("--allow-high-risk", "bool", false, "false", "Permit targeting a credential manager"),
    ("--wait", "string", false, "auto", "Settle mode: auto | milliseconds (0-3600000) | 0"),
    ("--wait-max", "integer", false, "5000", "Upper bound on auto settle, ms (0-3600000)"),
    ("--quiet-ms", "integer", false, "250", "Quiet period that ends an auto settle, ms (0-3600000)"),
    ("--then", "string", false, "", "Fold a follow-up read into the action reply: dump | diff | focus"),
    ("--path", "string", false, "",
     "Child-index path from `find` (e.g. 0.3.2.7); picks one element when a ref is ambiguous"),
    ("--depth", "integer", false, "",
     "Tree depth limit (default 16 for axdump and --then, 18 for waitfor, 20 for find and ref/query resolution)"),
    ("--max", "integer", false, "",
     "Node budget (default 4000 for axdump, --then and waitfor, 6000 for find and ref/query resolution)"),
    ("--menus", "bool", false, "false", "Include the menu bar subtree when walking the tree"),
    ("--enhanced", "bool", false, "false", "Set AXEnhancedUserInterface first (some Catalyst apps)"),
    ("--help", "bool", false, "false", "Print the command reference and exit 0 (also -h)"),
    ("--version", "bool", false, "false", "Print the version and exit 0 (also -V)"),
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
        ("--no-context", "bool", false, "false", "Omit the url/focus header and print the bare tree"),
    ]),
    CmdSpec(name: "find", desc: "Locate elements by text; returns ref, index, centre, path, actions", opts: [
        ("--text", "string", true, "", "Substring to match, case-insensitive"),
        ("--actionable", "bool", false, "false", "Only elements that expose an action"),
    ]),
    CmdSpec(name: "actions", desc: "List the AX actions an element supports", opts: [
        ("--ref", "string", false, "", "Element fingerprint from find/axdump"),
        ("--query", "string", false, "", "Selector, e.g. role=AXButton;text~=send;win=Inbox;nth=0"),
        ("--index", "integer", false, "",
         "Positional index as printed by `find` (fragile; prefer ref/query). Resolved against "
         + "the find/query walk (--depth 20 --max 6000), so an index copied from `axdump`'s "
         + "smaller default walk can address a different node."),
    ]),
    CmdSpec(name: "click", desc: "Press an element or a point", opts: [
        ("--ref", "string", false, "", "Element fingerprint"),
        ("--query", "string", false, "", "Selector"),
        ("--index", "integer", false, "", "Positional index as printed by `find`"),
        ("--x", "number", false, "", "Global x coordinate"),
        ("--y", "number", false, "", "Global y coordinate"),
        ("--mode", "string", false, "ax", "ax (AXPress) or event (synthetic click)"),
        ("--button", "string", false, "left", "left | right | middle"),
        ("--count", "integer", false, "1", "Click count for double/triple (1-10)"),
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
        ("--pages", "integer", false, "1", "Pages to scroll (1-100)"),
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
        ("--timeout", "number", false, "10", "Seconds before giving up (0-86400); 0 checks once"),
    ]),
    CmdSpec(name: "batch", desc: "Run a JSON action script in one process; reads stdin if neither option is given", opts: [
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
    CmdSpec(name: "doctor", desc: "Check permissions and dependencies; exits 2 if a blocking check fails", opts: []),
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
    {"name":"scu","version":\(jstr(scuVersion)),\
    "description":"Background macOS UI automation: read and drive apps without stealing focus or moving the pointer",\
    "commands":{\(cmds.joined(separator: ","))},\
    "global_flags":{\(globals)},\
    "exit_codes":{"0":"Success","1":"Transient error (UI busy, capture failed) -- retry",\
    "2":"Config error (missing macOS permission, refused target, secure field) -- fix setup, do not retry",\
    "3":"Bad input (unknown command, stale ref, no match) -- fix arguments",\
    "4":"Rate limited -- wait and retry (reserved by the contract; only the hidden contract probe returns it)"},\
    "envelope":{"version":"1","success":"{ version, status, data }",\
    "error":"{ version, status, error: { code, message, suggestion } }",\
    "doctor":"keeps the full report on stdout either way: { version, status, data } plus an error object \
    when a blocking check (accessibility, ax_live_probe, gui_session) fails -- that case is status error, \
    code setup_incomplete, exit 2, and the same error envelope also goes to stderr. \
    data.healthy false with status success means only a non-blocking check failed"},\
    "argv":{"global_flags_anywhere":true,"end_of_flags":"--"},\
    "config":{"path":"~/Library/Caches/scu","env_prefix":"SCU_","env_vars":[]},\
    "auto_json_when_piped":true}
    """)
    exit(Exit.ok.rawValue)
}

let helpText = """
scu \(scuVersion) — background macOS UI automation

Reads and drives one app through the Accessibility API without bringing it to the
front or moving your pointer. Each action flashes a teal agent cursor so you can see
what it touched.

USAGE
  scu <command> [--pid P | --app NAME] [options]
  Global flags work on either side of the command name — `scu --json apps` and
    `scu apps --json` are the same call — and `--` ends flag parsing:
    --pid --app --json --quiet --no-cursor --hold --no-check --allow-high-risk
    --wait --wait-max --quiet-ms --then --path --depth --max --menus --enhanced

READ
  windows [--all]                  list windows; --all includes minimized
  apps                             running apps with pids
  axdump [--grep T] [--diff]       indexed AX tree ([N] Ref Role @x,y: text)
                                   also --actions --actionable --no-context
  find --text T [--actionable]     locate elements: ref, index, centre, path, actions
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
  Every action takes --then dump|diff|focus, which folds the follow-up read into the
    reply and saves a second process launch.
  Every action reports "changed" from a tree fingerprint taken before and after.
    changedCoverage "partial" means the walk hit its node budget, so changed:false is
    inconclusive there — re-read with find/axdump, or raise --max.

FLOW
  waitfor --text T [--ref R] [--gone]   block until a condition holds
  batch [--script F]               run a JSON step list in one process
  settle                           wait for the UI to stop changing
  Settling knobs: --wait auto|MS|0, --wait-max MS (5000), --quiet-ms MS (250).
    --quiet-ms is the settle quiet period; --quiet only suppresses human output.

UTIL
  doctor                           check permissions (run this first; exits 2 if blocked)
  unhide                           un-hide + un-minimize, no activation
  launch --app NAME                launch without stealing focus
  cursor --x X --y Y --label T     show the agent cursor
  agent-info                       machine-readable capability manifest
  skill install                    install the skill file for agents
  help | --help | -h               this reference
  version | --version | -V         print the version

TARGETING — prefer query over ref over index
  --query 'role=AXButton;text~=send;nth=0'   readable, portable
  --ref 'Button#3f2a1b'                      exact fingerprint from find
  --path '0.3.2.7'                           picks one when a ref is ambiguous
  --index 42                                 positional, as printed by find; breaks on reflow
  Query keys: role= id= text~= text== title= win= nth= actionable
  win= scopes to one window by title — needed when an app has several documents open
  An unrecognised clause fails with bad_query rather than being ignored; note there is
    no bare text= — use text~= or text==.
  Tree budget: --depth N --max N --menus --enhanced apply to every walk, not just
    axdump — a ref or query is resolved against a walk of the same tree. That walk is
    depth 20 / max 6000, the one find prints indices from; an index copied from axdump's
    smaller default walk can address a different node.

SAFETY
  Actions are refused on disabled, hidden and zero-size elements. Pass --no-check to
    act anyway; the reply's "changed" field tells you if it landed.
  Typing into a secure text field is refused with no override — --no-check does not
    skip it (code secure_field, exit 2). Ask the user to type the password.
  System security surfaces (SecurityAgent, authentication prompts) are never driven.
  Credential managers require --allow-high-risk on every call.
  Synthetic input is refused while macOS secure input is active.

Tips:
  Run `scu doctor` first — permissions are the number one failure mode, and they are
    granted to your terminal application, not to scu.
  Prefer `axdump`/`find` over `shot`: reading the tree takes ~35ms and is exact,
    while a screenshot costs a vision round-trip.
  Use `batch` for anything multi-step. Model round-trips dominate cost, not execution.
  Use `waitfor` instead of guessing a sleep.
  `setvalue` beats `type` for background apps — keystrokes follow real focus.
  If a Catalyst app shows a shallow tree, retry `axdump --enhanced`.
  Minimized windows cannot receive clicks: run `unhide` first.

Examples:
  scu doctor
  scu apps
  scu find --app Notes --text "Shopping"
  scu click --app Notes --query 'role=AXButton;text~=New Note'
  scu setvalue --app Notes --query 'role=AXTextArea;nth=0' --value "milk, eggs"
  scu waitfor --app Safari --text "Sign in" --timeout 15
  echo '[{"do":"setvalue","query":"role=AXTextField;nth=0","value":"hi"},
        {"do":"key","key":"return"},
        {"do":"waitfor","text":"Sent"}]' | scu batch --app Messages

EXIT CODES
  0 success   1 transient, retry   2 config/permission/secure field, fix setup
  3 bad input, fix arguments       4 rate limited (reserved; never returned)
  doctor keeps its full report on stdout either way; a blocking failure is code
    setup_incomplete, exit 2, with the error on stderr as usual.

Errors are JSON on stderr with a code and a suggestion; stdout stays clean for pipes.
"""
