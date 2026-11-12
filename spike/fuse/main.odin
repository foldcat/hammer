// M00.08 — Minimal FUSE deployment proof (Linux).
//
// Spike, not the product implementation. Proves the deployment path the
// editor's mounted filesystem adapter (SPECS.md §16.7, M19.04) will use:
// an unprivileged user process serving the FUSE kernel protocol over
// /dev/fuse, mounted either by a direct mount(2) (privileged path) or via
// the setuid fusermount3 helper speaking the libfuse 3.x protocol
// (socketpair + _FUSE_COMMFD; the helper opens /dev/fuse itself and
// returns the connection fd via SCM_RIGHTS — the path a normal desktop
// editor takes). No libfuse: the wire protocol is implemented here from
// the kernel's fuse.h so the spike documents exactly what an adapter must
// speak.
//
// The filesystem is a minimal read-only tree:
//
//   /            (dir, mode 0755)
//   ├── hello.txt 31 bytes of UTF-8 (multibyte content)
//   └── big.txt   280000 bytes (spans multiple 128 KiB READ requests)
//
// Mount options used (mirroring libfuse's fuse_kern_mount handshake):
// fd=N (connection fd, direct path only — the helper regenerates it from
// its own /dev/fuse fd), rootmode=40000 (S_IFDIR), user_id/group_id of
// the real user, default_permissions (kernel checks modes against the
// attrs we return; no FUSE_ACCESS traffic), max_read=131072, ro (kernel
// enforces read-only; device-like writes are M19 work).
//
// Modes:
//   mount <dir>   mount and serve <dir> until SIGTERM or FUSE_DESTROY,
//                 then unmount cleanly; prints MNT_OK on readiness
//   genref <dir>  write hello.txt and big.txt into <dir> so a harness
//                 can diff them against the mounted tree
//
// Protocol notes:
//   - little-endian native structs (host is x86-64); layouts are asserted
//     against the kernel uapi sizes below
//   - FUSE_INIT negotiation: reply minor = min(kernel, 31); flags = 0, so
//     the kernel will not use READDIRPLUS (handled anyway) or parallel
//     dirops
//   - FORGET/BATCH_FORGET take no reply; INTERRUPT is answered ENOSYS
//   - one request per read() on /dev/fuse; the daemon blocks in read()
//     and the SIGTERM handler breaks it out via EINTR
package main

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

// --- FUSE protocol constants (linux/fuse.h) ----------------------------

FUSE_KERNEL_VERSION :: 7
FUSE_MINOR_VERSION :: 31 // protocol minor we negotiate down to

FUSE_ROOT_ID :: 1
HELLO_NODE :: 2
BIG_NODE :: 3

// Opcodes we answer (the full set the kernel can send to a read-only
// filesystem with default_permissions and no negotiated flags).
FUSE_LOOKUP :: 1
FUSE_FORGET :: 2
FUSE_GETATTR :: 3
FUSE_OPEN :: 14
FUSE_READ :: 15
FUSE_STATFS :: 17
FUSE_RELEASE :: 18
FUSE_FLUSH :: 25
FUSE_INIT :: 26
FUSE_OPENDIR :: 27
FUSE_READDIR :: 28
FUSE_RELEASEDIR :: 29
FUSE_ACCESS :: 34
FUSE_INTERRUPT :: 36
FUSE_DESTROY :: 38
FUSE_BATCH_FORGET :: 42
FUSE_READDIRPLUS :: 44

DT_DIR :: 4
DT_REG :: 8

S_IFDIR :: 0o040000
S_IFREG :: 0o100000

// --- wire structs (x86-64 Linux layouts, sizes asserted) ---------------

Fuse_In_Header :: struct {
	len:     u32,
	opcode:  u32,
	unique:  u64,
	nodeid:  u64,
	uid:     u32,
	gid:     u32,
	pid:     u32,
	padding: u32,
}
#assert(size_of(Fuse_In_Header) == 40)

Fuse_Out_Header :: struct {
	len:    u32,
	error:  i32, // 0 = success, negative errno otherwise
	unique: u64,
}
#assert(size_of(Fuse_Out_Header) == 16)

Fuse_Init_In :: struct {
	major:         u32,
	minor:         u32,
	max_readahead: u32,
	flags:         u32,
	flags2:        u32, // 7.36+ only; ignored
	unused:        [11]u32,
}
#assert(size_of(Fuse_Init_In) == 64)

