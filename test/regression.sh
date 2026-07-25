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
# A dedicated document keeps the suite from touching anything the user cares about.
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
  check "setvalue by query"          "$BIN setvalue --pid $PID --query 'role=AXTextArea' --value written2 --no-cursor"
  check "second value landed"        "$BIN axdump --pid $PID | grep -q written2"
  check "key chord accepted"         "$BIN key --pid $PID --key cmd+a"
  check "selecttext"                 "$BIN selecttext --pid $PID --query 'role=AXTextArea' --text written2 --no-cursor"
  check "settle reports ms"          "$BIN settle --pid $PID | grep -q settledMs"
  check "waitfor finds present text" "$BIN waitfor --pid $PID --text written2 --timeout 3"
  check "waitfor times out (exit 1)" "$BIN waitfor --pid $PID --text ZZQQXX --timeout 1; [ \$? -eq 1 ]"
  check "stale ref exits 3"          "$BIN click --pid $PID --ref 'Bogus#000000' --no-cursor; [ \$? -eq 3 ]"
  check "ambiguous query names candidates" "$BIN click --pid $PID --query 'role=AXButton' --no-cursor 2>&1 | grep -q ambiguous_query"
fi

echo "== flow =="
if [ -n "$PID" ]; then
  check "batch runs a script" \
    "echo '[{\"do\":\"setvalue\",\"query\":\"role=AXTextArea\",\"value\":\"batched\"},{\"do\":\"waitfor\",\"text\":\"batched\"}]' | $BIN batch --pid $PID --no-cursor | grep -q '\"completed\":2'"
  check "batch value landed"         "$BIN axdump --pid $PID | grep -q batched"
  # A failing step must report the steps that already succeeded.
  check "batch reports partial progress" \
    "echo '[{\"do\":\"setvalue\",\"query\":\"role=AXTextArea\",\"value\":\"first\"},{\"do\":\"click\",\"ref\":\"Bogus#000\"}]' | $BIN batch --pid $PID --no-cursor 2>&1 | grep -q completedSteps"
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

echo "== non-interference =="
AFTER=$(frontmost)
if [ "$BEFORE" = "$AFTER" ]; then
  pass "frontmost app unchanged ($BEFORE)"
else
  fail "frontmost app changed: $BEFORE -> $AFTER"
fi

echo "== teardown =="
osascript -e 'tell application "TextEdit" to close every document without saving' >/dev/null 2>&1
osascript -e 'tell application "TextEdit" to quit' >/dev/null 2>&1
pass "closed TextEdit without saving"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
