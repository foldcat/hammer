package platform

import errs "../core/errs"

IME_Event_Kind :: enum u8 {
	Preedit,
	Preedit_Caret,
	Preedit_Done,
	Commit,
	Error,
}

// IME_Event text and err are borrowed only during notify. Preedit caret is a
// Unicode scalar index. Commit contains one complete, possibly multi-scalar,
// UTF-8 commit; it must not also be emitted as ordinary character events.
IME_Event :: struct {
	kind:   IME_Event_Kind,
	text:   []byte,
	caret:  int,
	err:    errs.Error,
}

IME_Service :: struct {
	notify: proc(user: rawptr, event: IME_Event),
}