// 7.31 layout (64 bytes); for minor >= 36 the kernel would read flags2
// out of unused[7], but we reply minor <= 31 so the old layout governs.
Fuse_Init_Out :: struct {
	major:                u32,
	minor:                u32,
	max_readahead:        u32,
	flags:                u32,
	max_background:       u16,
	congestion_threshold: u16,
	max_write:            u32,
	time_gran:            u32,
	max_pages:            u16,
	map_alignment:        u16,
	unused:               [8]u32,
}
#assert(size_of(Fuse_Init_Out) == 64)

Fuse_Attr :: struct {
	ino:       u64,
	size:      u64,
	blocks:    u64,
	atime:     u64,
	mtime:     u64,
	ctime:     u64,
	atimensec: u32,
	mtimensec: u32,
	ctimensec: u32,
	mode:      u32,
	nlink:     u32,
	uid:       u32,
	gid:       u32,
	rdev:      u32,
	blksize:   u32,
	padding:   u32,
}
#assert(size_of(Fuse_Attr) == 88)

Fuse_Entry_Out :: struct {
	nodeid:           u64,
	generation:       u64,
	entry_valid:      u64,
	attr_valid:       u64,
	entry_valid_nsec: u32,
	attr_valid_nsec:  u32,
	attr:             Fuse_Attr,
}
#assert(size_of(Fuse_Entry_Out) == 128)

Fuse_Attr_Out :: struct {
	attr_valid:      u64,
	attr_valid_nsec: u32,
	dummy:           u32,
	attr:            Fuse_Attr,
}
#assert(size_of(Fuse_Attr_Out) == 104)

Fuse_Getattr_In :: struct {
	getattr_flags: u32,
	dummy:         u32,
	fh:            u64,
}
#assert(size_of(Fuse_Getattr_In) == 16)

Fuse_Open_In :: struct {
	flags:      u32,
	open_flags: u32,
}
#assert(size_of(Fuse_Open_In) == 8)

Fuse_Open_Out :: struct {
	fh:         u64,
	open_flags: u32,
	padding:    u32,
}
#assert(size_of(Fuse_Open_Out) == 16)

// Shared by READ and READDIR (the offset/size fields are the ones used).
Fuse_Read_In :: struct {
	fh:         u64,
	offset:     u64,
	size:       u32,
	read_flags: u32,
	lock_owner: u64,
	flags:      u32,
	padding:    u32,
}
#assert(size_of(Fuse_Read_In) == 40)

Fuse_Dirent :: struct {
	ino:     u64,
	off:     u64,
	namelen: u32, // includes the terminating NUL
	typ:     u32,
}
#assert(size_of(Fuse_Dirent) == 24)

Fuse_Statfs_Out :: struct {
	blocks:  u64,
	bfree:   u64,
	bavail:  u64,
	files:   u64,
	ffree:   u64,
	bsize:   u32,
	namelen: u32,
	frsize:  u32,
	padding: u32,
	spare:   [6]u32,
}
#assert(size_of(Fuse_Statfs_Out) == 80)

// SCM_RIGHTS control message plumbing for the fusermount3 handshake
// (x86-64 Linux layout).
SOL_SOCKET :: 1
SCM_RIGHTS :: 1

Cmsghdr :: struct {
	len:   uint,
	level: i32,
	type:  i32,
}
#assert(size_of(Cmsghdr) == 16)

// --- served content ----------------------------------------------------

HELLO_CONTENT := "hello, 世界! édition — 42\n"

BIG_LINES :: 8000
BIG_BYTES :: BIG_LINES * 35 // "%06d: abcdefghijklmnopqrstuvwxyz\n"

// build_big_content generates the deterministic big.txt body (273.4 KiB,
// more than two full 128 KiB max_read chunks). The caller owns the
// returned slice (delete it with the same allocator, default = heap).
build_big_content :: proc() -> ([]u8, bool) {
	buf := make([dynamic]u8, 0, BIG_BYTES)
	for i in 0 ..< BIG_LINES {
		// temp-allocated line; copied into buf immediately.
		line := fmt.tprintf("%06d: abcdefghijklmnopqrstuvwxyz\n", i)
		append(&buf, ..transmute([]u8)line)
	}
	return buf[:], true
}

// --- connection state --------------------------------------------------

