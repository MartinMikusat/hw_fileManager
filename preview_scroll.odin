package file_manager

// A text preview scrolls on its own: Enter (or the right arrow) moves the focus
// into it, the arrow, page and home/end keys then move through the file, and
// Escape, the left or right arrow or Enter hand the focus back to the tree. The wheel
// scrolls it whenever the pointer is over it.

preview_text_shown :: proc(host: ^Window) -> bool {
	return host.preview_shown && host.preview.kind == .Text
}

preview_rows :: proc(host: ^Window) -> int {
	area_height := host.preview_rect.h-2*COLUMN_PAD
	return max(int(area_height/host.tree.row_height), 1)
}

preview_scroll_to :: proc(host: ^Window, line: f32) {
	limit := f32(max(len(host.preview.lines)-preview_rows(host), 0))
	host.preview.scroll = clamp(line, 0, limit)
}

// preview_focus_begin focuses the preview of the selected file; it reports false
// when there is none to focus or all of it already fits.
preview_focus_begin :: proc(host: ^Window) -> bool {
	if !preview_text_shown(host) || len(host.preview.lines) <= preview_rows(host) {return false}
	host.preview.focused = true
	return true
}

// preview_handle_key scrolls for a key while the preview has the focus and
// reports whether the key was used.
preview_handle_key :: proc(host: ^Window, key: uint) -> bool {
	if !host.preview.focused {return false}
	rows := preview_rows(host)
	page := f32(max(rows-1, 1))
	switch key {
	case 126: preview_scroll_to(host, host.preview.scroll-1)
	case 125: preview_scroll_to(host, host.preview.scroll+1)
	case 116: preview_scroll_to(host, host.preview.scroll-page)
	case 121, 49: preview_scroll_to(host, host.preview.scroll+page)
	case 115: preview_scroll_to(host, 0)
	case 119: preview_scroll_to(host, f32(len(host.preview.lines)))
	case 123, 124, 53, 36, 76: host.preview.focused = false
	case: return false
	}
	return true
}

// preview_scroll_wheel scrolls by a wheel or trackpad delta (points when precise,
// otherwise wheel lines) when the pointer is over the text preview.
preview_scroll_wheel :: proc(host: ^Window, point_x, point_y, delta: f32, precise: bool) -> bool {
	if !preview_text_shown(host) {return false}
	rect := host.preview_rect
	if point_x < rect.x || point_x >= rect.x+rect.w || point_y < rect.y || point_y >= rect.y+rect.h {return false}
	lines := precise ? delta/host.tree.row_height : delta*3
	preview_scroll_to(host, host.preview.scroll-lines)
	return true
}
