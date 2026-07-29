#!/usr/bin/env bash
# Regression suite for scu.
#
# Drives a real app (TextEdit) in the background and asserts both behaviour and the
# output contract. Verifies the frontmost application never changes — that is the whole
# premise of the tool, so it is checked before and after the run.
#
# Two rules this suite learned the hard way, and every assertion below follows them:
#
#   1. Assert the EFFECT, not the exit code. Every defect that survived a review round
#      hid behind a plausible exit code — a wrong suggestion, an object where an array
#      belonged, a `changed:false` on a mutation that landed. Where a fix changed a
#      suggestion, assert the suggestion text; where it changed a JSON type, parse the
#      JSON and assert the type.
#   2. Touch only what the suite created. Teardown used to close every TextEdit document
#      without saving, which discarded the unsaved work of whoever happened to have the
#      app open.
#
# Usage: test/regression.sh [path-to-binary]     (default ./scu)
# Requires: bash, python3, osascript. Exit 0 = all passed.

set -u
BIN="${1:-./scu}"
[ -x "$BIN" ] || { echo "no binary at $BIN — run make first"; exit 2; }

PASS=0; FAIL=0; SKIP=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
# A skip is reported, never counted as a pass. A test that cannot run on this machine is a
# coverage hole, and silently passing it is how untested code shipped as "53/53 green".
skip() { printf '  \033[33m·\033[0m %s — skipped: %s\n' "$1" "$2"; SKIP=$((SKIP+1)); }
check() { if eval "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi; }

# A locked screen stops apps publishing accessibility trees, so every UI-driven assertion
# below would fail for a reason that has nothing to do with the code. Detect it once and
# skip those explicitly — reporting a coverage hole beats both a false red and a false green.
SCREEN_LOCKED=no
if python3 -c "
import sys, subprocess
out = subprocess.run(['ioreg','-n','Root','-d1'], capture_output=True, text=True).stdout
sys.exit(0 if 'CGSSessionScreenIsLocked\"=Yes' in out.replace(' ','') else 1)
" 2>/dev/null; then SCREEN_LOCKED=yes; fi
# needs_screen <description> — returns 0 (and records a skip) when the screen is locked.
needs_screen() {
  [ "$SCREEN_LOCKED" = yes ] && { skip "$1" "the screen is locked; apps publish no AX tree"; return 0; }
  return 1
}

is() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — got '$2', want '$3'"; fi; }

# exits <description> <expected> <command...>
exits() {
  local d="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  if [ "$got" = "$want" ]; then pass "$d"; else fail "$d — exit $got, want $want"; fi
}

# Literal substring match via shell globbing, so an assertion can quote a suggestion
# verbatim without escaping it for a regex engine.
saying()  { case "$2" in *"$3"*) pass "$1";; *) fail "$1 — no '$3' in: $(printf '%.180s' "$2")";; esac; }
denying() { case "$2" in *"$3"*) fail "$1 — '$3' is still present";; *) pass "$1";; esac; }

