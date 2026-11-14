# M00.08 — Minimal FUSE deployment proof (Linux)

**Status:** done (Linux, raw syscalls via `core:sys/linux`, no libfuse, no
new dependencies). WinFsp/Windows deferred: no Windows toolchain on this
machine (M00.06 decision), so nothing is claimed for WinFsp.

## What was built

`spike/fuse/` contains a minimal raw-protocol FUSE filesystem daemon:

- `main.odin` — the daemon (`build/fuse_spike`). Speaks the FUSE 7.x
  kernel wire protocol directly over `/dev/fuse` (wire structs asserted
  against the kernel uapi sizes; no libfuse). Two modes:
  - `mount <dir>` — mount and serve until SIGTERM or FUSE_DESTROY, then
    unmount cleanly; prints `MNT_OK` on readiness.
  - `genref <dir>` — write the served files to disk for the harness to
    diff against.
- `demo.sh` — headless harness: mounts in a task-owned `mktemp -d`
  sandbox under `/tmp/opencode/` only (never a real mount point), drives
  real client tooling (`ls`, `cat`, `stat`, `find`, `df`, `head`/`tail`),
  verifies byte-exact content with hard-coded sha256 checksums, the
  clean SIGTERM shutdown path, the crash (kill -9) + kernel abort +
  `fusermount3 -uz` recovery path, and asserts no leftover mounts.
  `make.odin` gained a `fuse-spike` target.

The served tree is minimal and read-only: a root directory plus
`hello.txt` (31 bytes of multibyte UTF-8) and `big.txt` (280,000 bytes,
spanning three 128 KiB READ requests). Read-only is deliberate: the
kernel enforces EROFS via the `ro` mount option, and the device-like
write path (WRITE/SETATTR/CREATE…) is M19 work. Spike code, not product
implementation (M19.04 owns the mounted adapter).

## Finding 1 — the unprivileged deployment path is fusermount3's new-style protocol

Direct `mount(2)` from an unprivileged process fails **EPERM** (verified;
the daemon tries it first and records which path was used). The fallback
that works is the setuid helper, but **this fusermount3 (libfuse 3.18.3)
rejects the old-style fd-inheritance protocol** (`fd=N` in the mount
options + an inherited non-CLOEXEC fd → `fusermount3: old style mounting
not supported`). The modern protocol, mirroring libfuse 3.x
`fuse_mount_sys`/`fuse_mount_fusermount`, is:

1. `socketpair(AF_UNIX, SOCK_STREAM)` — the comm socket.
2. `fork`; the child execs `/usr/bin/fusermount3` with
   `-o <opts> -- <mountpoint>` and `_FUSE_COMMFD=<child's socket fd>` in
   its environment (the fd is inherited across execve; no CLOEXEC).
3. The helper opens `/dev/fuse` **itself** (as the caller's real uid via
   `setfsuid`), does its mountpoint permission checks, and `mount(2)`s
   with `fd=/rootmode=/user_id=/group_id=` regenerated from its own fd
   and the caller's ids.
4. The helper sends the FUSE connection fd back over the comm socket as
   one byte + `SCM_RIGHTS` control message (`sendmsg`), then exits.
5. The parent `recvmsg()`s the fd (helper exit without a message = mount
   failed, observed as a 0-byte read/EOF), then reaps the helper.

