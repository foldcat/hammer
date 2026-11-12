// M00.04 — Native X11 clipboard spike (Linux/X11 only).
//
// A standalone spike that demonstrates X11 selection get/set over Xlib:
//   - UTF-8 (incl. non-ASCII) round-trips through the real selection
//   - Large transfers via the INCR protocol
//   - Both CLIPBOARD and PRIMARY selections
//   - Explicit errors on failure (no default Xlib error-exit behavior)
//
// This is throwaway spike code, not the M06.04 product implementation.
// The editor will build a clipboard service on these findings (delayed
// paste, ownership monitoring, cancellation, etc.). Findings are recorded
// in docs/m00-04-clipboard.md.
//
// Two modes, run as separate processes sharing one X display:
//
//     clipboard_spike serve <CLIPBOARD|PRIMARY> <file>
//         Owns the selection and serves the file's bytes as UTF8_STRING
//         (plus the GTK "text/plain;charset=utf-8" atom), using INCR for
//         payloads larger than 64 KiB. Runs until killed; prints
//         "ready <sel> len=<n>" to stdout once ownership is acquired.
//
//     clipboard_spike get <CLIPBOARD|PRIMARY> [-o outfile] [--timeout-ms n]
//         Requests the selection as UTF8_STRING, follows INCR if the
//         owner announces it, validates the payload as UTF-8, and writes
//         it to stdout (or outfile). Diagnostics go to stderr.
//
//     clipboard_spike get <CLIPBOARD|PRIMARY> --targets
//         Lists the owner's advertised conversion targets instead of
//         fetching text.
//
// Exit codes: 0 = success, 1 = runtime/X11 failure, 2 = usage error.
package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import xlib "vendor:x11/xlib"

INCR_THRESHOLD :: 64 * 1024          // payloads above this are served via INCR
INCR_CHUNK :: 64 * 1024              // bytes per INCR continuation step
MAX_TRANSFER :: 64 * 1024 * 1024     // refuse INCR streams larger than this
DEFAULT_TIMEOUT_MS :: 10_000         // get-mode deadline
POLL_INTERVAL :: 2 * time.Millisecond

DATA_PROP :: "HAMMER_CLIPBOARD_SPIKE"

// ---- X error handling -----------------------------------------------------
//
// Xlib's default error handler exits the process. The spike installs its
// own so failures (e.g. a requestor that dies mid-INCR) become explicit,
// inspectable errors. The program is single-threaded, so a plain global
// flag is sufficient.

x_error_seen: bool
x_error_code: i32

on_x_error :: proc "c" (display: ^xlib.Display, event: ^xlib.XErrorEvent) -> i32 {
	x_error_seen = true
	x_error_code = i32(event.error_code)
	return 0
}

x_error_text :: proc(code: i32) -> string {
	switch code {
	case 0:  return "Success"
	case 2:  return "BadValue"
	case 3:  return "BadWindow"
	case 4:  return "BadPixmap"
	case 5:  return "BadAtom"
	case 8:  return "BadMatch"
	case 9:  return "BadDrawable"
	case 10: return "BadAccess"
	case 11: return "BadAlloc"
	case 14: return "BadIDChoice"
	}
	return "unknown"
}

// ---- atoms -----------------------------------------------------------------

Atoms :: struct {
	selection: xlib.Atom,
	targets:   xlib.Atom,
	utf8:      xlib.Atom,
	gtk_utf8:  xlib.Atom,
	incr:      xlib.Atom,
	data_prop: xlib.Atom,
}

selection_atom :: proc(display: ^xlib.Display, name: string) -> (xlib.Atom, bool) {
	known: string
	switch name {
	case "CLIPBOARD":
		known = "CLIPBOARD"
	case "PRIMARY":
		known = "PRIMARY"
	case:
		return 0, false
	}
	cname, aerr := strings.clone_to_cstring(known, context.temp_allocator)
	if aerr != nil {
		fmt.eprintln("error: out of scratch memory while interning an atom")
		return 0, false
	}
	return xlib.InternAtom(display, cname, false), true
}

