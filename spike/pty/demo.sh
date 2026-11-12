#!/bin/sh
# M00.07 PTY spike demo. No display needed; exercises the raw-Linux PTY
# path end to end:
#
#   - echo: bidirectional flow through the pty (input echo disabled via
#     termios, ONLCR translation asserted)
#   - escape: an ANSI sequence emitted in 4 delayed writes must arrive
#     split across reads and reassemble exactly
#   - flood: 1 MiB of output drained through a non-blocking poll loop
#   - kill: SIGTERM to the process group of a SIGTERM-blocked child, then
#     SIGKILL escalation and reaping
#   - size: TIOCSWINSZ/TIOCGWINSZ window-size round-trip through the pty
#   - exitcode: exit-status reaping and EIO-on-master semantics
#   - raw: cfmakeraw-equivalent termios state (no \n -> \r\n translation)
#
# Afterwards the harness asserts that no orphaned pty_child processes
# remain (the spike arms PR_SET_PDEATHSIG and reaps everything itself).
set -eu

SPIKE=${1:-build/pty_spike}
CHILD=${2:-build/pty_child}
TIMEOUT=30

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep_log() { # grep_log <log> <pattern>
    log=$1
    pattern=$2
    if ! grep -q "$pattern" "$log"; then
        cat "$log" >&2 || true
        fail "missing '$pattern'"
    fi
}

run_mode() { # run_mode <mode> <log>
    mode=$1
    log=$2
    if ! timeout "$TIMEOUT" "$SPIKE" "$mode" "$CHILD" >"$log" 2>&1; then
        cat "$log" >&2 || true
        fail "$mode mode failed"
    fi
}

[ -x "$SPIKE" ] || fail "no spike binary at $SPIKE (run: odin run make.odin -file -- pty-spike)"
[ -x "$CHILD" ] || fail "no child binary at $CHILD (run: odin run make.odin -file -- pty-spike)"

run_mode echo "$TMP/echo.log"
grep_log "$TMP/echo.log" '>> echo: round-trip ok'
grep_log "$TMP/echo.log" '7 bytes out with ONLCR'
echo "OK: echo round-trip (input echo off, ONLCR translation visible)"

run_mode escape "$TMP/escape.log"
grep_log "$TMP/escape.log" '>> escape: reassembled ok (reads=4,5,3,4,2, first-chunk-bytes=5)'
grep_log "$TMP/escape.log" '>> escape: ANSI split across reads'
echo "OK: escape sequence split across reads and reassembled exactly"

run_mode flood "$TMP/flood.log"
grep_log "$TMP/flood.log" '>> flood: 1048576 bytes drained'
echo "OK: flood (1 MiB drained through the poll loop)"

run_mode kill "$TMP/kill.log"
grep_log "$TMP/kill.log" '>> kill: SIGTERM ignored'
grep_log "$TMP/kill.log" '>> kill: child confirmed alive after SIGTERM'
grep_log "$TMP/kill.log" '>> kill: SIGKILL delivered via process group, child reaped (WTERMSIG=9)'
echo "OK: kill (process-group SIGTERM ignored by blocked child, SIGKILL escalation)"

run_mode size "$TMP/size.log"
grep_log "$TMP/size.log" '>> size: child saw cols=120 rows=34; master readback matches'
echo "OK: size (TIOCSWINSZ/TIOCGWINSZ round-trip)"

run_mode exitcode "$TMP/exitcode.log"
grep_log "$TMP/exitcode.log" '>> exitcode: child exited 7'
grep_log "$TMP/exitcode.log" '>> exitcode: EIO on master after child exit confirmed'
echo "OK: exitcode (status reaping and EIO end-of-output semantics)"

run_mode raw "$TMP/raw.log"
grep_log "$TMP/raw.log" '>> raw: raw termios verified'
echo "OK: raw (raw termios: no output post-processing)"

# Usage paths: no mode and unknown mode must fail cleanly.
if "$SPIKE" >"$TMP/usage.log" 2>&1; then
    fail "expected nonzero exit without a mode"
fi
grep_log "$TMP/usage.log" 'usage:'
if "$SPIKE" bogus "$CHILD" >"$TMP/bogus.log" 2>&1; then
    fail "expected nonzero exit for unknown mode"
fi
echo "OK: usage paths fail cleanly"

# No orphaned children: every spawn was reaped, and PR_SET_PDEATHSIG
# would have taken stragglers down with the spike.
if pgrep -x pty_child >/dev/null 2>&1; then
    fail "orphaned pty_child processes remain"
fi
echo "OK: no orphaned pty_child processes"

echo "ALL OK"