All of this was verified end to end with raw `core:sys/linux` calls
(`socketpair`/`fork`/`execve` with envp/`recvmsg`/`waitpid`): mount
succeeded via the helper, the received fd served FUSE_INIT immediately,
and the kernel round-tripped real requests. The helper-side option
whitelist also matters: unknown options make fusermount3 `exit(1)`;
`default_permissions`, `max_read=`, `ro`, `fsname=`, `subtype=` are all
accepted (verified in this spike's option set).

Deployment prerequisites confirmed on this machine and documented for
M20.07: `/dev/fuse` present and user-accessible (mode 666), `fuse` in
`/proc/filesystems`, setuid-root `/usr/bin/fusermount3`. No components
were installed for this spike.

## Finding 2 — the /dev/fuse read buffer must fit 4096 + max_write

The kernel requires every read on `/dev/fuse` to be able to hold the
largest possible request:
`max(FUSE_MIN_READ_BUFFER=8192, 4096 + max_write)`. With `max_write`
advertised as 131072 in the INIT reply, a 128 KiB read buffer made the
second read fail with **EINVAL** (the INIT request itself fit, so the
failure landed one request later — easy to misdiagnose). Buffer sizes
must track the advertised `max_write`; the spike uses 256 KiB. This is a
hard invariant for any adapter loop, not a recommendation.

## Finding 3 — the protocol surface a minimal read-only fs must answer

Verified empirically on kernel 6.18.50 (FUSE 7.45 offered; the daemon
negotiates down to 7.31 with flags=0):

- `FUSE_INIT` (26) is the first request, always. Replying minor 31 with
  flags=0 keeps the kernel off READDIRPLUS/parallel-dirops/async-read;
  the 64-byte 7.31 `init_out` layout governs.
- With `default_permissions`, the kernel checks modes against the
  returned attrs and sends **no FUSE_ACCESS** (handled anyway,
  defensively).
- The observed opcode set over a full `ls`/`cat`/`stat`/`df`/`find`
  session: INIT, LOOKUP (1), GETATTR (3), OPEN (14), READ (15), STATFS
  (17), RELEASE (18), FLUSH (25), OPENDIR (27), READDIR (28), RELEASEDIR
  (29), and **FUSE_SYNCFS (52)** on kernel 6.x — SYNCFS is answered
  ENOSYS, which the kernel accepts.
- `READDIR` comes with offsets; each dirent's `off` is its own index and
  entries with `off > offset` are emitted. READDIRPLUS is implemented but
  correctly never requested (not negotiated).
- `FORGET`/`BATCH_FORGET` take no reply; `INTERRUPT` gets ENOSYS;
  unknown opcodes get ENOSYS; `DESTROY` is answered and ends the loop.
- `statx`-based `stat` maps to FUSE_GETATTR; `tail -c` (seek-to-end via
  getattr size) and multi-chunk reads work byte-exactly (sha256-verified
  over the whole 280,000-byte file and the multibyte file).

## Finding 4 — lifecycle: SIGTERM clean unmount, kill -9 abort, lazy recovery

- **Clean shutdown**: a SIGTERM handler sets a flag; the blocking
  `read()` returns EINTR; the loop breaks, the daemon unmounts
  (`fusermount3 -u`, matching the helper-mount path), and exits 0. The
  mount disappears from mountinfo and the mountpoint dir is empty again.
  Verified by the harness.
- **Crash**: `kill -9` leaves the mount listed in mountinfo but dead —
  reads fail (kernel aborts the connection when the daemon fd closes) —
  and `fusermount3 -uz` (MNT_DETACH) clears it. Verified. M19.07 must
  replicate this recovery path for safe shutdown.
- The harness also refuses to start if a stale `fuse.hammer` mount
  exists, and asserts none remain at the end.

## Not validated

- Writes (read-only mount by design), CREATE/SETATTR/renames, xattrs,
  symlinks, locking — all M19 device-semantics territory; the kernel's
  EROFS enforcement of `ro` was verified instead.
- `allow_other` (requires `user_allow_other` in `/etc/fuse.conf`; not
  needed for a single-user editor mount).
- `auto_unmount` (the helper's daemonized unmount-on-parent-death mode;
  M19.07 should evaluate it against the manual recovery path proven
  here).
- WinFsp and anything Windows.

## Implications for later milestones

- M19.04 (Unix mounted adapter): the deployment path is proven — the
  setuid-helper protocol (Finding 1) is the one an unprivileged editor
  will use, and the entire kernel protocol surface needed for a minimal
  fs is enumerated (Finding 3), all via the pinned `core:sys/linux` with
  no new dependencies. The buffer-size invariant (Finding 2) and the
  crash recovery path (Finding 4) are hard requirements to carry into
  the adapter design.
- M20.07 (packaging): runtime prerequisites are exactly `/dev/fuse` +
  kernel fuse module + setuid `fusermount3` (or an equivalent helper);
  WinFsp is a separate deployment dependency on Windows (SPECS.md
  §16.7).

## Validation

- `odin run make.odin -file -- fuse-spike` — `-vet` clean, core only.
- `./spike/fuse/demo.sh` — ALL OK: mount via helper path (direct
  mount(2) EPERM recorded), `ls`/sha256/`stat`/`head`/`tail`/`find`/`df`
  assertions, ENOENT + kernel-enforced EROFS, SIGTERM clean shutdown,
  kill -9 crash + kernel abort + `fusermount3 -uz` recovery, usage
  paths, no leftover mounts.
- Kernel 6.18.50, FUSE protocol 7.45 offered / 7.31 negotiated.
