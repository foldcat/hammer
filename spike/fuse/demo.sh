#!/bin/sh
# M00.08 FUSE deployment spike demo. Mounts the minimal read-only FUSE
# filesystem in a task-owned sandbox and proves the deployment path end to
# end with real tooling:
#
#   - mount + readiness: the daemon must report MNT_OK and the mount must
#     appear in /proc/self/mountinfo as fuse.hammer
#   - real client tools: ls, cat, stat, find, df, head/tail (offset
#     reads), byte-exact multibyte content, ENOENT, kernel-enforced EROFS
#   - clean lifecycle: SIGTERM -> daemon unmounts -> mount gone, dir empty
#   - crash recovery: kill -9 -> kernel aborts the connection (reads
#     fail) -> fusermount3 -uz clears the stale mount
#
# Isolation: everything lives in a mktemp sandbox under /tmp/opencode.
# No real mount points are touched, and the trap unmounts/removes the
# sandbox on any exit path.
set -eu

SPIKE=${1:-build/fuse_spike}
TIMEOUT=30

# Sandbox path guard: the mount point must always live inside the
# task-owned sandbox; cleanup refuses to act outside it.
TMP=$(mktemp -d /tmp/opencode/m00-08-fuse.XXXXXX)
MNT=$TMP/mnt
REF=$TMP/ref
mkdir -p "$MNT" "$REF"

DAEMON_PID=

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