Fuse_Conn :: struct {
	fd:           linux.Fd,
	direct_mount: bool, // mount(2) succeeded directly (privileged path)
	kernel_minor: u32,
	kernel_flags: u32,
	destroyed:    bool,
	stats:        [64]u32, // requests per opcode, for the harness
	hello:        []u8,    // borrowed: HELLO_CONTENT constant
	big:          []u8,    // owned by run_mount
}

// stop_requested is set from the SIGTERM handler and read in the serve
// loop. Single-writer/single-reader on a word-aligned i32; the only
// signal-safe action taken in the handler. The read() syscall returns
// EINTR when the handler runs, so the loop observes the flag promptly.
stop_requested: i32

term_handler :: proc "c" (sig: linux.Signal) {
	stop_requested = 1
}

// --- small helpers -----------------------------------------------------

// bytes_of is the one raw-pointer boundary: it turns a wire struct into a
// byte view for append/write. Precondition: p points to at least n valid
// bytes of the struct.
bytes_of :: proc(p: rawptr, n: int) -> []u8 {
	return ([^]u8)(p)[:n]
}

write_all :: proc(fd: linux.Fd, data: []u8) -> bool {
	rest := data
	for len(rest) > 0 {
		n, errno := linux.write(fd, rest)
		if errno == .EINTR {
			continue
		}
		if errno != .NONE || n <= 0 {
			return false
		}
		rest = rest[n:]
	}
	return true
}

reply_error :: proc(c: ^Fuse_Conn, unique: u64, err: i32) -> bool {
	out := Fuse_Out_Header{len = 16, error = err, unique = unique}
	return write_all(c.fd, bytes_of(&out, 16))
}

reply_payload :: proc(c: ^Fuse_Conn, unique: u64, payload: []u8) -> bool {
	out := Fuse_Out_Header{len = u32(16 + len(payload)), error = 0, unique = unique}
	buf := make([dynamic]u8, 0, 16 + len(payload))
	defer delete(buf)
	append(&buf, ..bytes_of(&out, 16))
	append(&buf, ..payload)
	return write_all(c.fd, buf[:])
}

// make_attr builds the attribute block for a node. Times are a fixed
// constant so stat output is deterministic.
make_attr :: proc(node, size: u64, mode: u32, nlink: u32) -> Fuse_Attr {
	now :: u64(1700000000)
	return Fuse_Attr {
		ino = node,
		size = size,
		blocks = (size + 511) / 512,
		atime = now,
		mtime = now,
		ctime = now,
		mode = mode,
		nlink = nlink,
		uid = u32(linux.geteuid()),
		gid = u32(linux.getegid()),
		rdev = 0,
		blksize = 4096,
	}
}

attr_for_node :: proc(node: u64, hello, big: []u8) -> (Fuse_Attr, bool) {
	switch node {
	case FUSE_ROOT_ID:
		return make_attr(FUSE_ROOT_ID, 4096, S_IFDIR | 0o755, 2), true
	case HELLO_NODE:
		return make_attr(HELLO_NODE, u64(len(hello)), S_IFREG | 0o644, 1), true
	case BIG_NODE:
		return make_attr(BIG_NODE, u64(len(big)), S_IFREG | 0o644, 1), true
	}
	return {}, false
}

// --- request handlers --------------------------------------------------

handle_init :: proc(c: ^Fuse_Conn, hdr: ^Fuse_In_Header, payload: []u8) -> bool {
	if len(payload) < 16 {
		return reply_error(c, hdr.unique, -i32(linux.Errno.EINVAL))
	}
	rin := (^Fuse_Init_In)(raw_data(payload))
	c.kernel_minor = rin.minor
	c.kernel_flags = rin.flags
	minor := rin.minor < FUSE_MINOR_VERSION ? rin.minor : FUSE_MINOR_VERSION
	out := Fuse_Init_Out {
		major = FUSE_KERNEL_VERSION,
		minor = minor,
		max_readahead = rin.max_readahead,
		flags = 0, // no READDIRPLUS/parallel-dirops negotiation
		max_background = 0,
		congestion_threshold = 0,
		max_write = 128 * 1024,
		time_gran = 1,
		max_pages = 0,
		map_alignment = 0,
		unused = {},
	}
	fmt.printf(
		">> init: negotiated 7.%d (kernel offered 7.%d, flags=0x%x)\n",
		minor,
		rin.minor,
		rin.flags,
	)
	return reply_payload(c, hdr.unique, bytes_of(&out, size_of(Fuse_Init_Out)))
}

