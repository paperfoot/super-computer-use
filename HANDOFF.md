# Handoff — super-computer-use (`scu`)

Written 2026-07-27. Updated after a stopped workflow run.

Read the **STOP** section first — it is the one thing that will make Boris angry if you
get it wrong. Then the **Next session** block at the bottom.

---

## What this is

`scu` is a macOS CLI that reads and drives apps through the Accessibility API without
stealing focus or moving the pointer. Built to give coding agents real desktop control,
positioned against OpenAI's Codex Computer Use.

- Repo: <https://github.com/paperfoot/super-computer-use> (public, paperfoot org)
- Local: `~/Code/super-computer-use`, binary at `~/.local/bin/scu`
- Also installed on the **Mac Studio** (`ssh studio`), same paths, `doctor` healthy
- ~2,300 lines of Swift, no dependencies. `make` / `make test` / `make conform`
- 53/53 regression tests, conformant to `paperfoot/agent-cli-framework`

The command is `scu`; the repo is `super-computer-use`. It was renamed from `bgcu`
mid-session because "background computer use" sold the wrong headline — the product is
computer use fast and scriptable enough for an agent, and background operation is one
property of that, not the pitch.

---

## The single most important lesson from this session

**Every serious bug found was a silent success — the tool reported `ok` and nothing had
happened.** Not crashes, not errors. Each was found by driving a real app and checking
the result, never by reading code or by the test suite as first written.

Concretely: responder-level chords (`cmd+a`) post fine to a background app and are
swallowed; zero-size and disabled elements accept `AXPress` and do nothing; element refs
collided across two windows of the same app; `unhide` reported success while restoring
nothing. All shipped as "working" before being tested against real apps.

So the architecture now leans on **verification over assumption**: every mutating command
reports `changed` (tree fingerprint before/after), `setvalue` reads the value back and
reports `verified`, and a preflight refuses predictable no-ops. Keep that discipline. If
you add an action verb, it must be able to say whether it worked.

Second lesson: **a wrong suggestion is worse than no suggestion.** Two shipped errors told
the user to run a command that could not fix their problem. The framework treats this as
P0 and it is right.

Third: **the test fixture was too well-behaved.** TextEdit is cooperative and surfaced
none of the interesting failures. Real finds came from Music, Finder, Chrome, Notes, and
a minimized Cursor window on the Studio.

---

## Research assets — read these before doing anything

Three external analyses, all evidence-cited. They are the highest-value context here
and cost roughly two hours of wall-clock to produce.

| File | What it is |
|---|---|
| `~/.claude/subagent-results/scu-codex-sky-reverse-engineering.md` | 1,366 lines. Codex Sol at max reasoning, disassembling Sky's 19 MB service. Full 29-code error taxonomy, 26-type IPC registry, transient-UI handling, ranked P0-P2 gap list. **Largely unread — only the bottom-line table and four sections were consumed.** |
| `~/.claude/subagent-results/scu-grok-implementation-survey.md` | Grok 4.5 survey of axcli, axterminator, Appium mac2, XCUITest, Playwright. Source of the `AXManualAccessibility` unlock and the actionability model. |

Sky's own docs are readable on disk and worth re-reading:
`/Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/@oai/sky/`
— unminified JS, typed API docs, 7 app-specific instruction files, and the Swift service
(`strings` it).

---

## Known gaps, ranked

From Codex's analysis. It explicitly judged our README's earlier claim — that Codex kept
only two advantages — "materially incomplete". Sky is a stateful service; `scu` is a
stateless CLI, and the difference shows on long autonomous runs.

**P0**

1. **Transient UI.** Menus, sheets, popovers, autocomplete and file dialogs live outside
   the target window, sometimes in another process (view services). `shot` captures one
   window; Sky composites a related-window graph with z-order. We are blind here.
2. **Revisioned element identity.** Refs are content hashes with no revision or
   invalidation. Sky refuses a stale handle; we may act on the wrong control after reflow
   or virtualization.
3. **Focus arbitration.** Sky ships a focus-steal suppression subsystem (`thiefPID`,
   `victimPID`, `isMenuDismissalSuppressionEnabled`). Likely why background menu
   interaction is a dead end for us rather than merely awkward.
4. **Session continuity.** No handling of lock, sleep, or turn boundaries.

**P1**

5. Richer node model — subrole, enabled/focused/selected, placeholder, help, action
   *labels*, value-settable. Ours is deliberately compact and loses all of it.
6. Locator chaining (ancestor/descendant), which XCUITest and Playwright have.
7. Hit-test detection of obscured elements.
8. Stage Manager, Spaces, full-screen recovery.

**Unverified, shipped anyway**

- Windowed click routing (window number + subtype 3 on synthetic clicks) — implemented
  from axcli's research, never tested against a Catalyst target.
- Global secure-input refusal — wired, but no live secure-input state was reachable to
  trigger it.

---

## Behaviour worth knowing before you change anything

- **Responder-level chords do not work in the background.** `cmd+a`, `cmd+c` are
  swallowed; `cmd+n` works. A background process has no first responder. Verified against
  three posting strategies. Use `setvalue`/`selecttext` instead.
- **Menu items also fail** — AXPress on a menu item returns success and does nothing.
- **`--mode event` is unreliable** on Catalyst/Electron. AX is the default for good reason.
- **Refs exclude AXValue** deliberately, so writing to a field does not change its own
  handle. They include the window title, or two documents collide.