cleanup() {
    # Safety net: stop the daemon and release the sandbox mount. Only
    # ever acts on the task-owned mount point below.
    if [ -n "${DAEMON_PID:-}" ]; then
        kill "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    fusermount3 -uz "$MNT" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

wait_mnt_ready() { # wait_mnt_ready <log>
    log=$1
    i=0
    while [ "$i" -lt 50 ]; do
        if grep -q "^MNT_OK$" "$log" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    cat "$log" >&2 || true
    fail "daemon did not report MNT_OK"
}

mounted_in_mountinfo() {
    grep -F " $MNT " /proc/self/mountinfo | grep -q "fuse.hammer"
}

[ -x "$SPIKE" ] || fail "no spike binary at $SPIKE (run: odin run make.odin -file -- fuse-spike)"
command -v fusermount3 >/dev/null 2>&1 || fail "fusermount3 not found"
[ -e /dev/fuse ] || fail "/dev/fuse missing"
if grep -q "fuse.hammer" /proc/self/mountinfo; then
    fail "pre-existing fuse.hammer mount found; clean up with fusermount3 -uz first"
fi

# Reference fixtures on disk (same constants the spike serves); the
# content itself is verified against the hard-coded checksums below.
"$SPIKE" genref "$REF" || fail "genref failed"

# --- clean lifecycle ----------------------------------------------------

LOG=$TMP/daemon.log
"$SPIKE" mount "$MNT" >"$LOG" 2>&1 &
DAEMON_PID=$!
wait_mnt_ready "$LOG"
grep_log "$LOG" '>> mount:'
mounted_in_mountinfo || fail "mount not visible in mountinfo after MNT_OK"

# readdir + getattr through ls
ls -la "$MNT" >"$TMP/ls.out" 2>&1 || fail "ls failed"
grep -q "hello.txt" "$TMP/ls.out" || fail "hello.txt not listed"
grep -q "big.txt" "$TMP/ls.out" || fail "big.txt not listed"
echo "OK: ls lists both files"

# byte-exact content: multibyte UTF-8 file and the 273 KiB file spanning
# multiple 128 KiB max_read chunks
echo "ccd9a31bf6330ceaf5ff55d7a47c6b125c2f27ba2a1dfd3ec2edfa9d51f35791  $MNT/hello.txt" | sha256sum -c - >/dev/null || fail "hello.txt checksum mismatch"
echo "12a92a84ae2a26c8961db8e5e51b56b9a3c4e421620aeac95c64d9df3650af85  $MNT/big.txt" | sha256sum -c - >/dev/null || fail "big.txt checksum mismatch"
echo "OK: sha256 byte-exact (hello.txt multibyte, big.txt multi-chunk)"

# metadata through stat
[ "$(stat -c '%a|%F' "$MNT/hello.txt")" = "644|regular file" ] || fail "hello.txt stat mismatch: $(stat -c '%a|%F' "$MNT/hello.txt")"
[ "$(stat -c '%a|%s' "$MNT/big.txt")" = "644|280000" ] || fail "big.txt stat mismatch: $(stat -c '%a|%s' "$MNT/big.txt")"
[ "$(stat -c '%a|%F' "$MNT")" = "755|directory" ] || fail "root dir stat mismatch: $(stat -c '%a|%F' "$MNT")"
echo "OK: stat metadata (modes, sizes, types)"

# offset reads: head at offset 0, tail via seek-to-end (GETATTR size)
head -c 35 "$MNT/big.txt" >"$TMP/got-head"
head -c 35 "$REF/big.txt" >"$TMP/ref-head"
cmp -s "$TMP/got-head" "$TMP/ref-head" || fail "head -c 35 mismatch"
tail -c 100 "$MNT/big.txt" >"$TMP/got-tail"
tail -c 100 "$REF/big.txt" >"$TMP/ref-tail"
cmp -s "$TMP/got-tail" "$TMP/ref-tail" || fail "tail -c 100 mismatch"
echo "OK: offset reads (head/tail)"

# traversal + statfs
[ "$(find "$MNT" -maxdepth 1 -type f | wc -l | tr -d ' ')" = "2" ] || fail "find saw wrong file count"
df "$MNT" >/dev/null 2>&1 || fail "df (STATFS) failed"
echo "OK: find traversal and df (STATFS)"

# error paths
if cat "$MNT/nope.txt" >/dev/null 2>&1; then
    fail "read of missing file unexpectedly succeeded"
fi
if (echo hi >"$MNT/hello.txt") 2>/dev/null; then
    fail "write to read-only mount unexpectedly succeeded"
fi
echo "OK: ENOENT and kernel-enforced EROFS error paths"

grep_log "$LOG" '>> init: negotiated'

# --- clean shutdown -----------------------------------------------------

kill -TERM "$DAEMON_PID"
if ! wait "$DAEMON_PID"; then
    cat "$LOG" >&2 || true
    fail "daemon exited nonzero on SIGTERM"
fi
DAEMON_PID=
grep_log "$LOG" '>> serve: stopped cleanly'
grep_log "$LOG" '>> unmount: clean'
# request coverage in the daemon stats (lookup, getattr, open, read, readdir)
grep_log "$LOG" ' 1='
grep_log "$LOG" ' 3='
grep_log "$LOG" ' 14='
grep_log "$LOG" ' 15='
grep_log "$LOG" ' 28='
if mounted_in_mountinfo; then
    fail "mount still present after clean SIGTERM shutdown"
fi
[ -z "$(ls -A "$MNT")" ] || fail "mountpoint dir not empty after unmount"
echo "OK: SIGTERM clean shutdown (daemon unmounted, dir empty)"

# --- crash recovery -----------------------------------------------------

"$SPIKE" mount "$MNT" >"$TMP/crash.log" 2>&1 &
DAEMON_PID=$!
wait_mnt_ready "$TMP/crash.log"
kill -9 "$DAEMON_PID"
wait "$DAEMON_PID" 2>/dev/null || true # expected: killed
DAEMON_PID=
# The kernel aborts the FUSE connection when the daemon dies: reads fail
# and the mount stays behind as a stale entry until lazily unmounted.
if cat "$MNT/hello.txt" >/dev/null 2>&1; then
    fail "read succeeded after daemon kill -9 (expected kernel abort)"
fi
mounted_in_mountinfo || fail "stale mount expected in mountinfo after crash"
fusermount3 -uz "$MNT"
if mounted_in_mountinfo; then
    fail "fusermount3 -uz did not clear the crashed mount"
fi
echo "OK: crash recovery (kernel abort + fusermount3 -uz lazy unmount)"

# --- usage paths --------------------------------------------------------

if "$SPIKE" >"$TMP/usage.log" 2>&1; then
    fail "expected nonzero exit without a mode"
fi
grep_log "$TMP/usage.log" 'usage:'
if "$SPIKE" bogus "$MNT" >"$TMP/bogus.log" 2>&1; then
    fail "expected nonzero exit for unknown mode"
fi
echo "OK: usage paths fail cleanly"

if grep -q "fuse.hammer" /proc/self/mountinfo; then
    fail "leftover fuse.hammer mounts remain"
fi

echo "ALL OK"
