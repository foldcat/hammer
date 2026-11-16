#+build linux

package x11ime

import "base:runtime"
import libc "core:c/libc"
import "core:mem"
import "core:unicode/utf8"

import xlib "vendor:x11/xlib"

import errs "../../core/errs"
import input "../../core/input"
import platform "../../platform"

DEFAULT_MAX_TEXT_BYTES :: 64 * 1024
LOOKUP_STACK_BYTES :: 256

XIMPreeditCallbacks :: xlib.XIMStyle(0x0002)
XIMPreeditNothing :: xlib.XIMStyle(0x0008)
XIMStatusNothing :: xlib.XIMStyle(0x0400)

Event_Filter :: proc "c" (event: ^xlib.XEvent) -> i32

foreign import ximlib "system:X11"
@(default_calling_convention = "c")
foreign ximlib {
	@(link_name = "XCloseIM") CloseIM :: proc(im: xlib.XIM) -> i32 ---
	@(link_name = "XDestroyIC") DestroyIC :: proc(ic: xlib.XIC) ---
	@(link_name = "XGetIMValues") GetIMValues_Styles :: proc(im: xlib.XIM, name: cstring, out: rawptr, term: cstring) -> cstring ---
	@(link_name = "XmbLookupString") mbLookupString :: proc(ic: xlib.XIC, event: ^xlib.XKeyEvent, buffer: [^]u8, bytes: i32, keysym: ^xlib.KeySym, status: ^i32) -> i32 ---
	@(link_name = "hammer_sapp_x11_set_event_filter") set_event_filter :: proc(filter: Event_Filter) ---
}

Preedit_Callbacks :: struct {
	client_data:    rawptr,
	start_callback: xlib.XIMCallback,
	draw_callback:  xlib.XIMCallback,
	caret_callback: xlib.XIMCallback,
	done_callback:  xlib.XIMCallback,
}

Options :: struct {
	max_bytes: int,
	allocator: runtime.Allocator,
	service:   platform.IME_Service,
	user:      rawptr,
}

// State is fixed-location and UI-thread owned. The display and window are
// borrowed from Sokol and must outlive State. The IM, IC, and callback table
// are destroyed together; event payloads are never retained by this package.
State :: struct {
	options:     Options,
	display:     ^xlib.Display,
	window:      xlib.Window,
	im:          xlib.XIM,
	ic:          xlib.XIC,
	callbacks:   Preedit_Callbacks,
	style:       xlib.XIMStyle,
	initialized: bool,
}