# Parse the envelope and assert on the parsed value. `grep '"windows":\[\]'` cannot tell an
# array from a string that looks like one, and that is exactly the bug class D2 came from.
jassert() {
  if printf '%s' "$2" | python3 -c "import json,sys
d = json.load(sys.stdin)
$3" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}

# Exit code plus a non-empty stderr. A trapping conversion dies with SIGTRAP: exit 133,
# zero bytes on both streams, outside the documented 0-4 contract — so assert the contract
# itself rather than one particular code.
contracted() {
  local d="$1"; shift
  local e; e=$("$@" 2>&1 >/dev/null); local got=$?
  if [ "$got" -gt 4 ]; then
    fail "$d — exit $got is outside the documented 0-4 contract"
  elif [ -z "$e" ]; then
    fail "$d — exit $got but nothing on stderr"
  else
    pass "$d"
  fi
}

frontmost() {
  osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' 2>/dev/null
}

nowms() { python3 -c 'import time; print(int(time.time()*1000))'; }

BEFORE=$(frontmost)
WORK=$(mktemp -d)
CACHE="$HOME/Library/Caches/scu"
# The doctor section makes the cache unwritable on purpose; restore it even if the suite
# dies mid-assertion, or the next run reports a false failure.
trap 'rm -rf "$WORK"; chmod u+rwx "$CACHE" 2>/dev/null' EXIT

echo "== setup =="
# A dedicated document keeps the suite from touching anything the user cares about, and
# every query below is scoped with win=scu-test so an unrelated TextEdit window the user
# happens to have open cannot make the queries ambiguous.
echo "seed" > "$WORK/scu-test.txt"

# A TextEdit the user already has open is theirs: attach to it, and never quit it in
# teardown. Only wait out a process that is running but unreadable — that is a TextEdit
# left quitting by a previous run, and reattaching to a dying one is what made this flaky.
TE_PREEXISTING=0
if pgrep -x TextEdit >/dev/null; then
  if "$BIN" axdump --app TextEdit >/dev/null 2>&1; then
    TE_PREEXISTING=1
  else
    for _ in $(seq 1 20); do
      pgrep -x TextEdit >/dev/null || break
      sleep 0.5
    done
  fi
fi

# Poll until the document window is genuinely readable rather than sleeping a guess.
# If a stale process never becomes readable, relaunch instead of burning the whole
# timeout.
PID=""
if [ "$SCREEN_LOCKED" = yes ]; then
  skip "TextEdit fixture" "the screen is locked; no app publishes an AX tree until it is unlocked"
else
for attempt in 1 2 3; do
  open -g -a TextEdit "$WORK/scu-test.txt" 2>/dev/null
  for _ in $(seq 1 16); do
    CAND=$(pgrep -x TextEdit | head -1)
    if [ -n "$CAND" ] && "$BIN" axdump --pid "$CAND" 2>/dev/null | grep -q TextArea; then
      PID="$CAND"; break
    fi
    sleep 0.5
  done
  [ -n "$PID" ] && break
  [ "$attempt" -lt 3 ] && echo "  (TextEdit not ready, relaunching — attempt $attempt of 3)"
done
if [ -n "$PID" ]; then
  pass "TextEdit ready (pid $PID)"
else
  fail "TextEdit did not become ready after 3 attempts"
  echo "  (app-driven tests will be skipped)"
fi
fi
Q='role=AXTextArea;win=scu-test'

echo "== contract =="
check "help exits 0"                 "$BIN --help"
check "version exits 0"              "$BIN --version"
check "agent-info is valid JSON"     "$BIN agent-info | python3 -m json.tool"
check "manifest lists commands"      "$BIN agent-info | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"commands\"]'"
check "unknown command exits 3"      "$BIN nosuchcommand; [ \$? -eq 3 ]"
check "errors go to stderr only"     "[ -z \"\$($BIN nosuchcommand 2>/dev/null)\" ]"
needs_screen "doctor runs" || check "doctor runs" "$BIN doctor"
for c in 1 2 3 4; do
  check "contract $c exits $c"       "$BIN contract $c; [ \$? -eq $c ]"
done

echo "== tree integrity =="
# Finder's AXApplication was observed listing *itself* as its own first child. Without cycle
# detection the walk re-enters the app once per level and spends the whole node budget
# emitting the same node: a 6000-row tree of duplicates, returned as a success. Assert that
# no single ref dominates a dump — a cycle makes one ref most of the output.
SELFPID=$(pgrep -x Finder | head -1)
if [ -z "$SELFPID" ]; then
  skip "a self-referential AX child cannot flood the tree" "Finder is not running"
elif needs_screen "a self-referential AX child cannot flood the tree"; then
  :
else
  DUP=$("$BIN" axdump --pid "$SELFPID" --no-context --json 2>/dev/null | python3 -c "
import json,sys,collections,re
t = json.load(sys.stdin)['data'].get('text','')
rows = [l for l in t.splitlines() if l.startswith('[')]
if not rows: print(0); raise SystemExit
refs = [r.split(']',1)[1].split()[0] for r in rows]
print(int(100 * collections.Counter(refs).most_common(1)[0][1] / len(refs)))
" 2>/dev/null || echo 100)
  if [ "${DUP:-100}" -lt 50 ]; then
    pass "a self-referential AX child cannot flood the tree (top ref is ${DUP}% of rows)"
  else
    fail "one ref is ${DUP}% of the dump — the walk is re-entering a cycle"
  fi
fi

# A locked screen used to be invisible: doctor reported healthy and an empty tree was blamed
# on the app, with a suggestion (--enhanced) that cannot help. Both must now name the lock.
if [ "$SCREEN_LOCKED" = yes ]; then
  OUT=$("$BIN" doctor --json 2>/dev/null)
  jassert "doctor fails gui_session when the screen is locked" "$OUT" \
    'c = [x for x in d["data"]["checks"] if x["name"] == "gui_session"][0]
assert c["ok"] is False and "locked" in c["detail"], c'
  # Only apps that publish nothing while locked reach the diagnosis path; Finder still
  # exposes its desktop. Find one that does, and assert it is not blamed for the lock.
  BLANK=""
  for a in TextEdit Notes Preview Calculator; do
    AP=$(pgrep -x "$a" | head -1) || true
    [ -z "$AP" ] && continue
    if ! "$BIN" axdump --pid "$AP" >/dev/null 2>&1; then BLANK="$AP"; break; fi
  done
  if [ -z "$BLANK" ]; then
    skip "a locked screen is reported as screen_locked" "no running app returns an empty tree to diagnose"
  else
    ERR=$("$BIN" axdump --pid "$BLANK" 2>&1 >/dev/null)
    saying  "a locked screen is reported as screen_locked, not blamed on the app" "$ERR" '"code":"screen_locked"'
    denying "the locked-screen error does not suggest --enhanced" "$ERR" '--enhanced'
  fi
else
  skip "doctor fails gui_session when the screen is locked" "the screen is unlocked"
  skip "a locked screen is reported as screen_locked" "the screen is unlocked"
fi

# The bundle-policy gate resolved a window's owner with .optionIncludingWindow, which returns
# nothing for a window that is not on screen — so shot refused most of what `windows --all`
# lists, with "No window with id N" and a suggestion naming the command that just printed it.
OFFID=$("$BIN" windows --all --json 2>/dev/null | python3 -c "
import json,subprocess,sys
allw = json.load(sys.stdin)['data']['windows']
on = {w['id'] for w in json.loads(subprocess.run(['$BIN','windows','--json'],capture_output=True,text=True).stdout)['data']['windows']}
off = [w['id'] for w in allw if w['id'] not in on]
print(off[0] if off else '')
" 2>/dev/null)
if [ -z "$OFFID" ]; then
  skip "shot resolves an off-screen window's owner" "no off-screen window to test with"
else
  ERR=$("$BIN" shot --window "$OFFID" --out /nonexistent-dir/x.png 2>&1 >/dev/null)
  denying "shot resolves an off-screen window's owner" "$ERR" "No window with id"
fi

echo "== argv =="
# Global flags used to be read but never stripped, and the dispatch guard rejected any
# leading dash, so `scu --json apps` exited 3 while `scu apps --json` worked.
OUT=$("$BIN" --json contract 0 2>/dev/null)
jassert "--json before the command still routes" "$OUT" 'assert d["status"] == "success"'
exits "--quiet before the command still routes" 0 "$BIN" --quiet contract 0
OUT=$("$BIN" --json help 2>/dev/null)
jassert "--json help emits the usage envelope" "$OUT" 'assert d["data"]["usage"]'
check  "--json apps still routes"    "$BIN --json apps | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"data\"][\"count\"] > 0'"

# flag() was a whole-array membership test, so a token that is the VALUE of an option was
# also matched as a flag. That is prompt-injection reachable: on-screen text arriving as
# `--value` cleared safety gates. Nothing here may be honoured as a flag.
OUT=$("$BIN" key --key --version 2>/dev/null)
is   "an option value is never read as a flag (--key --version)" "$OUT" ""
OUT=$("$BIN" setvalue --value --help 2>/dev/null)
is   "an option value is never read as a request for help"       "$OUT" ""

# `--` ends option parsing, which is the only way to pass a literal flag-shaped token.
OUT=$("$BIN" -- --help 2>&1 >/dev/null); EC=$?
is     "-- terminates flag parsing (exit)" "$EC" 3
saying "-- terminates flag parsing (code)" "$OUT" '"code":"unknown_command"'

echo "== output contract =="
# An empty Swift array satisfies the [(String, Any)] cast vacuously, so EVERY empty list
# used to serialise as {}: the JSON type of a field flipped with its length and typed
# consumers broke on exactly the zero-result path they most need to handle.
OUT=$("$BIN" windows --app zzzznosuchappxyz --json 2>/dev/null)
jassert "an empty window list is [] not {}" "$OUT" \
  'assert isinstance(d["data"]["windows"], list) and d["data"]["windows"] == [], d'
OUT=$("$BIN" batch --pid 999999 --json-script '[]' 2>/dev/null)
jassert "an empty batch step list is [] not {}" "$OUT" \
  'assert isinstance(d["data"]["steps"], list) and d["data"]["steps"] == [], d'
OUT=$("$BIN" agent-info 2>/dev/null)
jassert "the manifest's empty env_vars list is [] not {}" "$OUT" \
  'assert isinstance(d["config"]["env_vars"], list), d["config"]'
# The same field must keep its type when it is non-empty, or the guard traded one bug for
# its mirror image.
OUT=$("$BIN" apps --json 2>/dev/null)
jassert "a non-empty list is still a list of objects" "$OUT" \
  'a = d["data"]["apps"]; assert isinstance(a, list) and isinstance(a[0], dict), type(a)'

echo "== numeric validation =="
# Every user-supplied number that reaches usleep, a UInt32 conversion or a loop bound used
# to trap: SIGTRAP, exit 133, nothing on either stream. The contract says 0-4 with an
# envelope, so that is what is asserted — not one specific code.
contracted "--wait out of range stays inside the exit contract" \
  "$BIN" settle --app Finder --wait 9000000
OUT=$("$BIN" settle --app Finder --wait 9000000 2>&1 >/dev/null); EC=$?
is     "--wait out of range exits 3"   "$EC" 3
saying "--wait out of range is bad_args" "$OUT" '"code":"bad_args"'

contracted "batch sleep with a negative ms stays inside the exit contract" \
  "$BIN" batch --pid 999999 --json-script '[{"do":"sleep","ms":-1}]'
contracted "--timeout nan stays inside the exit contract" \
  "$BIN" waitfor --pid 999999 --text zz --timeout nan
OUT=$("$BIN" waitfor --pid 999999 --text zz --timeout nan 2>&1 >/dev/null)
saying "--timeout nan names the accepted range" "$OUT" 'timeout must be a number between 0 and 86400'

# `--timeout inf` did not trap — it looped forever. perl's alarm is the timeout(1) stock
# macOS does not ship; exit 142 means the alarm fired, i.e. it never returned.
perl -e 'alarm 8; exec @ARGV' "$BIN" waitfor --pid 999999 --text zz --timeout inf >/dev/null 2>&1
is "--timeout inf returns instead of looping forever" "$?" "3"

OUT=$("$BIN" click --pid 999999 --x abc --y 10 2>&1 >/dev/null)
saying "a non-numeric --x is named, not swallowed" "$OUT" "x must be a number, not 'abc'"

echo "== read =="
check "windows is valid JSON"        "$BIN windows | python3 -m json.tool"
check "apps lists processes"         "$BIN apps | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"data\"][\"count\"]>0'"
if [ -n "$PID" ]; then
  check "axdump finds the text area" "$BIN axdump --pid $PID | grep -q TextArea"
  check "axdump --actions annotates" "$BIN axdump --pid $PID --actions | grep -q '{'"
  check "axdump --grep filters"      "$BIN axdump --pid $PID --grep seed | grep -q seed"
  check "find returns a ref"         "$BIN find --pid $PID --text seed | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"data\"][\"count\"]>0'"
  check "empty --text is rejected"   "$BIN find --pid $PID --text ''; [ \$? -eq 3 ]"
  check "resolve by --app works"     "$BIN axdump --app TextEdit | grep -q Application"

  # --grep took its needle as a value while `--no-context` was ALSO honoured as a flag, so
  # the url/focus header vanished. The header is the effect to assert; the exit code never
  # moved.
  OUT=$("$BIN" axdump --pid "$PID" --grep --no-context 2>/dev/null)
  jassert "a flag-shaped --grep needle does not suppress the context header" "$OUT" \
    'assert "focus:" in d["data"]["text"], repr(d["data"]["text"][:120])'

  # The actions list is fetched once during the walk and reused, instead of being fetched,
  # discarded and re-fetched by every renderer. This is an output-equivalence guard: the
  # saving is in IPC count, which the CLI does not expose.
  A=$("$BIN" axdump --pid "$PID" --actions --max 300 --no-context | md5)
  B=$("$BIN" axdump --pid "$PID" --actions --max 300 --no-context | md5)
  is "--actions renders identically across runs" "$A" "$B"
fi

echo "== resolver =="
if [ -n "$PID" ]; then
  # Query.init had no terminal else, so `text=Send` — one character off `text~=Send` — was
  # dropped and the query resolved against role= alone, pressing whatever that matched
  # with ok:true.
  OUT=$("$BIN" actions --pid "$PID" --query 'role=AXApplication;text=zzqqxx-not-present' 2>&1 >/dev/null); EC=$?
  is     "an unrecognised query clause is refused (exit)" "$EC" 3
  saying "an unrecognised query clause is refused (code)" "$OUT" '"code":"bad_query"'
  saying "bad_query names the valid clauses"              "$OUT" 'Note there is no bare `text=`'
  OUT=$("$BIN" actions --pid "$PID" --query 'role=AXApplication;nth=abc' 2>&1 >/dev/null)
  saying "a non-numeric nth= is refused too"              "$OUT" '"code":"bad_query"'

  # collectNodes set currentWindow on entering a window and never restored it, so every
  # node walked afterwards — the whole menu bar in an app that lists windows first — was
  # keyed to an unrelated window's title. Menu bar items belong to no window.
  OUT=$("$BIN" actions --pid "$PID" --menus --query 'role=AXMenuBarItem;win=scu-test' 2>&1 >/dev/null)
  saying "menu bar items are not scoped to a window title" "$OUT" '"code":"no_match"'

  # resolveNode re-implemented the ref lookup with drifted messages, so a fix to
  # resolveSuggestion reached only half the call sites. The single command and the batch
  # step must answer an identical dead ref identically.
  C_OUT=$("$BIN" click --pid "$PID" --ref 'Bogus#000000' --no-cursor 2>&1 >/dev/null); C_EC=$?
  B_OUT=$("$BIN" batch --pid "$PID" --no-cursor --json-script '[{"do":"click","ref":"Bogus#000000"}]' 2>&1 >/dev/null); B_EC=$?
  is "a stale ref exits the same way through click and batch" "$C_EC" "$B_EC"
  C_SUG=$(printf '%s' "$C_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["error"]["suggestion"])' 2>/dev/null)
  B_SUG=$(printf '%s' "$B_OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["error"]["suggestion"])' 2>/dev/null)
  is "a stale ref suggests the same fix through click and batch" "$C_SUG" "$B_SUG"
  is "the stale-ref suggestion is the resolver's own" "$C_SUG" \
     'Re-run `scu find` or `scu axdump` and use the fresh ref.'
fi

echo "== act =="
if [ -n "$PID" ]; then
  REF=$($BIN axdump --pid "$PID" 2>/dev/null \
        | python3 -c 'import json,sys
lines=json.load(sys.stdin)["data"]["text"].split("\n")
# Tree rows only: the dump now leads with url/focus context lines that also mention roles.
print(next(l.split()[1] for l in lines if l.startswith("[") and "TextArea" in l))' 2>/dev/null)
  [ -n "$REF" ] && pass "resolved a stable ref ($REF)" || fail "could not resolve a ref"

  check "setvalue by ref"            "$BIN setvalue --pid $PID --ref '$REF' --value written1 --no-cursor"
  check "value landed"               "$BIN axdump --pid $PID | grep -q written1"
  # The ref must not change when the element's value changes, or scripts break.
  check "ref stable after write"     "$BIN axdump --pid $PID | grep -q '$REF'"
  check "setvalue by query"          "$BIN setvalue --pid $PID --query '$Q' --value written2 --no-cursor"
  check "second value landed"        "$BIN axdump --pid $PID | grep -q written2"
  check "key chord accepted"         "$BIN key --pid $PID --key cmd+a"
  check "selecttext"                 "$BIN selecttext --pid $PID --query '$Q' --text written2 --no-cursor"
  check "settle reports ms"          "$BIN settle --pid $PID | grep -q settledMs"
  check "waitfor finds present text" "$BIN waitfor --pid $PID --text written2 --timeout 3"
  check "waitfor times out (exit 1)" "$BIN waitfor --pid $PID --text ZZQQXX --timeout 1; [ \$? -eq 1 ]"
  check "stale ref exits 3"          "$BIN click --pid $PID --ref 'Bogus#000000' --no-cursor; [ \$? -eq 3 ]"
  check "ambiguous query names candidates" "$BIN click --pid $PID --query 'role=AXButton' --no-cursor 2>&1 | grep -q ambiguous_query"

  # settle read its quiet period from intOpt("quiet"), colliding with the global output
  # boolean, while the documented --quiet-ms was read nowhere. Assert the elapsed time,
  # because both spellings exited 0.
  MS=$("$BIN" settle --pid "$PID" --quiet-ms 1200 2>/dev/null \
       | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["settledMs"])' 2>/dev/null)
  if [ -n "${MS:-}" ] && [ "$MS" -ge 1200 ] 2>/dev/null; then
    pass "--quiet-ms lengthens the settle (${MS}ms)"
  else
    fail "--quiet-ms was ignored (settledMs=${MS:-none}, expected >= 1200)"
  fi

  # --hold reached RunLoop.run(until:) unparsed, so nan became a nonsense deadline. The
  # refusal happens after preflight and before the press, so nothing is driven.
  OUT=$("$BIN" click --pid "$PID" --query "$Q" --hold nan 2>&1 >/dev/null); EC=$?
  is     "--hold nan is refused (exit)" "$EC" 3
  saying "--hold nan names the range"   "$OUT" 'hold must be a number between 0 and 30'

  # An unchecked multiply computed the wheel-tick loop bound, so a huge --pages trapped.
  contracted "a huge --pages stays inside the exit contract" \
    "$BIN" scroll --pid "$PID" --query "$Q" --direction down --pages 9223372036854775807 --no-cursor

  # cmdScroll built AXScrollUp/Down, which no element exposes, so the AX fast path was
  # dead code and every scroll silently fell through to synthetic wheel events. The reply
  # now says which path ran; the old build had no such field at all.
  OUT=$("$BIN" scroll --pid "$PID" --query "$Q" --direction down --pages 1 --no-cursor 2>/dev/null)
  jassert "scroll reports which path it took" "$OUT" \
    'assert d["data"]["via"] in ("ax", "event"), d["data"]'

  # Each end of a drag resolves separately: an element that resolved but has no centre is
  # no_geometry naming the ref, not "pass the flags you just passed".
  APPREF=$("$BIN" axdump --pid "$PID" --no-context 2>/dev/null \
        | python3 -c 'import json,sys
lines=json.load(sys.stdin)["data"]["text"].split("\n")
print(next(l.split()[1] for l in lines if l.startswith("[") and "AXApplication" in l))' 2>/dev/null)
  if [ -n "$APPREF" ]; then
    OUT=$("$BIN" drag --pid "$PID" --from-ref "$APPREF" --to-ref "$APPREF" --no-cursor 2>&1 >/dev/null)
    saying "a resolved element with no centre is no_geometry" "$OUT" '"code":"no_geometry"'
    saying "no_geometry names the ref that failed"            "$OUT" "$APPREF"
  else
    skip "a resolved element with no centre is no_geometry" "no AXApplication row in the dump"
  fi

  # A filtered dump used to overwrite the --diff baseline with its filtered render, so the
  # next --diff reported the entire tree as newly added.
  rm -f "$CACHE/$PID.tree"
  "$BIN" axdump --pid "$PID" >/dev/null 2>&1
  "$BIN" axdump --pid "$PID" --grep zzqqnotpresent >/dev/null 2>&1
  OUT=$("$BIN" axdump --pid "$PID" --diff 2>/dev/null)
  jassert "a filtered dump does not poison the --diff baseline" "$OUT" \
    'assert d["data"]["text"].strip() == "(no change)", d["data"]["text"][:200]'
fi

echo "== verification (silent-success regressions) =="
if [ -n "$PID" ]; then
  # A responder-level chord posts fine and does nothing in a background app. The tool
  # must say so via "changed" rather than reporting a bare success.
  "$BIN" setvalue --pid "$PID" --query "$Q" --value "HONESTY" --no-cursor >/dev/null 2>&1
  CH=$("$BIN" key --pid "$PID" --key cmd+a 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["changed"])' 2>/dev/null)
  [ "$CH" = "False" ] && pass "responder chord reports changed=false" \
                      || fail "responder chord reported changed=$CH (expected False)"
  # And it should carry the explanation, not leave the caller guessing.
  check "responder chord explains why" \
    "$BIN key --pid $PID --key cmd+a | grep -q 'first responder'"
  # A real mutation must still report changed=true, or the signal is worthless.
  CH2=$("$BIN" setvalue --pid "$PID" --query "$Q" --value "CHANGED-NOW" --no-cursor 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["changed"])' 2>/dev/null)
  [ "$CH2" = "True" ] && pass "real mutation reports changed=true" \
                      || fail "real mutation reported changed=$CH2 (expected True)"

  # The fingerprint used to digest text.prefix(40) over settle's depth-10/220-node poll
  # sample, so it was blind to most of a real tree AND to any edit past character 40.
  # These two values share their first 60 characters and change nothing else about the
  # layout, so only a whole-text digest can see the difference.
  LONG=$(printf 'x%.0s' $(seq 1 60))
  "$BIN" setvalue --pid "$PID" --query "$Q" --value "${LONG}HEAD" --no-cursor >/dev/null 2>&1
  OUT=$("$BIN" setvalue --pid "$PID" --query "$Q" --value "${LONG}TAIL" --no-cursor 2>/dev/null)
  jassert "changed sees an edit past character 40" "$OUT" 'assert d["data"]["changed"] is True, d["data"]'

  # The fingerprint walk can hit its node budget, and then changed:false is a maybe. The
  # envelope has to say so rather than imply it compared the whole tree.
  jassert "the action envelope states its fingerprint coverage" "$OUT" \
    'assert d["data"]["changedCoverage"] in ("full", "partial"), d["data"]'

  # verified was emitted as the STRING "true"/"false", so the failure value was truthy in
  # jq, JS and Python alike. Only the tri-state third case stays a string.
  OUT=$("$BIN" setvalue --pid "$PID" --query "$Q" --value verifyme --no-cursor 2>/dev/null)
  jassert "setvalue reports verified as a real boolean" "$OUT" \
    'v = d["data"]["verified"]; assert v is True, (type(v).__name__, v)'

  # selecttext reported neither changed nor settled and skipped preflight entirely. A
  # selection moves no node, so `changed` alone would always be false — hence `verified`.
  "$BIN" setvalue --pid "$PID" --query "$Q" --value written2 --no-cursor >/dev/null 2>&1
  OUT=$("$BIN" selecttext --pid "$PID" --query "$Q" --text written2 --no-cursor 2>/dev/null)
  jassert "selecttext reports changed like every sibling verb" "$OUT" \
    'assert isinstance(d["data"]["changed"], bool), d["data"]'
  jassert "selecttext reads the selection back as verified" "$OUT" \
    'assert d["data"]["verified"] is True, d["data"]'

  # AXSelectedTextRange is an NSRange over the UTF-16 backing store, but the offset was
  # measured in Swift Characters, so one non-BMP character earlier in the value shifted
  # the whole selection. The context header prints what is actually selected.
  "$BIN" setvalue --pid "$PID" --query "$Q" --value 'Hi 👋 world' --no-cursor >/dev/null 2>&1
  "$BIN" selecttext --pid "$PID" --query "$Q" --text world --no-cursor >/dev/null 2>&1
  SEL=$("$BIN" axdump --pid "$PID" --depth 1 2>/dev/null | grep -o "selected: '[^']*'" | head -1)
  is "a selection past an emoji lands on the right characters" "$SEL" "selected: 'world'"

  # Zero-size elements are a classic silent no-op; refuse rather than pretend.
  # Assert the refusal only. Never press a real menu item: nth=0 is "About This Mac",
  # and pressing it opened a window on the user's screen on every run.
  check "zero-size element is refused" \
    "$BIN click --pid $PID --menus --query 'role=AXMenuItem;nth=0' --no-cursor 2>&1 | grep -q element_not_visible"
fi

echo "== multi-window addressing =="
if [ -n "$PID" ]; then
  # Two documents in one app expose identically-shaped elements. Before refs were scoped
  # to their window, both produced the same ref and every lookup became ambiguous.
  echo "second doc" > "$WORK/scu-second.txt"
  open -g -a TextEdit "$WORK/scu-second.txt" 2>/dev/null
  sleep 2
  REFS=$("$BIN" axdump --pid "$PID" 2>/dev/null | python3 -c 'import json,sys
lines=json.load(sys.stdin)["data"]["text"].split("\n")
refs=[l.split()[1] for l in lines if "TextArea" in l]
print(len(refs), len(set(refs)))' 2>/dev/null)
  set -- $REFS
  if [ "${1:-0}" -ge 2 ]; then
    [ "$1" = "$2" ] && pass "refs are unique across windows ($1 text areas, $2 distinct)" \
                    || fail "ref collision: $1 text areas but only $2 distinct refs"
  else
    pass "only one window present; collision check skipped"
  fi
  check "win= scopes to one document" \
    "$BIN setvalue --pid $PID --query 'role=AXTextArea;win=scu-second' --value scoped --no-cursor"
  check "win= wrote the right document" \
    "$BIN axdump --pid $PID --grep scoped | grep -q scoped"
fi

echo "== flow =="
if [ -n "$PID" ]; then
  check "batch runs a script" \
    "echo '[{\"do\":\"setvalue\",\"query\":\"$Q\",\"value\":\"batched\"},{\"do\":\"waitfor\",\"text\":\"batched\"}]' | $BIN batch --pid $PID --no-cursor | grep -q '\"completed\":2'"
  check "batch value landed"         "$BIN axdump --pid $PID | grep -q batched"
  # A failing step must report the steps that already succeeded.
  check "batch reports partial progress" \
    "echo '[{\"do\":\"setvalue\",\"query\":\"$Q\",\"value\":\"first\"},{\"do\":\"click\",\"ref\":\"Bogus#000\"}]' | $BIN batch --pid $PID --no-cursor 2>&1 | grep -q completedSteps"
fi

echo "== batch parity =="
# Batch steps used to re-implement every verb, so the preflight, the secure-field refusal,
# `changed` and required arguments were present on one path and missing on the other.
if [ -n "$PID" ]; then
  # The preflight is the load-bearing half: a step that reports ok:true after acting on a
  # 0x0 element is the exact silent success this tool exists to eliminate. setvalue rather
  # than click, because pressing a real menu item opens a window on the user's screen.
  OUT=$("$BIN" batch --pid "$PID" --menus --no-cursor \
        --json-script '[{"do":"setvalue","query":"role=AXMenuItem;nth=0","value":"x"}]' 2>&1 >/dev/null)
  saying "a batch step runs the same actionability preflight" "$OUT" '"code":"element_not_visible"'

  OUT=$("$BIN" batch --pid "$PID" --no-cursor \
        --json-script "[{\"do\":\"setvalue\",\"query\":\"$Q\",\"value\":\"batchparity\"}]" 2>/dev/null)
  jassert "a batch step reports changed"  "$OUT" 'assert d["data"]["steps"][0]["changed"] is True, d["data"]'
  jassert "a batch setvalue reports verified" "$OUT" 'assert d["data"]["steps"][0]["verified"] is True, d["data"]'
  jassert "the batch envelope states its fingerprint coverage" "$OUT" \
    'assert d["data"]["changedCoverage"] in ("full", "partial"), d["data"]'
fi

# `value` used to be coerced to "" when the key was missing or misspelled, wiping the field
# and reporting ok:true. It is required now, and checked before the target is resolved.
OUT=$("$BIN" batch --pid 999999 --json-script '[{"do":"setvalue","ref":"Bogus#0"}]' 2>&1 >/dev/null)
saying "a batch setvalue without a value is bad_args" "$OUT" '"code":"bad_args"'
saying "…and says which key is missing"              "$OUT" 'value is required'

# waitfor read only step["text"], silently dropping `ref` and leaving an empty needle that
# could never match — and {"gone":true} with no needle returned an instant false success.
OUT=$("$BIN" batch --pid 999999 --json-script '[{"do":"waitfor","ref":"Bogus#000000","timeout":1}]' 2>&1 >/dev/null)
saying "a batch waitfor watches the ref it was given" "$OUT" 'Bogus#000000 never became present'
exits  "a batch waitfor with no needle is refused" 3 \
  "$BIN" batch --pid 999999 --json-script '[{"do":"waitfor","gone":true,"timeout":1}]'

# A resolver failure inside batch was routed through the action mappers, answering a
# permanently stale ref with "run scu doctor" and a retryable exit 1.
exits "a stale ref inside batch exits 3, not 1" 3 \
  "$BIN" batch --pid 999999 --json-script '[{"do":"click","ref":"Bogus#000000"}]'

# The unknown_step suggestion restated the array shape the caller had already written.
OUT=$("$BIN" batch --pid 999999 --json-script '[{"do":"selecttext"}]' 2>&1 >/dev/null)
saying "unknown_step names the supported verbs" "$OUT" \
  'Supported steps are click, setvalue, type, key, scroll, waitfor and sleep'

# Every step reports `changed`, including the ones that touch nothing.
OUT=$("$BIN" batch --pid 999999 --json-script '[{"do":"sleep","ms":10}]' 2>/dev/null)
jassert "even a sleep step reports changed" "$OUT" \
  'assert isinstance(d["data"]["steps"][0]["changed"], bool), d["data"]'

# A forgotten --script used to block forever on an interactive stdin with nothing on
# either stream. A pty is the only way to hand scu a terminal; a pipe must still read.
python3 - "$BIN" <<'PY'
import os, pty, select, sys, time
b = sys.argv[1]
pid, fd = pty.fork()
if pid == 0:
    os.execv(b, [b, "batch", "--pid", "999999"])
status, deadline = None, time.time() + 6
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try: os.read(fd, 4096)
        except OSError: pass
    done, st = os.waitpid(pid, os.WNOHANG)
    if done:
        status = st
        break
if status is None:
    os.kill(pid, 9); os.waitpid(pid, 0); sys.exit(1)
sys.exit(0 if os.waitstatus_to_exitcode(status) == 3 else 1)
PY
[ $? -eq 0 ] && pass "batch on an interactive stdin fails instead of blocking" \
             || fail "batch on an interactive stdin blocked or exited wrongly"

echo "== launch =="
# The old advice was "pass the exact display name", which is exactly what the caller had
# just done. A suggestion has to be a command that produces the one form that resolves.
OUT=$("$BIN" launch --app ZzNoSuchAppZz 2>&1 >/dev/null); EC=$?
is     "an unknown app is a bad argument"        "$EC" 3
saying "app_not_found suggests a runnable command" "$OUT" "osascript -e 'id of app"

echo "== safety policy =="
# These assertions used to grep the Swift source, which passes whether or not the gate
# ever runs. Every one below invokes the binary and checks what it actually does.

# The parser defect was directly prompt-injection reachable: a flag-shaped string arriving
# as a --value payload was also honoured as a flag, so on-screen text could clear a safety
# gate. --no-check is the observable one — with it honoured, setvalue skipped the
# preflight and reported ok:true after writing into a 0x0 element.
if [ -n "$PID" ]; then
  OUT=$("$BIN" setvalue --pid "$PID" --menus --query 'role=AXMenuItem;nth=0' \
        --value '--no-check' --no-cursor 2>&1 >/dev/null)
  saying "a --value payload cannot turn itself into --no-check" "$OUT" '"code":"element_not_visible"'
fi

# `shot` addresses a window id and never resolved a pid, so it walked straight past the
# policy gate — a credential manager's window was one id away. Resolving the owner first
# also turns an unknown id into a bad argument instead of a capture attempt.
OUT=$("$BIN" shot --window 999999999 --out "$WORK/none.png" 2>&1 >/dev/null); EC=$?
is     "shot refuses an unknown window id (exit)" "$EC" 3
saying "shot refuses an unknown window id (code)" "$OUT" '"code":"bad_args"'
# screencapture's own stderr used to interleave with the envelope and break `2>&1 | jq`.
jassert "shot's stderr is the envelope and nothing else" "$OUT" 'assert d["status"] == "error", d'

# The denylist itself, exercised only against a credential manager that is ALREADY
# running. Launching one is forbidden — an earlier suite put a Keychain password prompt on
# the user's screen on every run — so this skips rather than starting anything.
HRPID=$("$BIN" apps --json 2>/dev/null | python3 -c '
import json, sys
risky = {"com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword",
         "com.bitwarden.desktop", "com.dashlane.dashlanephonefinal", "com.lastpass.LastPass",
         "com.nordpass.macos", "me.proton.pass.electron", "com.apple.keychainaccess"}
print(next((str(a["pid"]) for a in json.load(sys.stdin)["data"]["apps"] if a["bundle"] in risky), ""))' 2>/dev/null)
if [ -n "${HRPID:-}" ]; then
  OUT=$("$BIN" find --pid "$HRPID" --text zzqqxx 2>&1 >/dev/null); EC=$?
  is     "a running credential manager is gated (exit 2)" "$EC" 2
  saying "a running credential manager is gated (code)"   "$OUT" '"high_risk_target"'
else
  skip "the high-risk denylist refuses a credential manager" \
       "none is running, and this suite never launches one"
fi

# The launch gate (bundle checked before openApplication) and the forbidden-bundle branch
# both need a target this suite is not allowed to start or drive.
skip "launch refuses a credential manager before starting it" \
     "proving it requires attempting to launch one"
skip "forbidden system security surfaces are refused" \
     "SecurityAgent and friends cannot be summoned safely"
skip "secure_field exits 2 on every path" \
     "no focused AXSecureTextField is reachable without a real password prompt"
skip "secure input blocks synthetic keystrokes" \
     "IsSecureEventInputEnabled cannot be forced on from a test"

# What the binary tells an agent about the gates it cannot exercise here.
HELP=$("$BIN" --help 2>/dev/null)
saying "help states credential managers need an explicit opt-in" "$HELP" '--allow-high-risk'
saying "help states secure fields have no override"             "$HELP" 'secure_field'

echo "== manifest and docs =="
INFO=$("$BIN" agent-info 2>/dev/null)
# --then, --path and the tree-budget flags all worked and were in no manifest; --hold was
# filed as command-scoped although every action reads it.
jassert "the manifest lists every global flag that works" "$INFO" \
  'g = d["global_flags"]
missing = [k for k in ["--then", "--path", "--depth", "--max", "--menus", "--enhanced", "--hold"] if k not in g]
assert not missing, missing'
jassert "axdump documents --no-context"  "$INFO" \
  'assert "--no-context" in [o["name"] for o in d["commands"]["axdump"]["options"]]'
jassert "find documents --actionable"    "$INFO" \
  'assert "--actionable" in [o["name"] for o in d["commands"]["find"]["options"]]'

# --no-check reads as though it lifts the secure-field refusal too. It never has.
jassert "--no-check says what it does not skip" "$INFO" \
  'assert "never skips the secure-text-field refusal" in d["global_flags"]["--no-check"]["description"], d["global_flags"]["--no-check"]'

# env_prefix advertised BGCU_, the pre-rename name, for a variable nothing reads.
jassert "the manifest advertises the current env prefix" "$INFO" \
  'assert d["config"]["env_prefix"] == "SCU_" and d["config"]["env_vars"] == [], d["config"]'
denying "no pre-rename BGCU_ names survive in the manifest" "$INFO" "BGCU_"

# The argv policy the parser now implements has to be discoverable, or an agent guesses.
jassert "the manifest states the argv policy" "$INFO" \
  'a = d["argv"]; assert a["global_flags_anywhere"] is True and a["end_of_flags"] == "--", a'

# doctor emits a status and an exit code no other command does; both were undocumented.
jassert "the manifest documents doctor's own envelope" "$INFO" \
  'e = d["envelope"]["doctor"]; assert "setup_incomplete" in e and "exit 2" in e, e'
jassert "batch documents the stdin path" "$INFO" \
  'assert "stdin" in d["commands"]["batch"]["description"], d["commands"]["batch"]'

# helpText printed the same win= sentence twice, the second copy misfiled under SAFETY.
N=$(printf '%s' "$HELP" | grep -o 'win= scopes' | wc -l | tr -d ' ')
is "help explains win= exactly once" "$N" "1"
saying "help documents the changed-coverage caveat" "$HELP" "changedCoverage"

# The embedded skill carried the pre-rename repo path, so the rebuild command it hands
# agents could not run, and it documented the settle period as --quiet.
"$BIN" skill install --path "$WORK/deep/nested/scu" >/dev/null 2>&1
if [ -f "$WORK/deep/nested/scu/SKILL.md" ]; then
  pass "skill install creates an explicit --path outright"
  MD=$(cat "$WORK/deep/nested/scu/SKILL.md")
  saying  "the skill's rebuild command names the current repo" "$MD" 'cd ~/Code/super-computer-use && make install'
  denying "the skill drops the pre-rename repo path"           "$MD" '~/Code/scu'
  saying  "the skill names --quiet-ms for the settle period"   "$MD" '`--quiet-ms` (default 250)'
  # The batch surface an agent has to reason about: the step keys, that waitfor takes a
  # ref, and that a step is not a cheaper path that skips the checks.
  saying  "the skill lists the batch step keys"                "$MD" '`waitfor` accepting `ref` as well as `text`'
  saying  "the skill says a step runs the same preflight"      "$MD" 'same preflight and reports the same `changed`'
  saying  "the skill lists the safety codes to branch on"      "$MD" '`secure_field`, `secure_input_active`, `forbidden_target`'
else
  fail "skill install did not create $WORK/deep/nested/scu/SKILL.md"
fi

echo "== doctor =="
# doctor is the one nonzero-exit path outside fail(). It used to write a success-shaped
# envelope with an undocumented third status while exiting 2, so an agent branching on
# status saw a non-error for an unhealthy machine.
OUT=$("$BIN" doctor --json 2>/dev/null); EC=$?
ST=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' 2>/dev/null)
case "$ST:$EC" in
  success:0) pass "doctor's status and exit code agree (success/0)" ;;
  error:2)   pass "doctor's status and exit code agree (error/2)"
             jassert "an unhealthy doctor carries the documented error object" "$OUT" \
               'assert d["error"]["code"] == "setup_incomplete" and d["error"]["suggestion"], d["error"]' ;;
  *)         fail "doctor reported status '$ST' with exit $EC — only success/0 and error/2 are documented" ;;
esac
jassert "doctor keeps the full report on stdout either way" "$OUT" 'assert d["data"]["checks"], d'

# Force the one failure a test can force: a non-blocking check. That must stay a success
# with healthy:false, not the old "partial_success" that no consumer knew to expect.
# Needs an otherwise-healthy machine: a locked screen fails gui_session, which IS blocking,
# so the status would be error for a reason this assertion is not about.
if needs_screen "a non-blocking failure stays status success"; then
  skip "a non-blocking failure still exits 0" "the screen is locked; gui_session fails blocking"
else
mkdir -p "$CACHE"
chmod 500 "$CACHE"
OUT=$("$BIN" doctor --json 2>/dev/null); EC=$?
chmod u+rwx "$CACHE"
jassert "a non-blocking failure stays status success" "$OUT" \
  'assert d["status"] == "success" and d["data"]["healthy"] is False, (d["status"], d["data"]["healthy"])'
is "a non-blocking failure still exits 0" "$EC" "0"
fi

# Three fixes that a caller follows literally, so the words are the contract.
OUT=$("$BIN" doctor --json 2>/dev/null)
jassert "the screencapture fix does not send anyone to Command Line Tools" "$OUT" \
  'f = [c["fix"] for c in d["data"]["checks"] if c["name"] == "screencapture_binary"][0]
assert "Command Line Tools cannot restore it" in f, f'
jassert "the ax_live_probe fix matches what was actually probed" "$OUT" \
  'c = [c for c in d["data"]["checks"] if c["name"] == "ax_live_probe"][0]
assert ("No regular app was running" in c["fix"]) == (c["detail"] == "no running app to probe"), c'

# The screen_recording fix was terminal-only: over SSH it named a row that does not exist
# and told the user to reopen a window that is not there. Both branches are exercisable
# from here, because isRemoteSession only reads the environment.
OUT=$(SSH_CONNECTION="1 2 3 4" "$BIN" doctor --json 2>/dev/null)
jassert "over SSH the screen-recording fix names the sshd binary" "$OUT" \
  'f = [c["fix"] for c in d["data"]["checks"] if c["name"] == "screen_recording"][0]
assert "/usr/libexec/sshd-keygen-wrapper" in f and "quit and reopen" not in f, f'
OUT=$(env -u SSH_CONNECTION -u SSH_TTY -u SSH_CLIENT "$BIN" doctor --json 2>/dev/null)
jassert "locally it keeps the terminal wording" "$OUT" \
  'f = [c["fix"] for c in d["data"]["checks"] if c["name"] == "screen_recording"][0]
assert "quit and reopen" in f, f'

# --quiet is documented as "suppress human output" and every other command honours it.
# A pty is needed because scu switches to JSON as soon as stdout is a pipe.
# `script` echoes a literal "^D" plus backspaces of its own when the child closes the pty;
# that is the harness talking, not scu. Drop the control bytes and that artifact, and what
# is left is whatever scu actually printed.
# --quiet suppresses the success report; an unhealthy machine still prints its error, so
# this only means anything when the machine is healthy.
if ! needs_screen "doctor --quiet prints nothing on a terminal"; then
QOUT=$(script -q /dev/null "$BIN" doctor --quiet 2>/dev/null | tr -cd '[:print:]' | sed 's/\^D//g' | tr -d ' ')
is "doctor --quiet prints nothing on a terminal" "$QOUT" ""
fi

echo "== capture =="
if [ -n "$PID" ]; then
  WID=$($BIN windows --app TextEdit 2>/dev/null \
        | python3 -c 'import json,sys
w=json.load(sys.stdin)["data"]["windows"]
print(w[0]["id"] if w else "")' 2>/dev/null)
  if [ -n "$WID" ]; then
    check "shot writes a png"        "$BIN shot --window $WID --out $WORK/s.png && [ -s $WORK/s.png ]"
    check "shot reports scale"       "$BIN shot --window $WID --out $WORK/s.png | grep -q scale"
  fi
fi

echo "== cost =="
# unlockAccessibility short-circuited on its memo only when --enhanced was absent, so
# --enhanced re-paid a 250ms settle on every tree walk — and a single action walks the
# tree half a dozen times. The absolute time is machine-dependent; the DELTA against the
# same script without --enhanced is not.
ELECTRON=$("$BIN" apps --json 2>/dev/null | python3 -c '
import json, sys
# Apps that accept AXManualAccessibility, which is what triggered the repeated settle.
wanted = ["Slack", "Cursor", "Visual Studio Code", "Notion", "Discord", "Obsidian", "ChatGPT", "Claude"]
names = {a["name"] for a in json.load(sys.stdin)["data"]["apps"]}
print(next((w for w in wanted if w in names), ""))' 2>/dev/null)
if [ -n "${ELECTRON:-}" ]; then
  SCRIPT='[{"do":"waitfor","text":"zzzqqq","gone":true},{"do":"waitfor","text":"zzzqqq","gone":true},{"do":"waitfor","text":"zzzqqq","gone":true}]'
  T0=$(nowms); "$BIN" batch --app "$ELECTRON" --no-cursor --json-script "$SCRIPT" >/dev/null 2>&1; T1=$(nowms)
  PLAIN=$((T1 - T0))
  T0=$(nowms); "$BIN" batch --app "$ELECTRON" --enhanced --no-cursor --json-script "$SCRIPT" >/dev/null 2>&1; T1=$(nowms)
  ENH=$((T1 - T0))
  DELTA=$((ENH - PLAIN))
  if [ "$DELTA" -lt 700 ]; then
    pass "--enhanced unlocks once per process, not once per walk ($ELECTRON: ${PLAIN}ms -> ${ENH}ms)"
  else
    fail "--enhanced re-unlocks on every walk ($ELECTRON: plain ${PLAIN}ms, enhanced ${ENH}ms)"
  fi
else
  skip "--enhanced unlocks once per process" "no app that accepts AXManualAccessibility is running"
fi

# urlSummary drove an unbounded per-node walk of every window on every axdump, ignoring
# --depth and --max entirely: 21.89s against 0.08s with --no-context, for one header line.
# The budget is shared across windows now, so the cost no longer scales with them.
T0=$(nowms); "$BIN" axdump --app Finder --depth 1 >/dev/null 2>&1; T1=$(nowms)
DUMPMS=$((T1 - T0))
if [ "$DUMPMS" -lt 3000 ]; then
  pass "axdump --depth 1 stays bounded (${DUMPMS}ms)"
else
  fail "axdump --depth 1 took ${DUMPMS}ms — the context walk is ignoring the budget again"
fi
# …and the header it exists for must still appear. Only a browser publishes AXURL, so this
# needs one with a window open.
BROWSER=""
for b in "Safari" "Google Chrome"; do
  C=$("$BIN" windows --app "$b" --json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null)
  [ "${C:-0}" -gt 0 ] && { BROWSER="$b"; break; }
done
if [ -n "$BROWSER" ] && [ "$SCREEN_LOCKED" = yes ]; then
  skip "the url header survives the budget" "the screen is locked; no AXURL is published"
elif [ -n "$BROWSER" ]; then
  check "the url header survives the budget" \
    "$BIN axdump --app '$BROWSER' --depth 2 | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"data\"][\"text\"].startswith(\"url: \")'"
else
  skip "the url header survives the budget" "no browser window is open to publish an AXURL"
fi

echo "== non-interference =="
# The promise is that scu never brings its target forward — not that focus is frozen.
# Asserting "frontmost never changed" false-fails whenever the person running the suite
# switches apps mid-run, which is exactly what they should be free to do.
AFTER=$(frontmost)
if [ "$AFTER" = "TextEdit" ]; then
  fail "target app was brought to the front (frontmost = TextEdit)"
else
  if [ "$BEFORE" = "$AFTER" ]; then
    pass "target never came forward; focus stayed on $AFTER"
  else
    pass "target never came forward (you switched $BEFORE -> $AFTER during the run)"
  fi
fi

echo "== teardown =="
# Only what this suite opened. "close every document without saving" threw away the
# unsaved work of anyone who happened to have TextEdit open, and quitting the app took
# the rest of their session with it.
for doc in scu-test.txt scu-second.txt; do
  osascript -e "tell application \"TextEdit\" to close (every document whose name is \"$doc\") saving no" >/dev/null 2>&1
done
if [ "$TE_PREEXISTING" -eq 1 ]; then
  pass "closed the suite's documents; left the TextEdit you already had open"
else
  # Quit only when nothing else is open in it: a document opened mid-run belongs to
  # someone else, and quitting would either discard it or block on a save sheet.
  LEFT=$(osascript -e 'tell application "TextEdit" to count documents' 2>/dev/null)
  if [ "${LEFT:-1}" = "0" ]; then
    osascript -e 'tell application "TextEdit" to quit' >/dev/null 2>&1
    pass "closed the suite's documents and quit the TextEdit it started"
  else
    pass "closed the suite's documents; left TextEdit running ($LEFT other document(s) open)"
  fi
fi

echo
echo "passed $PASS, failed $FAIL, skipped $SKIP"
[ "$FAIL" -eq 0 ] || exit 1
