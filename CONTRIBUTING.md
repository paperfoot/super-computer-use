# Contributing

## App quirks are the most useful contribution

Accessibility support varies wildly between Mac apps. Some publish a clean tree; some
expose buttons with no press action; some publish nothing until you set an obscure
attribute. Every quirk you document saves the next person an afternoon.

If an app misbehaves, open an issue with:

```bash
bgcu doctor
bgcu axdump --app "That App" --actions --max 200
```

Include what you expected and what happened. That's enough to turn it into a documented
workaround or a code fix.

## Building

```bash
git clone https://github.com/paperfoot/bgcu && cd bgcu
make            # builds ./bgcu
make test       # regression suite, drives a real TextEdit window
make conform    # agent-cli-framework conformance probe
```

Both suites must pass before a PR merges. `make test` needs Accessibility granted to your
terminal; run `bgcu doctor` if it complains.

## Code layout

```
src/output.swift     format detection, JSON envelope, exit codes
src/args.swift       argument access
src/ax.swift         tree walking, addressing, settle, cursor, windows
src/actions.swift    press/type/key/scroll/drag primitives
src/commands.swift   one function per command
src/doctor.swift     permission diagnostics
src/agentinfo.swift  capability manifest and help text
src/main.swift       entry point and dispatch
```

Plain Swift, no third-party dependencies. Keep it that way.

## Rules that aren't negotiable

These hold the agent contract together. A change that breaks one is a bug.

1. **Every stdout path respects the output format.** JSON when piped, human text in a
   terminal. No raw text leaks.
2. **Errors go to stderr** with a code, a message, and a suggestion. The suggestion is a
   literal command someone can run — a wrong one is worse than none.
3. **Exit codes are 0-4 and nothing else.** `0` success, `1` transient, `2` config,
   `3` bad input, `4` rate limited.
4. **`agent-info` matches reality.** If it lists a command, that command works. Add new
   commands to the manifest in the same commit.
5. **No interactive prompts.** Never read stdin except for a piped batch script.
6. **Never steal focus.** No `activate`, no `activateIgnoringOtherApps`. If a change makes
   an app come forward, it's wrong, and `make test` will catch it.

## Adding a command

1. Write `cmdYourThing()` in `commands.swift`, ending in `emit(...)` or `fail(...)`.
2. Add a `case` in `main.swift`.
3. Add a `CmdSpec` to `commandSpecs` in `agentinfo.swift`.
4. Add a line to `helpText`.
5. Add a case to `test/regression.sh`.

## Style

Match the surrounding code. Comments explain *why*, not *what* — the AX API has enough
non-obvious behaviour to justify them, and the existing comments are the model.
