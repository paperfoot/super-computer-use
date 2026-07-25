let embeddedSkill = """
---
name: scu
description: Fast, scriptable computer use for macOS — drive any Mac app from the CLI via the Accessibility API. ~35ms reads instead of screenshot+vision, batch whole workflows in one call, target elements by meaning not pixels, and it never steals focus or moves the pointer. Use for ANY macOS GUI automation or native-app task: reading Mail/Notes/Messages/WhatsApp, driving native apps, multi-step UI workflows, or when the built-in computer-use MCP refuses because another app is frontmost. Triggers: "computer use", "control my Mac", "read that app", "automate this app", "without taking over my screen", "scu".
---

# scu — super computer use

Binary `~/.local/bin/scu`; repo at `~/Code/scu` (Swift, no dependencies).
Rebuild: `cd ~/Code/scu && make install`

**Run `scu doctor` first if anything fails** — it names the exact permission and pane.
`scu agent-info` prints the full machine-readable manifest; `scu help` the reference.

Drives one app via the Accessibility API and per-process events. The frontmost app never
changes and the user's pointer never moves — unlike the built-in `computer-use` MCP, which
requires the target frontmost and hides every other app.

## Use it in this order

1. **`find` or `axdump`** to see state and get a target handle.
2. **Act by `--query`** (readable, portable) or `--ref` (exact). Avoid `--index`.
3. **`waitfor`** instead of guessing a sleep.
4. **`batch`** whenever there are 2+ steps — it collapses N model round-trips into one.

## Addressing: query > ref > index

```bash
--query 'role=AXButton;text~=send;nth=0'   # readable, survives app updates
--ref 'Button#3f2a1b'                      # exact fingerprint from find/axdump
--index 42                                 # positional; breaks on any reflow
```

Query keys: `role=`, `id=` (AXIdentifier), `text~=` (contains), `text==` (exact),
`title=`, `nth=` (0-based among matches), `actionable`. Ambiguous queries fail with the
candidate list rather than guessing — add `nth=` or narrow the query.

Refs deliberately exclude the element's **value**, so writing to a field does not change
its own handle; the same ref keeps working across repeated writes.

## Commands

```bash
# read
scu windows [--app NAME] [--all]        # --all includes minimized/hidden
scu apps                                # running apps with pids
scu axdump --pid P [--grep T] [--diff] [--actions] [--actionable] [--menus] [--enhanced]
scu find --pid P --text T               # ref + index + centre + actions + path
scu actions --pid P --query Q            # what this element supports
scu shot --window ID --out F            # capture even when occluded; prints origin+scale

# act  (--no-cursor hides the overlay; --wait auto|MS|0 controls settle)
scu click --pid P --query Q [--mode ax|event] [--button right] [--count 2]
scu setvalue --pid P --query Q --value V
scu selecttext --pid P --query Q --text T [--cursor before|after]
scu type --pid P --text T
scu key --pid P --key "cmd+shift+a"
scu scroll --pid P --query Q --direction down [--pages N]
scu drag --pid P --from-ref A --to-ref B
scu perform --pid P --query Q --action AXShowMenu

# flow
scu waitfor --pid P --text T [--gone] [--timeout S]
scu batch --pid P --script F            # or pipe JSON on stdin
scu settle --pid P

# util
scu unhide --pid P                      # un-hide + un-minimize, no activation
scu launch --app NAME                   # launch without stealing focus
scu cursor --x X --y Y --label T
```

`--pid` can be replaced by `--app NAME` anywhere.

## batch — the biggest win

Model round-trips dominate cost, not execution. `batch` runs a whole script in one
process; each step re-resolves its target against a fresh tree, so a mid-script reflow is
handled instead of silently clicking the wrong thing. It stops at the first failure and
reports which steps completed.

```bash
cat <<'JSON' | scu batch --pid $PID
[ {"do":"setvalue","query":"role=AXTextField;nth=0","value":"hello"},
  {"do":"key","key":"return"},
  {"do":"waitfor","text":"Results","timeout":8},
  {"do":"click","query":"role=AXButton;text~=save"} ]
JSON
```
Steps: `click`, `setvalue`, `type`, `key`, `scroll`, `waitfor`, `sleep`.

## Settling

Default `--wait auto` registers an AXObserver and returns once the app has been quiet for
`--quiet` ms (default 250), capped by `--wait-max` (5000), and only when nothing is still
marked busy. Falls back to polling a tree signature if the app refuses an observer.
Measured: ~280ms on a simple write. `--wait 300` forces a fixed sleep; `--wait 0` skips.

## Errors are structured

Errors go to **stderr** as `{"version":"1","status":"error","error":{code,message,suggestion}}`;
stdout stays clean so `scu axdump … | jq` never breaks. Every error carries a `suggestion`
that is a literal command to run.

Exit codes: `0` ok, `1` transient (retry), `2` permission/config (fix setup, do not retry),
`3` bad input (fix arguments), `4` rate limited.

Codes to branch on: `stale_ref`, `ambiguous_ref`, `no_match`, `ambiguous_query`,
`no_window`, `window_minimized`, `permission_denied`, `no_ax_tree`, `press_failed`,
`setvalue_failed`, `timeout`, `app_not_running`, `capture_failed`.

## Gotchas

- **`--mode event` is unreliable.** Catalyst and Electron apps silently drop per-PID
  synthetic mouse events. Default `ax` mode (AXPress) is the reliable path.
- **`setvalue` beats `type`** for background apps — keystrokes tend to follow real focus.
- **Minimized windows cannot receive clicks.** `scu unhide --pid P` first. Reading works
  while minimized, but a captured frame can be stale; AX data stays live.
- **Shallow tree on a modern app?** Try `--enhanced` (sets AXEnhancedUserInterface), which
  some Catalyst/wrapped-iOS apps require before publishing a full tree.
- **No AX tree at all** → fall back to `shot` + vision; needs the window un-minimized
  (occlusion is fine). `shot` prints `originX/originY/scale` so image pixels map back:
  `globalX = originX + pixelX / scale`.
- Prefer AX text over screenshots generally: ~35ms and exact, vs a vision round-trip.

## App quirks found in testing

| App | Behaviour | Do this |
|---|---|---|
| Notes, Reminders, Calendar | launch with no window; tree is just the app node | `scu key --key cmd+n` first |
| Music | sidebar rows expose no AXPress, only ShowDefaultUI/ShowAlternateUI | `perform` a listed action, or double-click |
| Finder | actionable items expose no AXPress | use `perform`, or `--mode event` |
| Chrome | rich tree but no AXIdentifier | target with `text~=`, not `id=` |
| WhatsApp / Catalyst | drop per-PID synthetic mouse events | keep default `ax` mode; `setvalue` over `type` |

`scu` distinguishes these for you: an empty tree returns `no_window`, `window_minimized`,
`permission_denied`, or `no_ax_tree` — each with the matching fix.

## Permissions and safety

Screen Recording (for `shot`) and Accessibility (everything else) must be granted to the
**terminal running Claude Code**, not to Claude. `scu` inherits those grants and has no
per-app approval gate of its own, unlike the computer-use MCP. So: never click links from
messages or emails, and get explicit approval before sending messages, submitting forms,
deleting data, or any irreversible action.
"""
