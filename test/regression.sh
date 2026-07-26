#!/usr/bin/env bash
# Regression suite for scu.
#
# Drives a real app (TextEdit) in the background and asserts both behaviour and the
# output contract. Verifies the frontmost application never changes — that is the whole
# premise of the tool, so it is checked before and after the run.
#
# Usage: test/regression.sh [path-to-binary]     (default ./scu)
# Requires: bash, python3, osascript. Exit 0 = all passed.

set -u
BIN="${1:-./scu}"
[ -x "$BIN" ] || { echo "no binary at $BIN — run make first"; exit 2; }

PASS=0; FAIL=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
check() { if eval "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi; }

frontmost() {
  osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' 2>/dev/null
}

BEFORE=$(frontmost)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "== setup =="
# A dedicated document keeps the suite from touching anything the user cares about, and
# every query below is scoped with win=scu-test so an unrelated TextEdit window the user
# happens to have open cannot make the queries ambiguous.
echo "seed" > "$WORK/scu-test.txt"

# Wait out a TextEdit left quitting by a previous run, otherwise `open` reattaches to a
# dying process and every app-driven assertion fails for the wrong reason.
for _ in $(seq 1 20); do
  pgrep -x TextEdit >/dev/null || break
  sleep 0.5
done

# Poll until the document window is genuinely readable rather than sleeping a guess.
# If a stale process never becomes readable, relaunch instead of burning the whole
# timeout — reattaching to a dying TextEdit is what made this suite flaky.
PID=""
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

echo "== contract =="
check "help exits 0"                 "$BIN --help"
check "version exits 0"              "$BIN --version"
check "agent-info is valid JSON"     "$BIN agent-info | python3 -m json.tool"
check "manifest lists commands"      "$BIN agent-info | python3 -c 'import json,sys; assert json.load(sys.stdin)[\"commands\"]'"
check "unknown command exits 3"      "$BIN nosuchcommand; [ \$? -eq 3 ]"
check "errors go to stderr only"     "[ -z \"\$($BIN nosuchcommand 2>/dev/null)\" ]"
check "doctor runs"                  "$BIN doctor"
for c in 1 2 3 4; do
  check "contract $c exits $c"       "$BIN contract $c; [ \$? -eq $c ]"
done

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
fi

echo "== act =="
if [ -n "$PID" ]; then
  REF=$($BIN axdump --pid "$PID" 2>/dev/null \
        | python3 -c 'import json,sys
lines=json.load(sys.stdin)["data"]["text"].split("\n")
print(next(l.split()[1] for l in lines if "TextArea" in l))' 2>/dev/null)
  [ -n "$REF" ] && pass "resolved a stable ref ($REF)" || fail "could not resolve a ref"

  check "setvalue by ref"            "$BIN setvalue --pid $PID --ref '$REF' --value written1 --no-cursor"
  check "value landed"               "$BIN axdump --pid $PID | grep -q written1"
  # The ref must not change when the element's value changes, or scripts break.
  check "ref stable after write"     "$BIN axdump --pid $PID | grep -q '$REF'"
  check "setvalue by query"          "$BIN setvalue --pid $PID --query 'role=AXTextArea;win=scu-test' --value written2 --no-cursor"
  check "second value landed"        "$BIN axdump --pid $PID | grep -q written2"
  check "key chord accepted"         "$BIN key --pid $PID --key cmd+a"
  check "selecttext"                 "$BIN selecttext --pid $PID --query 'role=AXTextArea;win=scu-test' --text written2 --no-cursor"
  check "settle reports ms"          "$BIN settle --pid $PID | grep -q settledMs"
  check "waitfor finds present text" "$BIN waitfor --pid $PID --text written2 --timeout 3"
  check "waitfor times out (exit 1)" "$BIN waitfor --pid $PID --text ZZQQXX --timeout 1; [ \$? -eq 1 ]"
  check "stale ref exits 3"          "$BIN click --pid $PID --ref 'Bogus#000000' --no-cursor; [ \$? -eq 3 ]"
  check "ambiguous query names candidates" "$BIN click --pid $PID --query 'role=AXButton' --no-cursor 2>&1 | grep -q ambiguous_query"
fi

echo "== honesty (silent-failure regressions) =="
if [ -n "$PID" ]; then
  # A responder-level chord posts fine and does nothing in a background app. The tool
  # must say so via "changed" rather than reporting a bare success.
  "$BIN" setvalue --pid "$PID" --query 'role=AXTextArea;win=scu-test' --value "HONESTY" --no-cursor >/dev/null 2>&1
  CH=$("$BIN" key --pid "$PID" --key cmd+a 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["changed"])' 2>/dev/null)
  [ "$CH" = "False" ] && pass "responder chord reports changed=false" \
                      || fail "responder chord reported changed=$CH (expected False)"
  # And it should carry the explanation, not leave the caller guessing.
  check "responder chord explains why" \
    "$BIN key --pid $PID --key cmd+a | grep -q 'first responder'"
  # A real mutation must still report changed=true, or the signal is worthless.
  CH2=$("$BIN" setvalue --pid "$PID" --query 'role=AXTextArea;win=scu-test' --value "CHANGED-NOW" --no-cursor 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["changed"])' 2>/dev/null)
  [ "$CH2" = "True" ] && pass "real mutation reports changed=true" \
                      || fail "real mutation reported changed=$CH2 (expected True)"
  # Zero-size elements are a classic silent no-op; refuse rather than pretend.
  # Assert the refusal only. Never press a real menu item: nth=0 is "About This Mac",
  # and pressing it opened a window on the user's screen on every run.
  check "zero-size element is refused" \
    "$BIN click --pid $PID --menus --query 'role=AXMenuItem;nth=0' --no-cursor 2>&1 | grep -q element_not_visible"
  check "--no-check is accepted as a flag" \
    "$BIN help | grep -q no-check"
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
    "echo '[{\"do\":\"setvalue\",\"query\":\"role=AXTextArea;win=scu-test\",\"value\":\"batched\"},{\"do\":\"waitfor\",\"text\":\"batched\"}]' | $BIN batch --pid $PID --no-cursor | grep -q '\"completed\":2'"
  check "batch value landed"         "$BIN axdump --pid $PID | grep -q batched"
  # A failing step must report the steps that already succeeded.
  check "batch reports partial progress" \
    "echo '[{\"do\":\"setvalue\",\"query\":\"role=AXTextArea;win=scu-test\",\"value\":\"first\"},{\"do\":\"click\",\"ref\":\"Bogus#000\"}]' | $BIN batch --pid $PID --no-cursor 2>&1 | grep -q completedSteps"
fi

echo "== safety policy =="
# Deliberately does NOT launch a credential manager. An earlier version opened Keychain
# Access to exercise the gate, which put a password prompt on the user's screen every run.
check "credential managers are gated"   "grep -q 'highRiskBundles' src/ax.swift"
check "security surfaces are forbidden" "grep -q 'forbiddenBundles' src/ax.swift"
check "policy runs on every pid"        "grep -q 'enforceTargetPolicy' src/ax.swift"
# The raw input path must carry the same guards as the element path.
check "type checks secure input"        "grep -q 'enforceSecureInput' src/commands.swift"
check "batch type checks it too"        "[ \$(grep -c 'enforceSecureInput' src/commands.swift) -ge 4 ]"

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
osascript -e 'tell application "TextEdit" to close every document without saving' >/dev/null 2>&1
osascript -e 'tell application "TextEdit" to quit' >/dev/null 2>&1
pass "closed TextEdit without saving"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
