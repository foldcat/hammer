package main

import editing "core/editing"
import platform "platform"
import tagstate "core/tag"

editor_cancel_tag_requests :: proc(tag: ^tagstate.State) {
	if tag == nil {
		return
	}
	if tag.delayed_paste.pending {
		request_id := platform.Clipboard_Request_ID(tag.delayed_paste.target.request_id)
		if services.clipboard.cancel != nil {
			services.clipboard.cancel(services.user, request_id)
		}
		editor_report(editing.delayed_paste_cancel(&tag.delayed_paste, u64(request_id)))
	}
	if tag.delayed_cut.pending {
		request_id := tag.delayed_cut.target.request_id
		editor_report(editing.delayed_cut_cancel(&tag.delayed_cut, request_id))
	}
}
