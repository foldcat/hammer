#!/bin/sh
# M00.04 clipboard spike demo. Requires a running X server; run under
# xvfb-run so the spike processes share one display:
#
#     xvfb-run -a spike/clipboard/demo.sh build/clipboard_spike
#
# Exercises:
#   - CLIPBOARD and PRIMARY round-trips with a small non-ASCII UTF-8 payload
#   - large (~1.4 MiB) transfers on both selections, asserting the INCR path
#   - TARGETS listing (UTF8_STRING and the GTK utf8 atom)
#   - persistence-after-exit: with the owner gone and no clipboard manager
#     present on the X server, the selection must be empty and get must fail
set -eu

BIN=${1:-build/clipboard_spike}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FIX="$HERE/fixtures/unicode.txt"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

wait_ready() { # wait_ready <log>  — bounded wait for the owner's "ready" line
    log=$1
    n=0
    while [ "$n" -lt 200 ]; do
        if grep -q '^ready ' "$log" 2>/dev/null; then
            return 0
        fi
        n=$((n + 1))
        sleep 0.05
    done
    cat "$log" >&2 || true
    fail "owner never became ready"
}

stop_owner() { # stop_owner <pid>
    pid=$1
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

roundtrip() { # roundtrip <selection> <file> [want_incr]
    sel=$1
    file=$2
    want_incr=${3:-0}
    log="$TMP/serve-$sel.log"
    geterr="$TMP/get-$sel.err"

    "$BIN" serve "$sel" "$file" >"$log" 2>"$TMP/serve-$sel.err" &
    pid=$!
    wait_ready "$log" || { stop_owner "$pid"; exit 1; }

    "$BIN" get "$sel" >"$TMP/out-$sel" 2>"$geterr" || {
        cat "$geterr" >&2
        stop_owner "$pid"
        fail "get $sel failed"
    }
    stop_owner "$pid"

    if ! cmp -s "$file" "$TMP/out-$sel"; then
        fail "round-trip mismatch for $sel"
    fi
    if [ "$want_incr" -eq 1 ] && ! grep -q 'via INCR' "$geterr"; then
        fail "expected the INCR path for $sel but it was not used"
    fi
    echo "OK: $sel round-trip of $(wc -c < "$file") bytes"
}

[ -x "$BIN" ] || fail "no spike binary at $BIN (build it first)"
[ -r "$FIX" ] || fail "missing fixture $FIX"

# Large payload: the fixture doubled past 1 MiB. Each repeat is a whole
# valid UTF-8 file, so the result stays valid UTF-8. 13 doublings of a
# ~160-byte fixture yields ~1.4 MiB.
large="$TMP/large.txt"
: >"$large"
cat "$FIX" >>"$large"
i=0
while [ "$i" -lt 13 ]; do
    cat "$large" "$large" >"$TMP/d"
    mv "$TMP/d" "$large"
    i=$((i + 1))
done

roundtrip CLIPBOARD "$FIX"
roundtrip PRIMARY "$FIX"
roundtrip CLIPBOARD "$large" 1
roundtrip PRIMARY "$large" 1

# TARGETS listing: the owner advertises UTF8_STRING and the GTK atom.
"$BIN" serve CLIPBOARD "$FIX" >"$TMP/serve-targets.log" 2>/dev/null &
pid=$!
wait_ready "$TMP/serve-targets.log" || { stop_owner "$pid"; exit 1; }
"$BIN" get CLIPBOARD --targets >"$TMP/targets" 2>"$TMP/get-targets.err" || {
    cat "$TMP/targets" "$TMP/get-targets.err" >&2
    stop_owner "$pid"
    fail "targets listing failed"
}
stop_owner "$pid"
grep -q 'UTF8_STRING' "$TMP/targets" || fail "UTF8_STRING missing from TARGETS"
grep -q 'text/plain;charset=utf-8' "$TMP/targets" || fail "GTK utf8 atom missing from TARGETS"
echo "OK: TARGETS listing (UTF8_STRING, text/plain;charset=utf-8)"

# Persistence: with the owner gone and no clipboard manager present, the
# selection must be empty and get must fail.
if "$BIN" get CLIPBOARD >/dev/null 2>&1; then
    fail "expected get to fail after the owner exited"
fi
echo "OK: after owner exit, selection is gone (no clipboard manager on this X server)"

echo "ALL OK"