init :: proc(state: ^State, display: ^xlib.Display, window: xlib.Window, options: Options) -> errs.Error {
	if state == nil || display == nil || window == 0 {
		return errs.new(.Invalid_Input, "ime: invalid X11 display, window, or state")
	}
	if state.initialized {
		return errs.new(.Conflict, "ime: X11 state is already initialized")
	}
	if options.max_bytes < 0 {
		return errs.new(.Invalid_Input, "ime: negative X11 text limit")
	}
	error_allocator := options.allocator
	if error_allocator.procedure == nil {
		error_allocator = context.allocator
	}
	state.options = options
	if state.options.max_bytes == 0 {
		state.options.max_bytes = DEFAULT_MAX_TEXT_BYTES
	}
	state.options.allocator = error_allocator
	state.display = display
	state.window = window

	if libc.setlocale(libc.Locale_Category.CTYPE, cstring("")) == nil {
		state^ = State{}
		return errs.new(.Unsupported, "ime: the process LC_CTYPE locale is unavailable", allocator = error_allocator)
	}
	xlib.SetLocaleModifiers(cstring(""))
	state.im = xlib.OpenIM(display, nil, nil, nil)
	if state.im == nil {
		state^ = State{}
		return errs.new(.IO, "ime: XOpenIM failed", allocator = error_allocator)
	}

	styles: ^xlib.XIMStyles
	if message := GetIMValues_Styles(state.im, cstring("queryInputStyle"), rawptr(&styles), nil); message != nil {
		CloseIM(state.im)
		state^ = State{}
		return errs.new(.IO, "ime: XGetIMValues(queryInputStyle) failed", allocator = error_allocator)
	}
	if styles == nil || styles.count_styles == 0 {
		if styles != nil {
			xlib.Free(styles)
		}
		CloseIM(state.im)
		state^ = State{}
		return errs.new(.Unsupported, "ime: input method advertised no styles", allocator = error_allocator)
	}
	for index in 0 ..< int(styles.count_styles) {
		style := styles.supported_styles[index]
		if style & XIMPreeditCallbacks != 0 && style & XIMStatusNothing != 0 {
			state.style = style
			break
		}
	}
	if state.style == 0 {
		for index in 0 ..< int(styles.count_styles) {
			if styles.supported_styles[index] == XIMPreeditNothing | XIMStatusNothing {
				state.style = XIMPreeditNothing | XIMStatusNothing
				break
			}
		}
	}
	xlib.Free(styles)
	if state.style == 0 {
		CloseIM(state.im)
		state^ = State{}
		return errs.new(.Unsupported, "ime: no supported preedit style", allocator = error_allocator)
	}

	state.callbacks = Preedit_Callbacks {
		client_data = state,
		start_callback = {callback = preedit_start},
		draw_callback = {callback = preedit_draw},
		caret_callback = {callback = preedit_caret},
		done_callback = {callback = preedit_done},
	}
	if state.style & XIMPreeditCallbacks != 0 {
		state.ic = xlib.CreateIC(
			state.im,
			cstring("inputStyle"), state.style,
			cstring("clientWindow"), window,
			cstring("focusWindow"), window,
			cstring("preeditAttributes"), &state.callbacks,
			nil,
		)
	} else {
		state.ic = xlib.CreateIC(
			state.im,
			cstring("inputStyle"), state.style,
			cstring("clientWindow"), window,
			cstring("focusWindow"), window,
			nil,
		)
	}
	if state.ic == nil {
		CloseIM(state.im)
		state^ = State{}
		return errs.new(.IO, "ime: XCreateIC failed", allocator = error_allocator)
	}
	state.initialized = true
	xlib.SetICFocus(state.ic)
	return {}
}

destroy :: proc(state: ^State) {
	if state == nil {
		return
	}
	if state.ic != nil {
		DestroyIC(state.ic)
	}
	if state.im != nil {
		CloseIM(state.im)
	}
	state^ = State{}
}

notify :: proc(state: ^State, event: platform.IME_Event) {
	if state.options.service.notify != nil {
		state.options.service.notify(state.options.user, event)
	}
}

report :: proc(state: ^State, err: errs.Error) {
	local := err
	notify(state, {kind = .Error, err = local})
	errs.destroy(&local)
}

preedit_start :: proc "c" (xim: xlib.XIM, client_data, call_data: rawptr) {
	context = runtime.default_context()
	state := (^State)(client_data)
	if state != nil && state.initialized {
		notify(state, {kind = .Preedit})
	}
}

preedit_draw :: proc "c" (xim: xlib.XIM, client_data, call_data: rawptr) {
	context = runtime.default_context()
	state := (^State)(client_data)
	callback := (^xlib.XIMPreeditDrawCallbackStruct)(call_data)
	if state == nil || !state.initialized || callback == nil {
		return
	}
	if callback.caret < 0 {
		report(state, errs.new(.Invalid_Input, "ime: negative X11 preedit caret", allocator = state.options.allocator))
		return
	}
	if callback.text == nil || callback.text.length == 0 {
		notify(state, {kind = .Preedit, caret = int(callback.caret)})
		return
	}
	if callback.text.encoding_is_wchar {
		report(state, errs.new(.Unsupported, "ime: wide-character X11 preedit is unsupported", allocator = state.options.allocator))
		return
	}
	if callback.text.string.multi_byte == nil {
		report(state, errs.new(.Invalid_Input, "ime: X11 preedit has no text buffer", allocator = state.options.allocator))
		return
	}
	length := int(callback.text.length)
	if length > state.options.max_bytes {
		report(state, errs.new(.Resource_Limit, "ime: X11 preedit exceeds the text budget", allocator = state.options.allocator))
		return
	}
	text := callback.text.string.multi_byte[:length]
	if !utf8.valid_string(string(text)) {
		report(state, errs.new(.Invalid_Input, "ime: X11 preedit is not valid UTF-8", allocator = state.options.allocator))
		return
	}
	notify(state, {kind = .Preedit, text = text, caret = int(callback.caret)})
}