make_atoms :: proc(display: ^xlib.Display, selection: xlib.Atom) -> Atoms {
	return Atoms{
		selection = selection,
		targets = xlib.InternAtom(display, cstring("TARGETS"), false),
		utf8 = xlib.InternAtom(display, cstring("UTF8_STRING"), false),
		gtk_utf8 = xlib.InternAtom(display, cstring("text/plain;charset=utf-8"), false),
		incr = xlib.InternAtom(display, cstring("INCR"), false),
		data_prop = xlib.InternAtom(display, cstring(DATA_PROP), false),
	}
}

atom_name :: proc(display: ^xlib.Display, atom: xlib.Atom) -> string {
	if atom == 0 {
		return "(none)"
	}
	// Borrowed from Xlib; used immediately, never stored.
	cs := xlib.GetAtomName(display, atom)
	if cs == nil {
		return "(unknown)"
	}
	return string(cs)
}

// ---- display setup --------------------------------------------------------

// open_display connects to the X server and creates a hidden 1x1 window
// with PropertyChange selected (needed to receive the INCR pacing
// notifications on the window that owns the conversion property).
open_display :: proc() -> (display: ^xlib.Display, window: xlib.Window, ok: bool) {
	xlib.SetErrorHandler(on_x_error)

	display = xlib.OpenDisplay(nil)
	if display == nil {
		fmt.eprintln("error: XOpenDisplay failed (is DISPLAY set?)")
		return nil, 0, false
	}

	// XChangeProperty data must be given in server byte order. The spike
	// does not implement byte swapping, so mismatched servers are refused
	// explicitly instead of serving garbage.
	expected := xlib.ByteOrder.LSBFirst if ODIN_ENDIAN == .Little else xlib.ByteOrder.MSBFirst
	if xlib.ImageByteOrder(display) != expected {
		fmt.eprintln("error: server byte order differs from client; not supported by this spike")
		xlib.CloseDisplay(display)
		return nil, 0, false
	}

	window = xlib.CreateSimpleWindow(
		display,
		xlib.DefaultRootWindow(display),
		0, 0, 1, 1, 0, 0, 0,
	)
	if window == 0 {
		fmt.eprintln("error: XCreateSimpleWindow failed")
		xlib.CloseDisplay(display)
		return nil, 0, false
	}
	xlib.SelectInput(display, window, {.PropertyChange})
	return display, window, true
}

// ---- owner side (serve) ----------------------------------------------------

// One active INCR transfer at a time (keyed by the requestor's window and
// property). Concurrent INCR requests are refused explicitly.
Incr_State :: struct {
	active:    bool,
	requestor: xlib.Window,
	property:  xlib.Atom,
	target:    xlib.Atom,
	pos:       int,
}

serve :: proc(selection_name, path: string) -> int {
	// Owned by this proc; freed on return.
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintf("error: cannot read %s: %v\n", path, err)
		return 1
	}
	defer delete(data)

	display, window, ok := open_display()
	if !ok {
		return 1
	}
	defer xlib.CloseDisplay(display)

	selection, valid := selection_atom(display, selection_name)
	if !valid {
		fmt.eprintf("error: unknown selection %q (want CLIPBOARD or PRIMARY)\n", selection_name)
		return 2
	}
	atoms := make_atoms(display, selection)

	xlib.SetSelectionOwner(display, selection, window, xlib.CurrentTime)
	xlib.Sync(display, false) // round-trip: deliver any pending X errors
	if x_error_seen {
		fmt.eprintf("error: X error (%s) while acquiring %s\n", x_error_text(x_error_code), selection_name)
		return 1
	}
	if xlib.GetSelectionOwner(display, selection) != window {
		fmt.eprintf("error: could not acquire %s (does another client own it?)\n", selection_name)
		return 1
	}

	fmt.printf("ready %s len=%d\n", selection_name, len(data))

	incr: Incr_State
	for {
		ev: xlib.XEvent
		xlib.NextEvent(display, &ev)
		#partial switch ev.type {
		case .SelectionRequest:
			handle_selection_request(display, &atoms, data, &incr, ev.xselectionrequest)
		case .SelectionClear:
			fmt.printf("lost %s (another client took ownership)\n", selection_name)
			return 0
		case .PropertyNotify:
			p := ev.xproperty
			if incr.active &&
			   p.window == incr.requestor &&
			   p.atom == incr.property &&
			   p.state == .PropertyDelete {
				incr_step(display, data, &incr)
			}
		}
	}
}