handle_getattr :: proc(c: ^Fuse_Conn, hdr: ^Fuse_In_Header) -> bool {
	attr, ok := attr_for_node(hdr.nodeid, c.hello, c.big)
	if !ok {
		return reply_error(c, hdr.unique, -i32(linux.Errno.ENOENT))
	}
	out := Fuse_Attr_Out{attr_valid = 1, attr = attr}
	return reply_payload(c, hdr.unique, bytes_of(&out, size_of(Fuse_Attr_Out)))
}

handle_lookup :: proc(c: ^Fuse_Conn, hdr: ^Fuse_In_Header, payload: []u8) -> bool {
	// The kernel sends NUL-terminated names; require the terminator to be
	// inside the payload before treating it as a string.
	if bytes.index_byte(payload, 0) < 0 {
		return reply_error(c, hdr.unique, -i32(linux.Errno.EINVAL))
	}
	name := string(cstring(raw_data(payload)))
	node: u64
	attr: Fuse_Attr
	switch name {
	case "hello.txt":
		node = HELLO_NODE
		attr, _ = attr_for_node(HELLO_NODE, c.hello, c.big)
	case "big.txt":
		node = BIG_NODE
		attr, _ = attr_for_node(BIG_NODE, c.hello, c.big)
	case:
		return reply_error(c, hdr.unique, -i32(linux.Errno.ENOENT))
	}
	out := Fuse_Entry_Out{nodeid = node, entry_valid = 1, attr_valid = 1, attr = attr}
	return reply_payload(c, hdr.unique, bytes_of(&out, size_of(Fuse_Entry_Out)))
}

handle_open :: proc(c: ^Fuse_Conn, hdr: ^Fuse_In_Header) -> bool {
	out := Fuse_Open_Out{fh = 0, open_flags = 0} // nodeid identifies the file; fh unused
	return reply_payload(c, hdr.unique, bytes_of(&out, size_of(Fuse_Open_Out)))
}

handle_read :: proc(c: ^Fuse_Conn, hdr: ^Fuse_In_Header, payload: []u8) -> bool {
	if len(payload) < size_of(Fuse_Read_In) {
		return reply_error(c, hdr.unique, -i32(linux.Errno.EINVAL))
	}
	rin := (^Fuse_Read_In)(raw_data(payload))
	content: []u8
	switch hdr.nodeid {
	case HELLO_NODE:
		content = c.hello
	case BIG_NODE:
		content = c.big
	case:
		return reply_error(c, hdr.unique, -i32(linux.Errno.ENOENT))
	}
	off := int(rin.offset)
	size := int(rin.size)
	if off >= len(content) {
		size = 0
	} else if off + size > len(content) {
		size = len(content) - off
	}
	if size > 1 << 20 { // defensive cap; kernel max_read is 128 KiB
		size = 1 << 20
	}
	return reply_payload(c, hdr.unique, content[off:off + size])
}

Dir_Entry :: struct {
	ino:  u64,
	off:  u64,
	typ:  u32,
	name: string,
}

ROOT_ENTRIES := [?]Dir_Entry {
	{FUSE_ROOT_ID, 1, DT_DIR, "."},
	{FUSE_ROOT_ID, 2, DT_DIR, ".."},
	{HELLO_NODE, 3, DT_REG, "hello.txt"},
	{BIG_NODE, 4, DT_REG, "big.txt"},
}

