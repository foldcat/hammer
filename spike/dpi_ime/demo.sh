#!/bin/sh
# M00.05 DPI/IME spike demo. Requires a running X server; run under
# xvfb-run so all processes share one display:
#
#     xvfb-run -a spike/dpi_ime/demo.sh build/dpi_ime build/dpi_ime_app
#
# Exercises:
#   - the native probe (Xft.dpi, mm-based DPI, RandR monitors, XTEST)
#   - the sapp probe app at default DPI and at Xft.dpi=192 (set via the
#     spike's own set-dpi mode, i.e. without external tools)
#   - the coordinate-model finding: mouse events arrive in physical
#     pixels while sapp.width()/height() stay in desc (logical) units
#   - sapp's CHAR events for ASCII text (fed via XTEST)
#   - the XIM bridge prototype: dead-key composition and preedit
#     callbacks under Xvfb
set -eu

BIN=${1:-build/dpi_ime}
APP=${2:-build/dpi_ime_app}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

wait_for() { # wait_for <log> <pattern> <tries>
    log=$1
    pattern=$2
    tries=$3
    n=0
    while [ "$n" -lt "$tries" ]; do
        if grep -q "$pattern" "$log" 2>/dev/null; then
            return 0
        fi
        n=$((n + 1))
        sleep 0.1
    done
    cat "$log" >&2 || true
    fail "timed out waiting for '$pattern'"
}

# start_app: launch the sapp probe app in the background, wait for its
# window id line, and record the pid and window id in the globals
# APP_PID / WIN_ID (runs in the main shell, not a subshell).
start_app() {
    log=$1
    : >"$log"
    "$APP" >"$log" 2>&1 &
    APP_PID=$!
    wait_for "$log" 'window=' 200
    WIN_ID=$(grep 'window=' "$log" | tail -1 | sed 's/.*window=//')
}

stop_app() {
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
}

grep_log() { # grep_log <log> <pattern>
    log=$1
    pattern=$2
    if ! grep -q "$pattern" "$log"; then
        cat "$log" >&2 || true
        fail "missing '$pattern'"
    fi
}

[ -x "$BIN" ] || fail "no probe binary at $BIN (build it first)"
[ -x "$APP" ] || fail "no probe app at $APP (build it first)"

# 1. Native probe.
"$BIN" probe >"$TMP/probe.log" 2>&1 || { cat "$TMP/probe.log" >&2; fail "probe failed"; }
grep_log "$TMP/probe.log" 'XTEST: yes'
cat "$TMP/probe.log"

# 2. Default DPI: physical window == sapp size, dpi_scale 1.0, Xft.dpi unset.
start_app "$TMP/app-default.log"
"$BIN" keys --window "$WIN_ID" >"$TMP/keys.log" 2>&1 || { cat "$TMP/keys.log" >&2; fail "keys feeder failed"; }
stop_app
grep_log "$TMP/app-default.log" 'physical=400x300 sapp=400x300'
grep_log "$TMP/app-default.log" 'dpi_scale=1.00 high_dpi=false'
grep_log "$TMP/app-default.log" 'xft_dpi=unset'
grep_log "$TMP/app-default.log" 'char U+0061'
grep_log "$TMP/app-default.log" 'char U+0041'
echo "OK: default DPI (physical 400x300, sapp 400x300, dpi_scale 1.0, ASCII chars via CHAR events)"

# 3. Xft.dpi=192: sapp folds the display-wide Xft.dpi into dpi_scale
#    (2.0, regardless of the high_dpi flag), pre-scales the physical
#    window, and reports framebuffer-sized sapp.width()/height(). Mouse
#    coordinates arrive in framebuffer pixels, consistent with
#    sapp.width(). The app must divide by dpi_scale to recover logical
#    (desc) units.
#    set-dpi holds its connection open: X servers reset their state when
#    the last client disconnects, so a short-lived writer would lose its
#    own write.
"$BIN" set-dpi 192 >"$TMP/setdpi.log" 2>&1 &
DPI_PID=$!
wait_for "$TMP/setdpi.log" 'ready' 100
start_app "$TMP/app-hidpi.log"
"$BIN" keys --window "$WIN_ID" --motion 300,200 >/dev/null 2>&1
stop_app
grep_log "$TMP/app-hidpi.log" 'physical=800x600 sapp=800x600'
grep_log "$TMP/app-hidpi.log" 'dpi_scale=2.00 high_dpi=false'
grep_log "$TMP/app-hidpi.log" 'xft_dpi=192.000'
# Mouse events in framebuffer pixels at scale 2 (physical window 800x600).
grep_log "$TMP/app-hidpi.log" 'mouse 300 200'
echo "OK: Xft.dpi=192 (physical/sapp 800x600, dpi_scale 2.0, mouse in framebuffer px)"

# 3b. clear-dpi removes the resource while the display state is still
#     alive, and the probe confirms it is gone.
"$BIN" clear-dpi >"$TMP/cleardpi.log" 2>&1 &
CLEAR_PID=$!
wait_for "$TMP/cleardpi.log" 'ready' 100
"$BIN" probe >"$TMP/probe-after-clear.log" 2>&1 || { cat "$TMP/probe-after-clear.log" >&2; fail "probe after clear failed"; }
grep_log "$TMP/probe-after-clear.log" 'Xft.dpi: unset'
kill "$DPI_PID" "$CLEAR_PID" 2>/dev/null || true
wait "$DPI_PID" "$CLEAR_PID" 2>/dev/null || true
echo "OK: clear-dpi removes the resource (probe confirms unset)"

# 4. high_dpi flag is a no-op on X11.
HAMMER_SPIKE_HIGH_DPI=1 "$APP" >"$TMP/app-highdpi-flag.log" 2>&1 &
APP_PID=$!
wait_for "$TMP/app-highdpi-flag.log" 'window=' 200
stop_app
grep_log "$TMP/app-highdpi-flag.log" 'high_dpi=false'
grep_log "$TMP/app-highdpi-flag.log" 'physical=400x300 sapp=400x300'
echo "OK: sapp_desc.high_dpi is a no-op on X11 (scale stays 1.0, window unscaled)"

# 5. Run the XIM bridge prototype: the commit path (dead-key composition)
#    must work. Preedit callbacks depend on the input method server; the
#    built-in XIM on this headless display does not advertise them, which
#    the spike reports (exercised=yes/no) rather than faking.
"$BIN" xim >"$TMP/xim.log" 2>&1 || { cat "$TMP/xim.log" >&2; fail "xim mode failed"; }
grep_log "$TMP/xim.log" 'commit: "é"'
grep_log "$TMP/xim.log" 'commit: "a"'
grep_log "$TMP/xim.log" 'RESULT: OK'
cat "$TMP/xim.log"
echo "OK: XIM bridge prototype (dead-key composition commit path)"

echo "ALL OK"
