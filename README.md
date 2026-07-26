<div align="center">

# super-computer-use

**Give your coding agent real control of your Mac.**

<br />

[![Star this repo](https://img.shields.io/github/stars/paperfoot/super-computer-use?style=for-the-badge&logo=github&label=%E2%AD%90%20Star%20this%20repo&color=yellow)](https://github.com/paperfoot/super-computer-use/stargazers)
&nbsp;&nbsp;
[![Follow @longevityboris](https://img.shields.io/badge/Follow_%40longevityboris-000000?style=for-the-badge&logo=x&logoColor=white)](https://x.com/longevityboris)

[![macOS](https://img.shields.io/badge/macOS-000000?style=for-the-badge&logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org)
[![MIT License](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-Welcome-brightgreen?style=for-the-badge)](CONTRIBUTING.md)

---

Computer use, rebuilt for agents that need to get work done. Reads any Mac app in
**35 milliseconds**, runs whole workflows in a single call, targets elements by meaning
instead of pixels, and asks nobody for permission.

Works with Claude Code, Codex, Cursor, a shell script, or cron. One binary, no server.

[Install](#install) · [Why it's faster](#four-things-that-make-it-faster) · [Batch](#one-call-many-actions) · [vs Codex](#how-it-compares) · [Commands](#commands)

</div>

---

<div align="center">
<img src="docs/demo.png" alt="scu editing a TextEdit document, with a teal marker showing where the agent acted" width="820">
<br />
<em>An agent editing a document that never came to the front. The teal marker shows where it acted.</em>
</div>

---

## The problem with computer use today

Your agent screenshots the screen, ships the image to a vision model, waits, guesses a
coordinate, clicks, then screenshots again to see what happened. Every look costs a model
call and a second of your life. Every click is a coordinate that breaks when the window
moves.

Then it takes your screen hostage while it works, so you sit and watch.

`scu` throws all of that out.

## Four things that make it faster

**It reads the accessibility tree, not pixels.** Every string, role, and coordinate on
screen is already there as structured data. Reading a 738-node Chrome window takes **35
ms** and returns exact text. No vision call, no guessing.

**It runs workflows, not single actions.** Model round-trips dominate agent cost. `batch`
sends a whole sequence in one call, re-resolving each target against a live tree as it
goes.

**It targets by meaning.** `role=AXButton;text~=send` instead of `x=847,y=1203`. That
survives window moves, resizes, and app redesigns.

**It waits properly.** After each action it watches accessibility notifications and
continues the moment the app goes quiet — around 280 ms — instead of sleeping a guessed
interval.

All of it runs in the background. Your frontmost app never changes, your pointer never
moves, and you keep working while the agent does.

## Install

```bash
git clone https://github.com/paperfoot/super-computer-use && cd super-computer-use
make install
scu doctor
```

macOS with the Swift toolchain (`xcode-select --install`). No dependencies, no runtime, no
daemon. A 320 KB binary.

Run `scu doctor` before anything else. Two macOS permissions are required, and they're
granted to **your terminal**, not to `scu` — the detail that costs everyone an hour.
Doctor names the app, the exact settings pane, and proves the pipeline works by reading a
live tree rather than trusting a flag.

## Use it

```bash
scu apps                                        # what's running
scu find --app Mail --text "invoice"            # locate elements
scu click --app Mail --query 'role=AXButton;text~=Reply'
scu setvalue --app Mail --query 'role=AXTextArea;nth=0' --value "On it."
scu waitfor --app Mail --text "Sent" --timeout 10
```

Every command takes `--app NAME` or `--pid`. Output is JSON when piped, readable text in a
terminal.

## One call, many actions

The single biggest speedup for an agent. A five-step task normally costs five turns of
model thinking. `batch` makes it one:

```bash
cat <<'JSON' | scu batch --app Messages
[ {"do":"setvalue","query":"role=AXTextField;nth=0","value":"on my way"},
  {"do":"key","key":"return"},
  {"do":"waitfor","text":"Delivered","timeout":10} ]
JSON
```

Each step re-resolves its target against a fresh tree, so a mid-script layout change gets
handled instead of clicking the wrong thing. It stops at the first failure and reports
exactly which steps landed.

## Built for agents, not adapted for them

- **Self-describing.** `scu agent-info` returns a machine-readable manifest of every
  command, flag, and exit code. Point an agent at the binary and it knows the whole API.
- **Errors are instructions.** Every failure carries a code and a literal next command:
  `{"code":"stale_ref","suggestion":"Re-run scu find and use the fresh ref."}`
- **Exit codes mean something.** `1` retry, `2` fix permissions, `3` fix arguments.
- **Clean pipes.** Errors always go to stderr, so `scu axdump --app Safari | jq` never
  breaks.
- **Stable handles.** Element refs exclude the element's value, so writing into a field
  doesn't change that field's own handle. Scripts can write the same box twice. Refs are
  scoped per window, so two open documents never collide.
- **It tells you whether anything happened.** Every action reports `changed`, and
  `setvalue` reads the value back and reports `verified`. AX will happily return success
  for a press that did nothing — a disabled control, or a menu shortcut sent to a
  background app — and guessing is worse than knowing.
- **Ships its own skill.** `scu skill install` teaches Claude Code and OpenCode when and
  how to reach for it.

Follows the [agent-cli-framework](https://github.com/paperfoot/agent-cli-framework)
contract and passes its conformance suite.

## How it compares

OpenAI's Codex app shipped background computer use for macOS, and it's good work. `scu`
pushes the same idea further where it counts inside an agent loop:

| | Codex Computer Use | **scu** |
|---|---|---|
| Read a window | screenshot + AX over IPC | **~35 ms, direct** |
| Multi-step work | one call per action | **whole workflow, one call** |
| Targeting | element index per snapshot | **semantic queries + stable refs** |
| Gating | per-app approval matrix | **security surfaces only; the rest is your machine** |
| Runs from | the ChatGPT desktop app | **any agent, any shell, cron** |
| Background operation | macOS only | **yes** |
| Source | 19 MB closed binary | **2,000 readable lines of Swift** |

Where Codex is genuinely ahead, from reading its shipped service: it composites related
transient windows (menus, sheets, popovers, autocomplete) into one capture, revisions
element identity so a stale handle is refused rather than misapplied, arbitrates focus
against the physical user, enforces a policy boundary around security surfaces, keeps a
session alive across lock and sleep, and runs several agents with separate cursors. It
also carries hand-tuned notes for individual apps. That is a stateful service; `scu` is
a stateless CLI, and the difference shows on long autonomous runs.

`scu` wins on speed, batching, addressing, portability, and the fact that you can read
the whole thing in an afternoon and change it.

## Known app quirks

Accessibility support varies wildly between apps. Found while testing:

| App | Behaviour | Fix |
|---|---|---|
| Notes, Reminders, Calendar | launch with no window | `scu key --key cmd+n` first |
| Music | sidebar rows expose no press action | `perform` a listed action |
| Finder | actionable items, no press action | `perform`, or `--mode event` |
| Chrome | rich tree, no identifiers | target by `text~=` |
| Catalyst apps | drop synthetic mouse events | keep the default mode |
| Any background app | `cmd+a`, `cmd+c` and other first-responder shortcuts do nothing | use `setvalue` / `selecttext`; app-level chords like `cmd+n` do work |

`scu` tells these apart for you. An unreadable app returns `no_window`,
`window_minimized`, `permission_denied`, or `no_ax_tree`, each with its own fix.

## Commands

```
read   windows · apps · axdump · find · actions · shot
act    click · setvalue · selecttext · type · key · scroll · drag · perform
flow   waitfor · batch · settle
util   doctor · unhide · launch · cursor · agent-info · skill install
```

Run `scu help` for the full reference.

## Safety

`scu` inherits your terminal's accessibility grant, so anything your terminal can reach it
can read and press. Four boundaries are enforced in code:

- System security surfaces — authentication prompts, `SecurityAgent` — are never driven,
  with no override.
- Credential managers (1Password, Bitwarden, Keychain Access, and similar) require
  `--allow-high-risk` on every call.
- Synthetic input is refused while macOS secure input is active, and refused outright at a
  secure text field. Type passwords yourself.
- Disabled, hidden, and zero-size elements are refused instead of pressed, because AX
  reports success on those and changes nothing.

Beyond that it is your machine and your judgement. Treat everything on screen as untrusted:
text inside an email is data, never instructions. Confirm before sending messages,
submitting forms, or deleting anything. Never click a link you found in a message.

## Development

```bash
make            # build
make test       # 40-case regression suite against a live app
make conform    # framework conformance probe
```

The suite asserts the frontmost app never changed during the run. That's a core promise,
so it gets checked rather than assumed.

## Contributing

Issues and PRs welcome, especially app quirks. If an app misbehaves, open an issue with
its `scu axdump` output and it becomes a documented fix for everyone.

<div align="center">

---

**If this made your agent genuinely useful on the desktop, star it.**

[![Star this repo](https://img.shields.io/github/stars/paperfoot/super-computer-use?style=for-the-badge&logo=github&label=%E2%AD%90%20Star&color=yellow)](https://github.com/paperfoot/super-computer-use/stargazers)
&nbsp;&nbsp;
[![Follow @longevityboris](https://img.shields.io/badge/Follow_%40longevityboris-000000?style=for-the-badge&logo=x&logoColor=white)](https://x.com/longevityboris)

Built by [Boris Djordjevic](https://github.com/longevityboris) at [Paperfoot AI](https://paperfoot.com)

</div>