handle_selection_request :: proc(
	display: ^xlib.Display,
	atoms: ^Atoms,
	data: []u8,
	incr: ^Incr_State,
	req: xlib.XSelectionRequestEvent,
) {
	reply_property: xlib.Atom = xlib.None

	fmt.eprintf(
		"trace: SelectionRequest target=%s requestor=%x property=%x\n",
		atom_name(display, req.target), req.requestor, req.property,
	)

	switch req.target {
	case atoms.targets:
		targets := [3]xlib.Atom{atoms.targets, atoms.utf8, atoms.gtk_utf8}
		xlib.ChangeProperty(
			display, req.requestor, req.property,
			xlib.XA_ATOM, 32, xlib.PropModeReplace,
			rawptr(&targets[0]), 3,
		)
		reply_property = req.property
	case atoms.utf8, atoms.gtk_utf8:
		if len(data) <= INCR_THRESHOLD {
			if len(data) > 0 {
				xlib.ChangeProperty(
					display, req.requestor, req.property,
					req.target, 8, xlib.PropModeReplace,
					rawptr(&data[0]), i32(len(data)),
				)
			} else {
				xlib.ChangeProperty(
					display, req.requestor, req.property,
					req.target, 8, xlib.PropModeReplace,
					nil, 0,
				)
			}
			reply_property = req.property
		} else if incr.active {
			// Only one INCR transfer at a time in this spike; refusing is
			// safer than corrupting both transfers.
			fmt.eprintln("note: refusing request while another INCR transfer is active")
			reply_property = xlib.None
		} else {
			length := u32(len(data))
			xlib.ChangeProperty(
				display, req.requestor, req.property,
				atoms.incr, 32, xlib.PropModeReplace,
				rawptr(&length), 1,
			)
			// Watch the requestor's window: PropertyNotify(Delete) events
			// there pace the INCR continuation steps.
			xlib.SelectInput(display, req.requestor, {.PropertyChange})
			incr^ = Incr_State{
				active = true,
				requestor = req.requestor,
				property = req.property,
				target = req.target,
				pos = 0,
			}
			fmt.printf(
				"note: serving %d bytes via INCR (%d chunk(s) of %d)\n",
				len(data), (len(data) + INCR_CHUNK - 1) / INCR_CHUNK, INCR_CHUNK,
			)
			reply_property = req.property
		}
	case:
		fmt.printf("note: refusing unsupported target %q\n", atom_name(display, req.target))
		reply_property = xlib.None
	}

	if x_error_seen {
		fmt.eprintf(
			"error: X error (%s) while serving a request (requestor gone?)\n",
			x_error_text(x_error_code),
		)
		x_error_seen = false
		incr.active = false
		return
	}

	notify := xlib.XEvent{}
	notify.xselection.type = .SelectionNotify
	notify.xselection.display = display
	notify.xselection.requestor = req.requestor
	notify.xselection.selection = req.selection
	notify.xselection.target = req.target
	notify.xselection.property = reply_property
	notify.xselection.time = req.time
	xlib.SendEvent(display, req.requestor, false, {}, &notify)
	xlib.Flush(display)

	fmt.eprintf("trace: replied to %x with property=%x\n", req.requestor, reply_property)
}

