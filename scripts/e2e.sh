#!/usr/bin/env bash
# Live end-to-end: give the real binary a real task against a real model, then
# assert the workspace actually changed.
#
# `zig build test` proves the tools decode their arguments. It cannot prove the
# loop finishes a job, because that needs a model. This does. Every bug that
# shipped in this repo -- a dead interrupt, non-recursive grep, tool arguments
# delivered with literal backslash-n -- would have failed one of these cases.
#
#   scripts/e2e.sh                 run every case
#   scripts/e2e.sh edit            run one case
#   OMFX_E2E_ARGS="--provider groq --model x" scripts/e2e.sh
#
# Exit 0 all passed, 1 a case failed, 2 setup is wrong.

set -uo pipefail

BIN="${OMFX_BIN:-./zig-out/bin/omfx}"
# Resolved up front: every case runs with cwd inside its own workspace.
[ -e "$BIN" ] && BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
EXTRA="${OMFX_E2E_ARGS:-}"
ONLY="${1:-}"
PASS=0
FAIL=0

[ -x "$BIN" ] || { echo "no binary at $BIN; run: zig build" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Runs omfx in a fresh workspace. Prints nothing unless -v.
ask() {
  local dir="$1" prompt="$2"
  ( cd "$dir" && "$BIN" ask --yolo $EXTRA "$prompt" ) >"$dir/.omfx-out" 2>&1
  # A binary that never launched must not look like a tool that reported a
  # problem; the honesty case would pass on the shell's own error otherwise.
  if grep -q 'No such file or directory$' "$dir/.omfx-out" && [ ! -x "$BIN" ]; then
    echo "omfx did not launch: $BIN" >&2
    exit 2
  fi
}

case_start() {
  CASE="$1"
  DIR="$WORK/$CASE"
  mkdir -p "$DIR"
  ( cd "$DIR" && git init -q . )
}

ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  {
  FAIL=$((FAIL+1))
  printf '  FAIL  %s\n     %s\n' "$CASE" "$1"
  printf '     transcript tail:\n'
  tail -c 1200 "$DIR/.omfx-out" 2>/dev/null | sed 's/^/       /'
}

want() { # description, expected, actual
  if [ "$2" = "$3" ]; then ok "$CASE: $1"; else
    bad "$1
       expected: $(printf %q "$2")
       actual:   $(printf %q "$3")"
  fi
}

skip() { [ -n "$ONLY" ] && [ "$ONLY" != "$1" ]; }

# Every case below needs a model. CI has no provider credentials, so offline it
# runs the one thing that is still worth asserting there -- the binary a release
# would ship actually launches -- and says plainly that the rest did not run.
if [ -n "${OMFX_E2E_OFFLINE:-}" ]; then
  CASE=launch
  DIR="$WORK"
  v="$("$BIN" version 2>&1)" && [ -n "$v" ] \
    && ok "launch: $v" || bad "the binary did not run: $v"
  "$BIN" help >/dev/null 2>&1 && ok "launch: help exits clean" || bad "help failed"
  if zig build test -- --test-filter "interrupt harness" >/dev/null 2>&1; then
    ok "interrupt harness: unit tests pass"
  else
    bad "interrupt harness unit tests failed"
  fi
  echo
  printf '%d passed, %d failed (offline: model cases not run)\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

# --- 1. write: the file must contain real newlines, not the characters \ and n.
if ! skip write; then
  case_start write
  ask "$DIR" 'Use the write tool to create hello.py containing exactly two lines: "def f():" then "    return 1"'
  got="$(cat "$DIR/hello.py" 2>/dev/null || echo '<missing>')"
  want "write produced real newlines" "$(printf 'def f():\n    return 1')" "$(printf '%s' "$got" | sed -e 's/[[:space:]]*$//')"
fi

# --- 2. edit: a multi-line old_string has to match what is on disk.
if ! skip edit; then
  case_start edit
  printf 'def div(a, b):\n    return a / b\n' > "$DIR/calc.py"
  ask "$DIR" 'In calc.py, make div return None when b is 0. Keep the rest of the function.'
  if grep -q 'return None' "$DIR/calc.py" 2>/dev/null && grep -q 'b == 0' "$DIR/calc.py" 2>/dev/null; then
    ok "$CASE: edit applied a multi-line change"
  else
    bad "calc.py was not edited; contents:
$(sed 's/^/       /' "$DIR/calc.py" 2>/dev/null)"
  fi
fi

# --- 3. search: grep must descend, which it did not for the first four months.
if ! skip search; then
  case_start search
  mkdir -p "$DIR/src/deep/nested"
  echo 'const MarkerSymbol = 1;' > "$DIR/src/deep/nested/target.zig"
  echo 'unrelated' > "$DIR/top.txt"
  ask "$DIR" 'Find which file defines MarkerSymbol and reply with just its path.'
  if grep -q 'src/deep/nested/target.zig' "$DIR/.omfx-out"; then
    ok "$CASE: grep found a symbol nested three directories down"
  else
    bad "did not locate the nested file"
  fi
fi

# --- 4. the whole job: edit, add a test, run it, and have it pass.
if ! skip task; then
  case_start task
  printf 'def add(a, b):\n    return a + b\n\ndef div(a, b):\n    return a / b\n' > "$DIR/calc.py"
  printf 'from calc import add\n\ndef test_add():\n    assert add(2, 3) == 5\n' > "$DIR/test_calc.py"
  echo '__pycache__/' > "$DIR/.gitignore"
  ask "$DIR" 'div crashes on a zero divisor. Make it return None instead, add a test for that case to test_calc.py, then run pytest and confirm both tests pass.'
  if ( cd "$DIR" && python3 -m pytest -q >/dev/null 2>&1 ); then
    n=$( cd "$DIR" && python3 -m pytest -q 2>/dev/null | tail -1 )
    if grep -q 'return None' "$DIR/calc.py" && grep -qE 'div' "$DIR/test_calc.py"; then
      ok "$CASE: task complete, pytest green ($n)"
    else
      bad "pytest passes but the change is missing (no fix, or no new test)"
    fi
  else
    bad "pytest does not pass after the run
$( cd "$DIR" && python3 -m pytest -q 2>&1 | tail -5 | sed 's/^/       /' )"
  fi
fi

# --- 5. interrupt: Esc must stop a running turn. This was dead code for months
# (recv(MSG_PEEK) returns ENOTSOCK on a tty) and nothing caught it, because a
# keypress mid-turn needs a terminal.
if ! skip interrupt; then
  case_start interrupt
  HERE="$(cd "$(dirname "$0")" && pwd)"
  if ! command -v python3 >/dev/null; then
    printf '  SKIP  %s: needs python3 for a pty\n' "$CASE"
  else
    python3 "$HERE/e2e-interrupt.py" "$BIN" "$DIR" >"$DIR/.omfx-out" 2>&1
    line="$(grep -o 'reached=[0-9]* after_esc=[0-9]*' "$DIR/.omfx-out" | tail -1)"
    reached="${line#reached=}"; reached="${reached%% *}"
    after="${line##*after_esc=}"
    # Started counting, stopped well short of 400, and barely advanced after Esc.
    if [ -n "$line" ] && [ "${reached:-0}" -gt 3 ] && [ "${after:-99999}" -lt 1900 ] \
       && [ $(( ${after:-99999} - ${reached:-0} )) -lt 60 ]; then
      ok "$CASE: Esc stopped the turn at $reached (reached $after after)"
    else
      bad "Esc did not stop the turn ($line)"
    fi
  fi
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
