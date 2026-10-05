package file_manager

import "base:intrinsics"
import "core:strings"
import NS "core:sys/darwin/Foundation"
import text_input "components:text_input"

// Cmd+E on a text preview opens it in the editor; Escape (or a click elsewhere)
// closes it, asking first when there are unsaved changes.

// textedit_begin opens the selected text file for editing, or says why it cannot be.
textedit_begin :: proc(window: ^Window) {
	if window.text_edit.active || !preview_text_shown(window) {return}
	entry, selected := tree_selected_entry(&window.tree)
	if !selected || entry.is_dir {return}
	if reason := textedit_open(&window.text_edit, entry.path); len(reason) > 0 {
		notice_set(window, reason)
		return
	}
	window.preview.focused = true
	textedit_reveal(window)
}

// textedit_end closes the editor and has the preview reload the file from disk.
textedit_end :: proc(window: ^Window) {
	textedit_free(&window.text_edit)
	window.preview.modified = {}
}

// textedit_leave ends editing and reports true, or raises the unsaved-changes
// prompt and reports false; `then` is what the prompt resumes.
textedit_leave :: proc(window: ^Window, then: Text_Edit_Then) -> bool {
	edit := &window.text_edit
	if !edit.active {return true}
	if edit.dirty {
		edit.prompt = .Leave
		edit.then = then
		edit.pending = true
		return false
	}
	textedit_end(window)
	return true
}

// textedit_resume carries on with what a Leave prompt interrupted.
textedit_resume :: proc(window: ^Window) {
	then := window.text_edit.then
	textedit_end(window)
	switch then {
	case .Exit:
	case .Close: window.ns_window->close()
	case .Quit:  app.application->terminate(nil)
	}
}

textedit_save_now :: proc(window: ^Window, force := false) {
	edit := &window.text_edit
	switch textedit_save(edit, force) {
	case .Saved:
		edit.prompt = .None
		if edit.pending {
			edit.pending = false
			textedit_resume(window)
		}
	case .Conflict:
		edit.prompt = .Conflict
	case .Failed:
		edit.prompt = .None
		edit.pending = false
		notice_set(window, "could not save")
	}
}

// textedit_reload discards the buffer and reads the file again.
textedit_reload :: proc(window: ^Window) {
	edit := &window.text_edit
	path := strings.clone(edit.path, context.temp_allocator)
	pending := edit.pending
	if pending {
		textedit_resume(window)
		return
	}
	if reason := textedit_open(edit, path); len(reason) > 0 {
		notice_set(window, reason)
		textedit_end(window)
	}
}

textedit_prompt_key :: proc(window: ^Window, key: uint) {
	edit := &window.text_edit
	switch edit.prompt {
	case .Leave:
		switch key {
		case 1:  textedit_save_now(window)
		case 2:  textedit_resume(window)
		case 53: edit.prompt = .None; edit.pending = false
		}
	case .Conflict:
		switch key {
		case 31: textedit_save_now(window, force = true)
		case 15: edit.prompt = .None; textedit_reload(window)
		case 53: edit.prompt = .None; edit.pending = false
		}
	case .None:
	}
}

// textedit_reveal scrolls so the caret is visible.
textedit_reveal :: proc(window: ^Window) {
	edit := &window.text_edit
	if !edit.active {return}
	text := textedit_text(edit)
	caret := textedit_caret(edit)
	line := textedit_line_of(edit, caret)
	rows := preview_rows(window)
	scroll := window.preview.scroll
	if f32(line) < scroll {scroll = f32(line)} else if f32(line) >= scroll+f32(rows) {scroll = f32(line-rows+1)}
	preview_scroll_to(window, scroll)
	area := view_preview_area(window.preview_rect)
	columns := max(int(area.w/window.char_advance), 1)
	column := textedit_column(text, edit.starts[line], caret)
	if column < edit.hscroll {
		edit.hscroll = max(column-4, 0)
	} else if column >= edit.hscroll+columns-1 {
		edit.hscroll = column-columns+2
	}
}