incr_step :: proc(display: ^xlib.Display, data: []u8, incr: ^Incr_State) {
	remaining := len(data) - incr.pos
	if remaining == 0 {
		// A zero-length property signals the end of the transfer.
		xlib.ChangeProperty(
			display, incr.requestor, incr.property,
			incr.target, 8, xlib.PropModeReplace,
			nil, 0,
		)
		incr.active = false
		fmt.println("note: INCR transfer complete")
		return
	}
	n := min(remaining, INCR_CHUNK)
	xlib.ChangeProperty(
		display, incr.requestor, incr.property,
		incr.target, 8, xlib.PropModeAppend,
		rawptr(&data[incr.pos]), i32(n),
	)
	incr.pos += n
	if x_error_seen {
		fmt.eprintf("error: X error (%s) during INCR transfer; aborting\n", x_error_text(x_error_code))
		x_error_seen = false
		incr.active = false
	}
}

// ---- requestor side (get) ---------------------------------------------------

get :: proc(
	selection_name: string,
	out_path: string,
	timeout: time.Duration,
	want_targets: bool,
) -> int {
	display, window, ok := open_display()
	if !ok {
		return 1
	}
	defer xlib.CloseDisplay(display)

	selection, valid := selection_atom(display, selection_name)
	if !valid {
		fmt.eprintf("error: unknown selection %q (want CLIPBOARD or PRIMARY)\n", selection_name)
		return 2
	}
	atoms := make_atoms(display, selection)

	target := atoms.utf8
	if want_targets {
		target = atoms.targets
	}

	xlib.ConvertSelection(display, selection, target, atoms.data_prop, window, xlib.CurrentTime)
	xlib.Flush(display)
	if x_error_seen {
		fmt.eprintf("error: X error (%s) during ConvertSelection\n", x_error_text(x_error_code))
		return 1
	}

	deadline := time.time_add(time.now(), timeout)

	// Phase 1: wait for SelectionNotify.
	for {
		if !wait_for_event(display, deadline) {
			fmt.eprintln("error: timed out waiting for SelectionNotify")
			return 1
		}
		ev: xlib.XEvent
		xlib.NextEvent(display, &ev)
		if ev.type != .SelectionNotify {
			continue
		}
		sel := ev.xselection
		if sel.requestor != window || sel.selection != selection || sel.target != target {
			continue
		}
		if sel.property == xlib.None {
			fmt.eprintf("error: conversion refused or no owner for %s\n", selection_name)
			return 1
		}
		fmt.eprintf("trace: SelectionNotify property=%x\n", sel.property)
		break
	}

	// Phase 2: read the conversion property. If it is the INCR marker,
	// follow the incremental protocol until the zero-length final chunk.
	act_type: xlib.Atom
	act_format: i32
	nitems, bytes_after: uint
	props: rawptr
	status := xlib.GetWindowProperty(
		display, window, atoms.data_prop,
		0, 1_000_000, false, xlib.AnyPropertyType,
		&act_type, &act_format, &nitems, &bytes_after, &props,
	)
	if status != 0 {
		fmt.eprintf("error: XGetWindowProperty failed with status %d\n", status)
		return 1
	}

	if want_targets {
		// The TARGETS reply is a list of 32-bit atoms; it is always tiny,
		// so an INCR announcement here is treated as an error.
		if act_type == atoms.incr {
			fmt.eprintln("error: TARGETS arrived via INCR; not supported by this spike")
			return 1
		}
		if act_type != xlib.XA_ATOM || act_format != 32 {
			fmt.eprintf("error: unexpected TARGETS payload (type %q, format %d)\n", atom_name(display, act_type), act_format)
			xlib.Free(props)
			return 1
		}
		fmt.printf("targets advertised by owner of %s:\n", selection_name)
		list := ([^]xlib.Atom)(props)
		for i in 0 ..< nitems {
			fmt.printf("  %s\n", atom_name(display, list[i]))
		}
		xlib.Free(props)
		xlib.DeleteProperty(display, window, atoms.data_prop)
		return 0
	}

	buf: [dynamic]u8
	defer delete(buf)
	used_incr := false

	if act_type == atoms.incr {
		if act_format != 32 || nitems != 1 {
			fmt.eprintf("error: malformed INCR announcement (format %d, %d item(s))\n", act_format, nitems)
			xlib.Free(props)
			return 1
		}
		expected := u64((([^]u32)(props))[0])
		xlib.Free(props)
		if expected > MAX_TRANSFER {
			fmt.eprintf("error: owner announced %d bytes; exceeds the %d byte limit\n", expected, MAX_TRANSFER)
			return 1
		}
		used_incr = true
		// Deleting the property acknowledges the announcement; the owner
		// starts sending chunks on the resulting PropertyNotify(Delete).
		xlib.DeleteProperty(display, window, atoms.data_prop)
		if !incr_receive_loop(display, window, &atoms, expected, &buf, deadline) {
			return 1
		}
	} else if act_type == atoms.utf8 || act_type == atoms.gtk_utf8 {
		if act_format != 8 {
			fmt.eprintf("error: owner served text with unexpected format %d\n", act_format)
			xlib.Free(props)
			return 1
		}
		if nitems > 0 {
			data := ([^]u8)(props)
			append(&buf, ..data[:nitems])
		}
		xlib.Free(props)
		xlib.DeleteProperty(display, window, atoms.data_prop)
	} else {
		fmt.eprintf("error: owner served unexpected type %q\n", atom_name(display, act_type))
		xlib.Free(props)
		return 1
	}

	if !utf8.valid_string(string(buf[:])) {
		fmt.eprintln("error: received data is not valid UTF-8 (owner violated UTF8_STRING)")
		return 1
	}

	if out_path == "" {
		_, werr := os.write(os.stdout, buf[:])
		if werr != nil {
			fmt.eprintf("error: writing stdout: %v\n", werr)
			return 1
		}
	} else {
		if werr := os.write_entire_file(out_path, buf[:]); werr != nil {
			fmt.eprintf("error: writing %s: %v\n", out_path, werr)
			return 1
		}
	}

	mode := "single property"
	if used_incr {
		mode = "INCR"
	}
	fmt.eprintf("received %d bytes from %s via %s (UTF-8 valid)\n", len(buf), selection_name, mode)
	return 0
}