// handle_readdir serves both READDIR and READDIRPLUS (the kernel only
// sends READDIRPLUS when negotiated, but the opcode is implemented for
// the M19 adapter's future needs). Entries with off > offset are emitted
// in order; each dirent's off is its own index so the kernel resumes
// correctly.
handle_readdir :: proc(c: ^Fuse_Conn, hdr: ^Fuse_In_Header, payload: []u8, plus: bool) -> bool {
	if len(payload) < size_of(Fuse_Read_In) {
		return reply_error(c, hdr.unique, -i32(linux.Errno.EINVAL))
	}
	rin := (^Fuse_Read_In)(raw_data(payload))
	offset := rin.offset
	budget := int(rin.size)
	buf := make([dynamic]u8, 0, budget < 4096 ? budget : 4096)
	defer delete(buf)
	for e in ROOT_ENTRIES {
		if e.off <= offset {
			continue
		}
		item_len := 24 + len(e.name) + 1
		if plus {
			item_len += 128
		}
		if item_len > budget {
			break // kernel will resume from the last returned off
		}
		de := Fuse_Dirent{ino = e.ino, off = e.off, namelen = u32(len(e.name) + 1), typ = e.typ}
		append(&buf, ..bytes_of(&de, 24))
		append(&buf, ..transmute([]u8)e.name)
		append(&buf, 0) // NUL terminator, counted in namelen
		if plus {
			attr, ok := attr_for_node(e.ino, c.hello, c.big)
			if !ok {
				continue
			}
			eo := Fuse_Entry_Out{nodeid = e.ino, entry_valid = 1, attr_valid = 1, attr = attr}
			append(&buf, ..bytes_of(&eo, 128))
		}
		budget -= item_len
	}
	return reply_payload(c, hdr.unique, buf[:])
}

handle_statfs :: proc(c: ^Fuse_Conn, hdr: ^Fuse_In_Header) -> bool {
	// Sizes are 0 (unknown); bsize/frsize/namelen keep df and name lookups
	// well-behaved.
	out := Fuse_Statfs_Out{bsize = 4096, namelen = 255, frsize = 4096}
	return reply_payload(c, hdr.unique, bytes_of(&out, size_of(Fuse_Statfs_Out)))
}

// dispatch answers one request. Returns false only for protocol-level
// failures; opcode-level unknowns get an ENOSYS reply like the kernel
// expects from a minimally capable daemon.
dispatch :: proc(c: ^Fuse_Conn, hdr: ^Fuse_In_Header, payload: []u8) -> bool {
	switch hdr.opcode {
	case FUSE_INIT:
		return handle_init(c, hdr, payload)
	case FUSE_GETATTR:
		return handle_getattr(c, hdr)
	case FUSE_LOOKUP:
		return handle_lookup(c, hdr, payload)
	case FUSE_OPEN, FUSE_OPENDIR:
		return handle_open(c, hdr)
	case FUSE_READ:
		return handle_read(c, hdr, payload)
	case FUSE_READDIR:
		return handle_readdir(c, hdr, payload, false)
	case FUSE_READDIRPLUS:
		return handle_readdir(c, hdr, payload, true)
	case FUSE_STATFS:
		return handle_statfs(c, hdr)
	case FUSE_RELEASE, FUSE_RELEASEDIR, FUSE_FLUSH, FUSE_ACCESS:
		return reply_payload(c, hdr.unique, nil)
	case FUSE_DESTROY:
		c.destroyed = true
		return reply_payload(c, hdr.unique, nil)
	case FUSE_FORGET, FUSE_BATCH_FORGET:
		return true // no reply expected
	case FUSE_INTERRUPT:
		return reply_error(c, hdr.unique, -i32(linux.Errno.ENOSYS))
	case:
		return reply_error(c, hdr.unique, -i32(linux.Errno.ENOSYS))
	}
}

// serve is the daemon loop: one blocking read per kernel request, until
// SIGTERM (stop_requested) or FUSE_DESTROY. Returns true on a clean stop.
serve :: proc(c: ^Fuse_Conn, rbuf: []u8) -> bool {
	for stop_requested == 0 && !c.destroyed {
		n, errno := linux.read(c.fd, rbuf)
		if errno == .EINTR {
			continue // handler ran; loop condition re-checks the flag
		}
		if errno != .NONE {
			fmt.eprintf(">> serve: read failed: %v\n", errno)
			return false
		}
		if n < size_of(Fuse_In_Header) {
			fmt.eprintf(">> serve: short request (%d bytes)\n", n)
			return false
		}
		hdr := (^Fuse_In_Header)(raw_data(rbuf))
		if int(hdr.len) > n || hdr.len < size_of(Fuse_In_Header) {
			fmt.eprintf(">> serve: bad header len %d (read %d)\n", hdr.len, n)
			return false
		}
		payload := rbuf[size_of(Fuse_In_Header):int(hdr.len)]
		if int(hdr.opcode) < len(c.stats) {
			c.stats[hdr.opcode] += 1
		}
		if !dispatch(c, hdr, payload) {
			fmt.eprintf(">> serve: write reply failed (opcode %d)\n", hdr.opcode)
			return false
		}
	}
	return true
}