- **Never launch a credential manager or press a real menu item in tests.** An earlier
  suite did both — it put a Keychain password prompt and an "About This Mac" window on
  the user's screen on every run. He noticed. Do not reintroduce.

---

## STOP — read this before running anything

**Never test `scu` against apps on Boris's laptop. He works on it all day.**

This rule was learned twice, the hard way, and the second time cost his patience:

1. An early regression suite launched Keychain Access and pressed "About This Mac" on
   every run, putting a real password prompt and a system window on his screen.
2. A five-agent review workflow was told TextEdit was a "safe fixture". Each agent opened
   scratch documents with `open -g` — which still puts a window on screen — and five
   agents doing it in parallel buried him in windows while he was working. He asked twice,
   the second time angrily, to stop using the machine.

`open -g` is **not** discreet. It does not steal focus, but the window is visible.

**Where to test instead, in order of preference:**

1. **The Mac Studio** — `ssh studio`, already has `scu` installed and `doctor` healthy.
   Nobody is looking at that screen. This is the default for anything that opens a window.
2. **Read-only probes against already-running apps** on any machine. `axdump`, `find`,
   `windows`, `apps`, `shot` change nothing and open nothing. Most review work needs only
   these.
3. **Source reading plus `scu --help` / `agent-info`** for contract questions.

If a workflow spawns agents that touch apps, put this rule in **every agent's prompt**,
not just the orchestrator's — the previous attempt had a safety block and the agents still
opened windows, because "TextEdit is a safe fixture" contradicted it.

---

## Next session — use UltraCode and Workflows

The user has asked explicitly for **UltraCode and multi-agent Workflows** from here. This
is standing opt-in for this project: author and run workflows rather than working solo,
and use adversarial verification rather than trusting a single pass.

The remaining work is a **review and refinement problem**, not a greenfield build — which
is exactly what fan-out is good at. Suggested shape:

**Workflow 1 — exhaustive review (parallel finders, adversarial verify).**
Dimensions, one agent each: correctness of the AX layer; the safety boundaries; error
taxonomy and suggestion accuracy (every suggestion must be a command that actually
works — two were wrong); the output contract; test coverage honesty (what passes while
being unverified). Then verify each finding with 2–3 independent skeptics prompted to
refute, majority rules. Loop until two dry rounds.

**Workflow 2 — mine the unread Codex report.** 1,366 lines, mostly unconsumed. Fan out by
section, each agent producing concrete implementable recipes with file:line evidence,
then a synthesis pass that ranks by value/effort against the current source.

**Workflow 3 — real-app conformance matrix.** One agent per app (Mail, Notes, Messages,
Safari, Slack, Finder, Music, System Settings, a Catalyst app, an Electron app), each
running the same scripted battery and recording which verbs actually work. This is where
the real bugs are. **Run this entirely on the Mac Studio over `ssh studio`** — it opens
windows by definition, so it must not touch the laptop.

### Attempt 1 of Workflow 1, and why it was killed

Run `wf_0a5536c5-81f` launched five finders (silent-success, safety, suggestions,
contract, test-honesty) with three refuting skeptics per finding. It was **stopped
mid-flight** because the finders were opening TextEdit windows on the laptop.

- Script is saved at
  `~/.claude/projects/-Users-biobook-Code-claude-computer-use/d5fe9c9d-e986-43a9-9657-ced24064804e/workflows/scripts/scu-adversarial-review-wf_0a5536c5-81f.js`
- Six agents had started, **zero completed**, so there is nothing cached worth resuming.
  Do not bother with `resumeFromRunId`; start fresh.
- The design was sound — reuse it, but change the testing rule in the shared CONTEXT
  string: strike "TextEdit is a safe fixture", and replace it with "read-only probes only
  on this machine; anything that opens a window runs over `ssh studio`".

One useful signal before it died: the finders were reading source and probing for several
minutes each without returning, which is normal for this workload. Long silence is not a
stall. Check liveness with mtimes on the transcript dir — and note `find -newermt` is GNU
syntax that silently fails on macOS and will lie to you.

**Then implement** the ranked output, with each fix carrying a regression test that fails
before and passes after.

Guardrails for whoever picks this up:

- Test against real apps, not TextEdit — but do it on the **Studio**, never the laptop.
  TextEdit is also too cooperative to surface the interesting failures.
- Every action verb must report whether it worked.
- Every error must carry a suggestion you have actually run.
- Never leave the user's machine changed: close what you open, restore what you minimize.
- Boris is working on the laptop all day. Do not open windows there, full stop. `open -g`
  is not discreet. When in doubt, run it on the Studio or not at all.

---

## Quick reference

```bash
scu doctor                     # always first; permissions belong to the terminal, or sshd
scu apps | scu windows
scu axdump --app Mail --grep invoice      # leads with url + focus context
scu find --app Mail --text invoice        # ref, index, centre, actions
scu click --app Mail --query 'role=AXButton;text~=Reply'
scu setvalue --query 'role=AXTextArea;win=Inbox' --value "..." --then diff
scu batch --app Messages < script.json    # whole workflow, one process
```

Query keys: `role= id= text~= text== title= win= nth= actionable`.
Flags that matter: `--then dump|diff|focus`, `--no-check`, `--allow-high-risk`,
`--no-context`, `--enhanced`, `--wait auto|MS|0`.

Exit codes: 0 ok, 1 transient, 2 permission/config, 3 bad input, 4 rate limited.