incr_receive_loop :: proc(
	display: ^xlib.Display,
	window: xlib.Window,
	atoms: ^Atoms,
	expected: u64,
	buf: ^[dynamic]u8,
	deadline: time.Time,
) -> bool {
	for {
		if !wait_for_event(display, deadline) {
			fmt.eprintln("error: timed out waiting for an INCR chunk")
			return false
		}
		ev: xlib.XEvent
		xlib.NextEvent(display, &ev)
		if ev.type != .PropertyNotify {
			continue
		}
		p := ev.xproperty
		if p.window != window || p.atom != atoms.data_prop || p.state != .PropertyNewValue {
			continue // our own property deletions also produce notifications
		}

		act_type: xlib.Atom
		act_format: i32
		nitems, bytes_after: uint
		props: rawptr
		// delete=true: the property deletion that follows this read is
		// the acknowledgment that requests the next chunk from the owner.
		status := xlib.GetWindowProperty(
			display, window, atoms.data_prop,
			0, 1_000_000, true, xlib.AnyPropertyType,
			&act_type, &act_format, &nitems, &bytes_after, &props,
		)
		if status != 0 {
			fmt.eprintf("error: XGetWindowProperty failed with status %d during INCR\n", status)
			return false
		}
		if act_type != atoms.utf8 && act_type != atoms.gtk_utf8 {
			fmt.eprintf("error: INCR chunk has unexpected type %q\n", atom_name(display, act_type))
			xlib.Free(props)
			return false
		}
		if act_format != 8 {
			fmt.eprintf("error: INCR chunk has unexpected format %d\n", act_format)
			xlib.Free(props)
			return false
		}

		n := int(nitems)
		if n == 0 {
			// Zero-length chunk terminates the transfer.
			if expected != 0 && u64(len(buf)) != expected {
				fmt.eprintf("error: INCR size mismatch: owner announced %d, received %d\n", expected, len(buf))
				return false
			}
			return true
		}
		if u64(len(buf)) + u64(n) > MAX_TRANSFER {
			fmt.eprintf("error: INCR stream exceeded the %d byte limit\n", MAX_TRANSFER)
			xlib.Free(props)
			return false
		}
		data := ([^]u8)(props)
		append(buf, ..data[:n])
		xlib.Free(props)
	}
}