// --- mount / unmount ---------------------------------------------------

// open_fuse_device opens the connection endpoint for the direct mount(2)
// path. The fusermount3 helper opens its own /dev/fuse fd (matching the
// caller's real uid via fsuid) and returns it over SCM_RIGHTS, so this fd
// is only used when mount(2) succeeds directly.
open_fuse_device :: proc() -> (fd: linux.Fd, errno: linux.Errno) {
	fd, errno = linux.open("/dev/fuse", {.RDWR})
	return
}

// mount_via_syscall is the privileged deployment path: a direct mount(2)
// with the connection fd in the data options. Requires CAP_SYS_ADMIN in
// this mount namespace; on an ordinary desktop user session this fails
// with EPERM and run_mount falls back to fusermount3.
mount_via_syscall :: proc(mnt_c, opts_c: cstring) -> linux.Errno {
	return linux.mount("hammer", mnt_c, "fuse", {.NOSUID, .NODEV, .RDONLY}, rawptr(opts_c))
}

// receive_fd completes the new-style fusermount3 handshake: the helper
// mounted the filesystem with its own /dev/fuse fd and sends it back as
// one byte of payload plus an SCM_RIGHTS control message on the comm
// socket. Returns false on EOF (helper failed and exited) or a malformed
// control message.
receive_fd :: proc(sock: linux.Fd) -> (fd: linux.Fd, ok: bool) {
	byte_buf: [1]u8
	iov := []linux.IO_Vec{{base = raw_data(byte_buf[:]), len = 1}}
	ctrl: [24]u8 // CMSG_SPACE(sizeof(int)) = 20 on x86-64
	msg := linux.Msg_Hdr{iov = iov, control = ctrl[:]}
	for {
		n, errno := linux.recvmsg(sock, &msg, {})
		if errno == .EINTR {
			continue
		}
		if errno != .NONE {
			return 0, false
		}
		if n != 1 {
			return 0, false // EOF: helper exited without mounting
		}
		break
	}
	if .CTRUNC in msg.flags {
		return 0, false
	}
	cmsg := (^Cmsghdr)(raw_data(ctrl[:]))
	if cmsg.level != SOL_SOCKET || cmsg.type != SCM_RIGHTS || cmsg.len < size_of(Cmsghdr) + size_of(i32) {
		return 0, false
	}
	got := (^i32)(uintptr(cmsg) + size_of(Cmsghdr))^
	return linux.Fd(got), true
}

// run_fusermount3 mounts via the setuid helper using the protocol libfuse
// 3.x speaks with it (this fusermount3 rejects "old style" fd inheritance):
//
//   - socketpair(AF_UNIX, SOCK_STREAM)
//   - fork; the child execs /usr/bin/fusermount3 with
//     -o <opts> -- <mountpoint> and _FUSE_COMMFD=<child's socket fd> in
//     its environment (the fd is inherited, no CLOEXEC)
//   - the helper opens /dev/fuse itself, does check_perm + mount(2), then
//     sendmsg()s the fuse fd back over the socket with SCM_RIGHTS
//   - the parent recvmsg()s the fd, then reaps the helper
//
// argv/env storage is heap-allocated before the fork; the child's copies
// are discarded by execve (or exit on failure). Returns the FUSE
// connection fd on success.
run_fusermount3 :: proc(mnt, opts: string) -> (fd: linux.Fd, ok: bool) {
	pair: [2]linux.Fd
	if serr := linux.socketpair(.UNIX, .STREAM, .UNSPECIFIED, &pair); serr != .NONE {
		fmt.eprintf(">> mount: socketpair failed: %v\n", serr)
		return 0, false
	}

	argv := make([dynamic]cstring, 0, 6)
	envp := make([dynamic]cstring, 0, 2)
	append_cstr :: proc(a: ^[dynamic]cstring, s: string) -> bool {
		cs, err := strings.clone_to_cstring(s)
		if err != nil {
			return false
		}
		append(a, cs)
		return true
	}
	defer free_argv(&argv)
	defer free_argv(&envp)
	if !append_cstr(&argv, "/usr/bin/fusermount3") ||
	   !append_cstr(&argv, "-o") ||
	   !append_cstr(&argv, opts) ||
	   !append_cstr(&argv, "--") ||
	   !append_cstr(&argv, mnt) ||
	   !append_cstr(&envp, fmt.tprintf("_FUSE_COMMFD=%d", pair[1])) {
		linux.close(pair[0])
		linux.close(pair[1])
		return 0, false
	}
	append(&argv, nil)
	append(&envp, nil)

	pid, errno := linux.fork()
	if errno != .NONE {
		linux.close(pair[0])
		linux.close(pair[1])
		return 0, false
	}
	if pid == 0 {
		// Child: raw syscalls only. pair[1] is inherited across execve
		// at the number recorded in _FUSE_COMMFD.
		linux.execve(argv[0], raw_data(argv), raw_data(envp))
		msg := transmute([]u8)string("child: fusermount3 exec failed\n")
		linux.write(2, msg)
		linux.exit(127)
	}

	linux.close(pair[1])
	fd, ok = receive_fd(pair[0])
	linux.close(pair[0])

	status: u32
	for {
		p, werr := linux.waitpid(pid, &status, {}, nil)
		if werr == .EINTR {
			continue
		}
		if werr != .NONE || p != pid {
			return 0, false
		}
		break
	}
	return fd, ok && linux.WIFEXITED(status) && linux.WEXITSTATUS(status) == 0
}

