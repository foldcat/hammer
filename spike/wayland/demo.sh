#!/bin/sh
# M00.06 Wayland spike demo. Headless end-to-end: no physical display is
# needed anywhere in this script.
#
# Exercises:
#   1. negative path: wayland platform requested but no compositor
#   2. native Wayland window + EGL context under weston's x11 backend
#      nested in Xvfb (window create, wl_display/wl_surface handles, GL
#      clear/swap, frame loop, autoquit), plus the probe mode (platform
#      support, default platform selection)
#   3. X11 contrast: the same binary on GLFW's X11 platform under Xvfb
#   4. the XWayland product path: the pinned-sokol hammer window (X11
#      client) running against weston's Xwayland server
#
# Why nested x11-backend and not weston's headless backend for test 2:
# the headless backend creates no input devices, so it advertises no
# wl_seat global, and the pinned GLFW 3.4 crashes dereferencing the
# missing seat (see docs/m00-06-wayland.md). The x11 backend provides a
# full compositor (seat, GL renderer) while the whole setup still runs
# displayless under Xvfb.
#
# All spawned processes (weston, Xvfb) are owned by this script and are
# killed on exit; every wait is bounded.
set -eu

SPIKE=${1:-build/wayland_spike}
HAMMER=${2:-build/hammer}
WESTON_BIN=${WESTON:-weston}
TIMEOUT=30