// wait_for_event polls until an event is available or the deadline passes.
// Xlib has no portable wait-with-timeout, and the spike is single-threaded,
// so a short poll with a deadline keeps failures bounded and explicit.
wait_for_event :: proc(display: ^xlib.Display, deadline: time.Time) -> bool {
	for xlib.Pending(display) == 0 {
		if i64(time.since(deadline)) >= 0 {
			return false
		}
		time.sleep(POLL_INTERVAL)
	}
	return true
}

// ---- CLI -------------------------------------------------------------------

usage :: proc() {
	fmt.eprintln(`usage:
  clipboard_spike serve <CLIPBOARD|PRIMARY> <file>
      Own the selection and serve the file's bytes as UTF8_STRING until killed.
  clipboard_spike get <CLIPBOARD|PRIMARY> [-o outfile] [--timeout-ms n] [--targets]
      Fetch the selection as UTF8_STRING (INCR-aware) to stdout or outfile.
      --targets lists the owner's advertised targets instead of fetching text.`)
}

run_get :: proc(args: []string) -> int {
	out_path := ""
	timeout_ms := DEFAULT_TIMEOUT_MS
	want_targets := false
	selection_name := ""

	i := 0
	for i < len(args) {
		arg := args[i]
		switch arg {
		case "-o":
			i += 1
			if i >= len(args) {
				usage()
				return 2
			}
			out_path = args[i]
		case "--timeout-ms":
			i += 1
			if i >= len(args) {
				usage()
				return 2
			}
			v, ok := strconv.parse_int(args[i])
			if !ok || v <= 0 {
				fmt.eprintf("error: invalid --timeout-ms %q\n", args[i])
				return 2
			}
			timeout_ms = v
		case "--targets":
			want_targets = true
		case:
			if selection_name == "" {
				selection_name = arg
			} else {
				usage()
				return 2
			}
		}
		i += 1
	}

	if selection_name == "" {
		usage()
		return 2
	}

	timeout := time.Duration(timeout_ms) * time.Millisecond
	return get(selection_name, out_path, timeout, want_targets)
}

report_leaks :: proc(track: ^mem.Tracking_Allocator) {
	if len(track.allocation_map) > 0 {
		fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
		for _, entry in track.allocation_map {
			fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
		}
	}
	if len(track.bad_free_array) > 0 {
		fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
		for entry in track.bad_free_array {
			fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
		}
	}
}

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)
	defer mem.tracking_allocator_destroy(&track)
	defer report_leaks(&track)

	args := os.args[1:]
	if len(args) == 0 {
		usage()
		os.exit(2)
	}
	switch args[0] {
	case "serve":
		if len(args) != 3 {
			usage()
			os.exit(2)
		}
		os.exit(serve(args[1], args[2]))
	case "get":
		os.exit(run_get(args[1:]))
	case:
		usage()
		os.exit(2)
	}
}