free_argv :: proc(argv: ^[dynamic]cstring) {
	for s in argv {
		if s != nil {
			free(rawptr(s))
		}
	}
	delete(argv^)
}

// unmount_fuse reverses the mount path that was taken: umount2 for the
// privileged direct mount, fusermount3 -u for the helper mount.
unmount_fuse :: proc(mnt: string, direct: bool) -> bool {
	if direct {
		mnt_c, err := strings.clone_to_cstring(mnt, context.temp_allocator)
		if err != nil {
			return false
		}
		uerr := linux.umount2(mnt_c, {})
		if uerr == .NONE {
			return true
		}
		fmt.eprintf(">> unmount: umount2 failed: %v\n", uerr)
		return false
	}
	argv := make([dynamic]cstring, 0, 4)
	append_argv :: proc(a: ^[dynamic]cstring, s: string) -> bool {
		cs, err := strings.clone_to_cstring(s)
		if err != nil {
			return false
		}
		append(a, cs)
		return true
	}
	defer free_argv(&argv)
	if !append_argv(&argv, "/usr/bin/fusermount3") ||
	   !append_argv(&argv, "-u") ||
	   !append_argv(&argv, mnt) {
		return false
	}
	append(&argv, nil)

	pid, errno := linux.fork()
	if errno != .NONE {
		return false
	}
	if pid == 0 {
		linux.execve(argv[0], raw_data(argv), nil)
		msg := transmute([]u8)string("child: fusermount3 -u exec failed\n")
		linux.write(2, msg)
		linux.exit(127)
	}
	status: u32
	for {
		p, werr := linux.waitpid(pid, &status, {}, nil)
		if werr == .EINTR {
			continue
		}
		if werr != .NONE || p != pid {
			return false
		}
		break
	}
	ok := linux.WIFEXITED(status) && linux.WEXITSTATUS(status) == 0
	if !ok {
		fmt.eprintln(">> unmount: fusermount3 -u failed")
	}
	return ok
}

// --- modes -------------------------------------------------------------