TMP=$(mktemp -d)
WESTON_PID=
XVFB_PID=
cleanup() {
    [ -z "$WESTON_PID" ] || kill "$WESTON_PID" 2>/dev/null || true
    [ -z "$XVFB_PID" ] || kill "$XVFB_PID" 2>/dev/null || true
    [ -z "$WESTON_PID" ] || wait "$WESTON_PID" 2>/dev/null || true
    [ -z "$XVFB_PID" ] || wait "$XVFB_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

wait_for_file() { # wait_for_file <path> <tries>
    path=$1
    tries=$2
    n=0
    while [ "$n" -lt "$tries" ]; do
        if [ -e "$path" ]; then
            return 0
        fi
        n=$((n + 1))
        sleep 0.1
    done
    fail "timed out waiting for '$path'"
}

wait_for_log() { # wait_for_log <log> <pattern> <tries>
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

grep_log() { # grep_log <log> <pattern>
    log=$1
    pattern=$2
    if ! grep -q "$pattern" "$log"; then
        cat "$log" >&2 || true
        fail "missing '$pattern'"
    fi
}

# start_weston: launch weston on the given backend, wait for the
# compositor socket, record WESTON_PID (runs in the main shell).
start_weston() {
    backend=$1
    socket=$2
    extra=$3
    log=$4
    mkdir -p "$XDG_RUNTIME_DIR"
    : >"$log"
    # The x11 backend needs DISPLAY to nest inside Xvfb; harmless for the
    # headless backend.
    DISPLAY=:97 "$WESTON_BIN" --backend="$backend" --socket="$socket" \
        --width=1024 --height=768 --idle-time=0 --no-config \
        --log="$log" $extra >/dev/null 2>&1 &
    WESTON_PID=$!
    wait_for_file "$XDG_RUNTIME_DIR/$socket" 200
}

stop_weston() {
    kill "$WESTON_PID" 2>/dev/null || true
    wait "$WESTON_PID" 2>/dev/null || true
    WESTON_PID=
}

[ -x "$SPIKE" ] || fail "no spike binary at $SPIKE (run: odin run make.odin -file -- wayland-spike)"
[ -x "$HAMMER" ] || fail "no hammer binary at $HAMMER (run: odin run make.odin -file)"

XDG_RUNTIME_DIR="$TMP/runtime"
export XDG_RUNTIME_DIR
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

Xvfb :97 -screen 0 1024x768x24 >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
wait_for_file /tmp/.X11-unix/X97 200

# 1. Negative path: wayland requested, no compositor in the environment.
env -u WAYLAND_DISPLAY -u DISPLAY HAMMER_GLFW_PLATFORM=wayland \
    "$SPIKE" >"$TMP/negative.log" 2>&1 && fail "expected nonzero exit without a compositor"
grep_log "$TMP/negative.log" '>> init failed'
echo "OK: negative path (wayland requested, no compositor -> init failed)"

# 2. Native Wayland under weston's x11 backend nested in Xvfb. The
#    platform hint is left unset: GLFW must pick Wayland itself from
#    WAYLAND_DISPLAY (DISPLAY is unset).
start_weston x11-backend.so wayland-spike "" "$TMP/weston-wayland.log"
env -u DISPLAY WAYLAND_DISPLAY=wayland-spike HAMMER_AUTOQUIT_FRAMES=5 \
    timeout "$TIMEOUT" "$SPIKE" >"$TMP/wayland.log" 2>&1 || { cat "$TMP/wayland.log" >&2; fail "wayland run failed"; }
grep_log "$TMP/wayland.log" '>> platform: wayland'
grep_log "$TMP/wayland.log" '>> wl_display: ok'
grep_log "$TMP/wayland.log" '>> wl_surface: ok'
grep_log "$TMP/wayland.log" '>> framebuffer: 640x480'
grep_log "$TMP/wayland.log" '>> gl version:'
grep_log "$TMP/wayland.log" '>> frame 1'
grep_log "$TMP/wayland.log" '>> frames rendered: 5'
grep_log "$TMP/wayland.log" '>> autoquit'
grep_log "$TMP/wayland.log" '>> exit clean'
env -u DISPLAY WAYLAND_DISPLAY=wayland-spike \
    "$SPIKE" probe >"$TMP/probe.log" 2>&1 || { cat "$TMP/probe.log" >&2; fail "probe failed"; }
grep_log "$TMP/probe.log" '>> build supports wayland: yes'
grep_log "$TMP/probe.log" '>> build supports x11: yes'
grep_log "$TMP/probe.log" '>> default platform: wayland'
stop_weston
cat "$TMP/wayland.log"
echo "OK: native Wayland window + EGL under nested weston (autoquit after 5 frames)"

# 3. X11 contrast on the same Xvfb: same binary, GLFW X11 platform, GLX.
env -u WAYLAND_DISPLAY DISPLAY=:97 HAMMER_GLFW_PLATFORM=x11 HAMMER_AUTOQUIT_FRAMES=5 \
    timeout "$TIMEOUT" "$SPIKE" >"$TMP/x11.log" 2>&1 || { cat "$TMP/x11.log" >&2; fail "x11 contrast run failed"; }
grep_log "$TMP/x11.log" '>> platform: x11'
grep_log "$TMP/x11.log" '>> wl_surface: n/a (not wayland)'
grep_log "$TMP/x11.log" '>> gl version:'
grep_log "$TMP/x11.log" '>> frames rendered: 5'
grep_log "$TMP/x11.log" '>> exit clean'
cat "$TMP/x11.log"
echo "OK: X11 contrast under Xvfb (same binary, GLFW X11 platform, GLX)"

# 4. XWayland product path: the pinned-sokol X11 hammer window runs
#    against weston's Xwayland server — i.e. how the current product
#    would appear inside a Wayland session. Westons headless backend is
#    fine here: hammer is an X11 client and never speaks the Wayland
#    protocol itself.
start_weston headless-backend.so wayland-spike-x "--xwayland" "$TMP/weston-xwayland.log"
wait_for_log "$TMP/weston-xwayland.log" 'display :[0-9]' 200
XW_DISPLAY=$(grep -o 'display :[0-9][0-9]*' "$TMP/weston-xwayland.log" | head -1 | sed 's/.*://')
[ -n "$XW_DISPLAY" ] || fail "cannot discover Xwayland display (check $TMP/weston-xwayland.log)"
env -u WAYLAND_DISPLAY DISPLAY=":$XW_DISPLAY" HAMMER_AUTOQUIT_FRAMES=5 \
    timeout "$TIMEOUT" "$HAMMER" >"$TMP/xwayland.log" 2>&1 || { cat "$TMP/xwayland.log" >&2; fail "hammer under Xwayland failed"; }
grep_log "$TMP/xwayland.log" '>> using GL backend'
grep_log "$TMP/xwayland.log" '>> window initialized: 800x600'
grep_log "$TMP/xwayland.log" '>> clean exit after 5 frames'
stop_weston
cat "$TMP/xwayland.log"
echo "OK: pinned-sokol hammer under weston Xwayland (X11 client in a Wayland session)"

echo "ALL OK"