// textedit_move_vertical moves the caret by whole lines, holding the column
// the movement started from across shorter lines.
textedit_move_vertical :: proc(window: ^Window, lines: int, extend: bool) {
	edit := &window.text_edit
	text := textedit_text(edit)
	caret := textedit_caret(edit)
	line := textedit_line_of(edit, caret)
	target := clamp(line+lines, 0, textedit_line_count(edit)-1)
	if edit.goal < 0 {edit.goal = text_input.character_column_for_offset(text, edit.starts[line], caret)}
	destination: int
	switch {
	case target == line && lines < 0: destination = 0
	case target == line && lines > 0: destination = len(text)
	case:
		start, end := textedit_line_range(edit, target)
		destination = text_input.offset_for_character_column(text, start, end, edit.goal)
	}
	text_input.move_selection(&edit.state, text, destination, extend)
}

// textedit_key handles a key while the editor is open and reports whether it was used.
textedit_key :: proc(window: ^Window, event: ^NS.Event, key: uint, command, option, control, shift: bool) -> bool {
	edit := &window.text_edit
	if edit.prompt != .None {
		textedit_prompt_key(window, key)
		return true
	}
	if edit.state.has_marked_text {
		textedit_interpret(window, event)
		textedit_reveal(window)
		return true
	}
	state := &edit.state
	text := textedit_text(edit)
	goal := edit.goal
	edit.goal = -1
	switch {
	case command && key == 1:  textedit_save_now(window)
	case command && key == 6:  _ = textedit_undo(edit, shift)
	case command && key == 0:  text_input.set_selection(state, text, 0, len(text))
	case command && key == 8:  textedit_clipboard_copy(window)
	case command && key == 7:  textedit_clipboard_copy(window); textedit_delete_range(edit, textedit_selection(edit))
	case command && key == 9:  textedit_clipboard_paste(window)
	case key == 53:            _ = textedit_leave(window, .Exit)
	case key == 123:
		switch {
		case command: text_input.move_line_start(state, text, shift)
		case option:  text_input.move_word_left(state, text, shift)
		case:         text_input.move_left(state, text, shift)
		}
	case key == 124:
		switch {
		case command: text_input.move_line_end(state, text, shift)
		case option:  text_input.move_word_right(state, text, shift)
		case:         text_input.move_right(state, text, shift)
		}
	case key == 126:
		if command {text_input.move_selection(state, text, 0, shift)} else {edit.goal = goal; textedit_move_vertical(window, -1, shift)}
	case key == 125:
		if command {text_input.move_selection(state, text, len(text), shift)} else {edit.goal = goal; textedit_move_vertical(window, 1, shift)}
	case key == 115: text_input.move_selection(state, text, 0, shift)
	case key == 119: text_input.move_selection(state, text, len(text), shift)
	case key == 116: edit.goal = goal; textedit_move_vertical(window, -max(preview_rows(window)-1, 1), shift)
	case key == 121: edit.goal = goal; textedit_move_vertical(window, max(preview_rows(window)-1, 1), shift)
	case key == 51:
		if command {
			start, end := textedit_selection(edit)
			if start == end {start = text_input.line_start_for_offset(text, end)}
			textedit_delete_range(edit, start, end)
		} else {
			textedit_delete_backward(edit, option)
		}
	case key == 117: textedit_delete_forward(edit)
	case key == 36, key == 76: textedit_newline(edit)
	case key == 48: textedit_insert(edit, "\t")
	case command || control: return false
	case: textedit_interpret(window, event)
	}
	textedit_reveal(window)
	return true
}

// textedit_interpret hands a key to the input system, which answers through the
// NSTextInputClient methods: composed text, dead keys and input methods.
textedit_interpret :: proc(window: ^Window, event: ^NS.Event) {
	array := intrinsics.objc_send(^NS.Object, cast(^NS.Object)intrinsics.objc_find_class("NSArray"), "arrayWithObject:", event)
	intrinsics.objc_send(nil, window.view, "interpretKeyEvents:", array)
}