run_mount :: proc(mnt: string) -> int {
	action := linux.Sig_Action{handler = term_handler, mask = {}}
	if sa_err := linux.rt_sigaction(.SIGTERM, &action, nil); sa_err != .NONE {
		fmt.eprintf(">> mount: rt_sigaction(SIGTERM) failed: %v\n", sa_err)
		return 1
	}

	fd, errno := open_fuse_device()
	if errno != .NONE {
		fmt.eprintf(">> mount: open /dev/fuse failed: %v\n", errno)
		return 1
	}
	// Shared pass-through options; the direct mount(2) path additionally
	// carries fd=/rootmode=/user_id=/group_id=, which the helper
	// regenerates from its own /dev/fuse fd and the caller's ids.
	common_opts := "default_permissions,max_read=131072,fsname=hammer,subtype=hammer,ro"
	direct_opts := fmt.tprintf(
		"fd=%d,rootmode=40000,user_id=%d,group_id=%d,%s",
		fd,
		u32(linux.geteuid()),
		u32(linux.getegid()),
		common_opts,
	)
	mnt_c, aerr := strings.clone_to_cstring(mnt, context.temp_allocator)
	if aerr != nil {
		fmt.eprintln(">> mount: out of memory")
		linux.close(fd)
		return 1
	}
	opts_c, oerr := strings.clone_to_cstring(direct_opts, context.temp_allocator)
	if oerr != nil {
		fmt.eprintln(">> mount: out of memory")
		linux.close(fd)
		return 1
	}

	direct := false
	merr := mount_via_syscall(mnt_c, opts_c)
	switch {
	case merr == .NONE:
		direct = true
		fmt.println(">> mount: direct mount(2) ok (privileged path)")
	case merr == .EPERM:
		// Expected on an ordinary user session: fall back to the setuid
		// helper, exactly like libfuse's fuse_mount_sys. The helper
		// opens its own /dev/fuse fd; ours is no longer needed.
		linux.close(fd)
		hfd, hok := run_fusermount3(mnt, common_opts)
		if !hok {
			fmt.eprintln(">> mount: fusermount3 helper failed")
			return 1
		}
		fd = hfd
		fmt.println(">> mount: fusermount3 ok (setuid helper path; direct mount EPERM)")
	case:
		fmt.eprintf(">> mount: mount(2) failed: %v\n", merr)
		linux.close(fd)
		return 1
	}

	big, bok := build_big_content()
	if !bok {
		fmt.eprintln(">> mount: cannot build big.txt content")
		unmount_fuse(mnt, direct)
		linux.close(fd)
		return 1
	}
	defer delete(big)

	c := Fuse_Conn {
		fd = fd,
		direct_mount = direct,
		hello = transmute([]u8)HELLO_CONTENT, // read-only constant view
		big = big,
	}

	// Readiness line, straight to fd 1 (unbuffered) so the harness can
	// poll the log while the daemon is live.
	linux.write(1, transmute([]u8)string("MNT_OK\n"))

	// The kernel requires every read on /dev/fuse to be able to hold the
	// largest possible request: max(FUSE_MIN_READ_BUFFER=8192,
	// 4096 + max_write). We advertise max_write=131072 in INIT, so the
	// buffer must be >= 135168 (a smaller buffer makes read fail EINVAL —
	// verified during this spike).
	rbuf := make([]u8, 256 * 1024)
	defer delete(rbuf)
	served := serve(&c, rbuf)

	fmt.printf(">> serve: %s stats", served ? "stopped cleanly" : "failed")
	for i in 0 ..< len(c.stats) {
		if c.stats[i] != 0 {
			fmt.printf(" %d=%d", i, c.stats[i])
		}
	}
	fmt.println()

	if !unmount_fuse(mnt, direct) {
		fmt.eprintln(">> unmount: FAILED (mount may remain; use fusermount3 -uz)")
		linux.close(fd)
		return 1
	}
	fmt.println(">> unmount: clean (mountpoint released)")
	linux.close(fd)
	return served ? 0 : 1
}

// run_genref writes the served tree into dir so a harness can compare the
// mounted files against an on-disk reference.
run_genref :: proc(dir: string) -> int {
	hello := transmute([]u8)HELLO_CONTENT
	big, bok := build_big_content()
	if !bok {
		fmt.eprintln(">> genref: cannot build big.txt content")
		return 1
	}
	defer delete(big)
	hpath := fmt.tprintf("%s/hello.txt", dir)
	bpath := fmt.tprintf("%s/big.txt", dir)
	if os.write_entire_file(hpath, hello) != nil {
		fmt.eprintf(">> genref: cannot write %s\n", hpath)
		return 1
	}
	if os.write_entire_file(bpath, big) != nil {
		fmt.eprintf(">> genref: cannot write %s\n", bpath)
		return 1
	}
	return 0
}

main :: proc() {
	args := os.args
	if len(args) < 2 {
		fmt.eprintf("usage: %s <mount <dir>|genref <dir>>\n", args[0])
		os.exit(1)
	}
	switch args[1] {
	case "mount":
		if len(args) < 3 {
			fmt.eprintf("usage: %s mount <dir>\n", args[0])
			os.exit(1)
		}
		os.exit(run_mount(args[2]))
	case "genref":
		if len(args) < 3 {
			fmt.eprintf("usage: %s genref <dir>\n", args[0])
			os.exit(1)
		}
		os.exit(run_genref(args[2]))
	case:
		fmt.eprintf("usage: %s <mount <dir>|genref <dir>>\n", args[0])
		os.exit(1)
	}
}