preedit_caret :: proc "c" (xim: xlib.XIM, client_data, call_data: rawptr) {
	context = runtime.default_context()
	state := (^State)(client_data)
	callback := (^xlib.XIMPreeditCaretCallbackStruct)(call_data)
	if state == nil || !state.initialized || callback == nil {
		return
	}
	if callback.position < 0 {
		report(state, errs.new(.Invalid_Input, "ime: negative X11 preedit caret", allocator = state.options.allocator))
		return
	}
	notify(state, {kind = .Preedit_Caret, caret = int(callback.position)})
}

preedit_done :: proc "c" (xim: xlib.XIM, client_data, call_data: rawptr) {
	context = runtime.default_context()
	state := (^State)(client_data)
	if state != nil && state.initialized {
		notify(state, {kind = .Preedit_Done})
	}
}

// filter_event returns 0 for ordinary Sokol processing, 1 to consume an event,
// or 2 to retain the Sokol key-down/up event while suppressing its legacy CHAR.
filter_event :: proc(state: ^State, event: ^xlib.XEvent) -> i32 {
	if state == nil || !state.initialized || event == nil {
		return 0
	}
	#partial switch event.type {
	case .MappingNotify:
		xlib.RefreshKeyboardMapping(&event.xmapping)
	case .FocusIn:
		xlib.SetICFocus(state.ic)
	case .FocusOut:
		xlib.UnsetICFocus(state.ic)
		notify(state, {kind = .Preedit_Done})
	case .KeyPress:
		if xlib.FilterEvent(event, state.window) {
			return 1
		}
		lookup_commit(state, &event.xkey)
		return 2
	case:
	}
	return 0
}

lookup_commit :: proc(state: ^State, event: ^xlib.XKeyEvent) {
	modifiers := commit_modifiers(event)
	buffer: [LOOKUP_STACK_BYTES]u8
	keysym: xlib.KeySym
	status: i32
	n := mbLookupString(state.ic, event, &buffer[0], len(buffer), &keysym, &status)
	if xlib.LookupStringStatus(status) == .BufferOverflow && int(n) > len(buffer) {
		if int(n) > state.options.max_bytes {
			report(state, errs.new(.Resource_Limit, "ime: X11 commit exceeds the text budget", allocator = state.options.allocator))
			return
		}
		owned, alloc_err := mem.alloc_bytes(int(n), 1, state.options.allocator)
		if alloc_err != .None {
			report(state, errs.newf(.Resource_Limit, "ime: allocating X11 commit failed: %v", alloc_err, allocator = state.options.allocator))
			return
		}
		defer delete(owned, state.options.allocator)
		n = mbLookupString(state.ic, event, &owned[0], i32(len(owned)), &keysym, &status)
		if n > 0 && int(n) <= len(owned) {
			emit_commit(state, owned[:int(n)], modifiers)
		}
		return
	}
	if n > 0 && int(n) <= len(buffer) {
		emit_commit(state, buffer[:int(n)], modifiers)
	}
}

commit_modifiers :: proc(event: ^xlib.XKeyEvent) -> input.Modifiers {
	modifiers: input.Modifiers
	if .ShiftMask in event.state {
		modifiers += {.Shift}
	}
	if .ControlMask in event.state {
		modifiers += {.Ctrl}
	}
	if .Mod1Mask in event.state {
		modifiers += {.Alt}
	}
	if .Mod4Mask in event.state {
		modifiers += {.Super}
	}
	return modifiers
}

emit_commit :: proc(state: ^State, text: []byte, modifiers: input.Modifiers) {
	if len(text) > state.options.max_bytes {
		report(state, errs.new(.Resource_Limit, "ime: X11 commit exceeds the text budget", allocator = state.options.allocator))
		return
	}
	if !utf8.valid_string(string(text)) {
		report(state, errs.new(.Invalid_Input, "ime: X11 commit is not valid UTF-8", allocator = state.options.allocator))
		return
	}
	notify(state, {kind = .Commit, text = text, modifiers = modifiers})
}