textedit_clipboard_copy :: proc(window: ^Window) {
	edit := &window.text_edit
	edit_clipboard_copy(window, textedit_text(edit))
}

textedit_clipboard_paste :: proc(window: ^Window) {
	pasteboard := edit_pasteboard()
	if pasteboard == nil {return}
	value := intrinsics.objc_send(^NS.String, pasteboard, "stringForType:", edit_nsstring("public.utf8-plain-text"))
	if value == nil {return}
	text := textedit_normalize_paste(NS.String_odinString(value))
	if len(text) > 0 && len(window.text_edit.buffer)+len(text) <= TEXTEDIT_MAX_BYTES {
		textedit_insert(&window.text_edit, text)
	}
}

// textedit_offset_at maps a point in the window to a byte offset in the buffer.
textedit_offset_at :: proc(window: ^Window, x, y: f32) -> int {
	edit := &window.text_edit
	area := view_preview_area(window.preview_rect)
	row := int((y-area.y)/window.tree.row_height+window.preview.scroll)
	line := clamp(row, 0, textedit_line_count(edit)-1)
	start, end := textedit_line_range(edit, line)
	column := (x-area.x)/window.char_advance+f32(edit.hscroll)
	return textedit_offset_at_column(textedit_text(edit), start, end, max(column, 0))
}

textedit_in_preview :: proc(window: ^Window, x, y: f32) -> bool {
	rect := window.preview_rect
	return window.preview_shown && x >= rect.x && x < rect.x+rect.w && y >= rect.y && y < rect.y+rect.h
}

// textedit_mouse_down places the caret, or selects a word (double click) or a
// line (triple click); with shift it extends the selection.
textedit_mouse_down :: proc(window: ^Window, x, y: f32, clicks: int, shift: bool) {
	edit := &window.text_edit
	if edit.prompt != .None {return}
	if edit.state.has_marked_text {textedit_commit_marked(edit, strings.clone(edit.state.marked_text, context.temp_allocator))}
	text := textedit_text(edit)
	offset := textedit_offset_at(window, x, y)
	edit.goal = -1
	edit.dragging = true
	switch {
	case clicks >= 3:
		line := textedit_line_of(edit, offset)
		start, end := textedit_line_range(edit, line)
		edit.drag_unit = .Line
		edit.drag_start, edit.drag_end = start, min(end+1, len(text))
		text_input.set_selection(&edit.state, text, edit.drag_start, edit.drag_end)
	case clicks == 2:
		edit.drag_unit = .Word
		edit.drag_start, edit.drag_end = text_input.word_bounds(text, offset)
		text_input.set_selection(&edit.state, text, edit.drag_start, edit.drag_end)
	case:
		edit.drag_unit = .Character
		if shift {
			edit.drag_start = edit.state.selection_anchor_byte
			edit.drag_end = edit.drag_start
			text_input.set_selection(&edit.state, text, edit.drag_start, offset)
		} else {
			edit.drag_start, edit.drag_end = offset, offset
			text_input.collapse_selection(&edit.state, text, offset)
		}
	}
	textedit_reveal(window)
}

textedit_mouse_dragged :: proc(window: ^Window, x, y: f32) {
	edit := &window.text_edit
	if !edit.dragging || edit.prompt != .None {return}
	area := view_preview_area(window.preview_rect)
	if y < area.y {preview_scroll_to(window, window.preview.scroll-1)} else if y > area.y+area.h {preview_scroll_to(window, window.preview.scroll+1)}
	text := textedit_text(edit)
	offset := textedit_offset_at(window, x, y)
	start, end := offset, offset
	switch edit.drag_unit {
	case .Character:
	case .Word:
		start, end = text_input.word_bounds(text, offset)
	case .Line:
		line_start, line_end := textedit_line_range(edit, textedit_line_of(edit, offset))
		start, end = line_start, min(line_end+1, len(text))
	}
	if offset < edit.drag_start {
		text_input.set_selection(&edit.state, text, edit.drag_end, start)
	} else {
		text_input.set_selection(&edit.state, text, edit.drag_start, end)
	}
}
