package file_manager

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
import text_input "components:text_input"
import devlog "devlog:."

// COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR: everything but the data.
COPYFILE_METADATA :: u32(7)

TEXTEDIT_FIELD :: text_input.Field_ID(2)
TEXTEDIT_MAX_BYTES :: 8*1024*1024
TEXTEDIT_UNDO_MAX :: 10000
TEXTEDIT_BOM :: "\xEF\xBB\xBF"

Text_Edit_Prompt :: enum {
	None,
	Leave,
	Conflict,
}

// Text_Edit_Then is what a Leave prompt resumes once it is answered.
Text_Edit_Then :: enum {
	Exit,
	Close,
	Quit,
}

// Text_Edit_Change is one undoable replacement of removed by inserted at position.
Text_Edit_Change :: struct {
	position:      int,
	removed:       string,
	inserted:      string,
	caret_before:  int,
	anchor_before: int,
	caret_after:   int,
	typing:        bool,
}

// Text_Edit is the editor of a text preview. The buffer is the file with LF line
// endings and no BOM; both are restored on save. Selection and caret live in
// state as byte offsets into it.
Text_Edit :: struct {
	active:   bool,
	path:     string,
	buffer:   [dynamic]u8,
	kinds:    []Syntax_Kind,
	language: Language,
	// starts holds the byte offset of every line; both it and kinds are rebuilt
	// lazily by textedit_sync after edits.
	starts:   [dynamic]int,
	stale:    bool,
	crlf:     bool,
	bom:      bool,
	dirty:    bool,
	modified: time.Time,
	state:    text_input.State,
	undo:     [dynamic]Text_Edit_Change,
	redo:     [dynamic]Text_Edit_Change,
	hscroll:  int,
	prompt:   Text_Edit_Prompt,
	then:     Text_Edit_Then,
	// pending: a Leave prompt is being resolved, so `then` resumes once saved or discarded.
	pending:  bool,
	// goal is the column vertical movement aims for; -1 until a vertical move sets it.
	goal:     int,
	dragging: bool,
	// Anchor range of the click that started a drag, and its granularity.
	drag_start: int,
	drag_end:   int,
	drag_unit:  Text_Edit_Unit,
}

Text_Edit_Unit :: enum {
	Character,
	Word,
	Line,
}

textedit_text :: proc(edit: ^Text_Edit) -> string {
	return string(edit.buffer[:])
}

textedit_change_free :: proc(change: Text_Edit_Change) {
	delete(change.removed)
	delete(change.inserted)
}

textedit_history_clear :: proc(history: ^[dynamic]Text_Edit_Change) {
	for change in history {textedit_change_free(change)}
	clear(history)
}

textedit_free :: proc(edit: ^Text_Edit) {
	delete(edit.path)
	delete(edit.buffer)
	delete(edit.kinds)
	delete(edit.starts)
	textedit_history_clear(&edit.undo)
	textedit_history_clear(&edit.redo)
	delete(edit.undo)
	delete(edit.redo)
	text_input.destroy(&edit.state)
	edit^ = {}
}

// textedit_decode turns file bytes into editor text, or says why the file is not
// editable. A file with mixed or lone carriage returns is refused: converting it
// would change bytes the user never touched.
textedit_decode :: proc(data: []u8) -> (text: [dynamic]u8, bom, crlf: bool, reason: string) {
	if len(data) > TEXTEDIT_MAX_BYTES {return nil, false, false, "file is larger than 8 MB"}
	body := data
	if len(body) >= 3 && string(body[:3]) == TEXTEDIT_BOM {
		bom = true
		body = body[3:]
	}
	returns, newlines, pairs := 0, 0, 0
	for value, index in body {
		switch value {
		case 0:
			return nil, false, false, "file is binary"
		case '\r':
			returns += 1
			if index+1 < len(body) && body[index+1] == '\n' {pairs += 1}
		case '\n':
			newlines += 1
		}
	}
	if !utf8.valid_string(string(body)) {return nil, false, false, "file is not valid UTF-8"}
	if returns > 0 && (returns != pairs || newlines != pairs) {return nil, false, false, "file mixes line endings"}
	crlf = returns > 0
	text = make([dynamic]u8, 0, len(body)+len(body)/8+64)
	for index := 0; index < len(body); index += 1 {
		if crlf && body[index] == '\r' {continue}
		append(&text, body[index])
	}
	return text, bom, crlf, ""
}

// textedit_encode is the file content for the buffer: the original line ending
// and BOM restored.
textedit_encode :: proc(edit: ^Text_Edit, allocator := context.allocator) -> []u8 {
	text := textedit_text(edit)
	builder := make([dynamic]u8, 0, len(text)+len(text)/16+8, allocator)
	if edit.bom {append(&builder, TEXTEDIT_BOM)}
	for index in 0 ..< len(text) {
		if edit.crlf && text[index] == '\n' {append(&builder, '\r')}
		append(&builder, text[index])
	}
	return builder[:]
}

// textedit_open reads the file into the editor, or returns why it cannot be edited.
textedit_open :: proc(edit: ^Text_Edit, path: string) -> (reason: string) {
	info, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil {return "file could not be read"}
	if info.size > TEXTEDIT_MAX_BYTES {return "file is larger than 8 MB"}
	if posix.access(strings.clone_to_cstring(path, context.temp_allocator), {.W_OK}) != .OK {return "file is read-only"}
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {return "file could not be read"}
	text, bom, crlf, why := textedit_decode(data)
	if len(why) > 0 {return why}
	textedit_free(edit)
	edit.active = true
	edit.path = strings.clone(path)
	edit.buffer = text
	edit.bom, edit.crlf = bom, crlf
	edit.modified = info.modification_time
	edit.language = highlight_language(filepath.base(path))
	edit.stale = true
	edit.goal = -1
	_ = text_input.focus(&edit.state, TEXTEDIT_FIELD, "")
	text_input.collapse_selection(&edit.state, "", 0)
	textedit_sync(edit)
	return ""
}

// textedit_sync rebuilds the line index and syntax kinds after edits.
textedit_sync :: proc(edit: ^Text_Edit) {
	if !edit.stale {return}
	edit.stale = false
	text := textedit_text(edit)
	clear(&edit.starts)
	append(&edit.starts, 0)
	for index in 0 ..< len(text) {
		if text[index] == '\n' {append(&edit.starts, index+1)}
	}
	delete(edit.kinds)
	edit.kinds = highlight_kinds(edit.language, text)
}

textedit_line_count :: proc(edit: ^Text_Edit) -> int {
	textedit_sync(edit)
	return len(edit.starts)
}

// textedit_line_of returns the index of the line holding the byte offset.
textedit_line_of :: proc(edit: ^Text_Edit, offset: int) -> int {
	textedit_sync(edit)
	low, high := 0, len(edit.starts)-1
	for low < high {
		middle := (low+high+1)/2
		if edit.starts[middle] <= offset {low = middle} else {high = middle-1}
	}
	return low
}

// textedit_line_range is the byte range of a line without its newline.
textedit_line_range :: proc(edit: ^Text_Edit, line: int) -> (start, end: int) {
	textedit_sync(edit)
	start = edit.starts[line]
	end = line+1 < len(edit.starts) ? edit.starts[line+1]-1 : len(edit.buffer)
	return
}

// textedit_replace swaps buffer[start:end] for value without touching history or
// the selection.
textedit_replace :: proc(edit: ^Text_Edit, start, end: int, value: string) {
	removed := end-start
	if removed == 0 && len(value) == 0 {return}
	if len(value) > removed {
		extra := len(value)-removed
		old := len(edit.buffer)
		resize(&edit.buffer, old+extra)
		copy(edit.buffer[end+extra:], edit.buffer[end:old])
	} else if len(value) < removed {
		copy(edit.buffer[start+len(value):], edit.buffer[end:])
		resize(&edit.buffer, len(edit.buffer)-(removed-len(value)))
	}
	copy(edit.buffer[start:], value)
	edit.stale = true
}

textedit_selection :: proc(edit: ^Text_Edit) -> (start, end: int) {
	return text_input.selection_bounds(&edit.state, textedit_text(edit))
}

textedit_caret :: proc(edit: ^Text_Edit) -> int {
	return text_input.clamp_byte_offset(textedit_text(edit), edit.state.caret_byte_offset)
}

textedit_collapse :: proc(edit: ^Text_Edit, offset: int) {
	text_input.collapse_selection(&edit.state, textedit_text(edit), offset)
}

// textedit_apply replaces [start, end) by value, records the change for undo and
// leaves the caret after the insertion. typing marks a keystroke that may merge
// with the previous one.
textedit_apply :: proc(edit: ^Text_Edit, start, end: int, value: string, typing := false) {
	if start == end && len(value) == 0 {return}
	change := Text_Edit_Change{
		position = start,
		removed = strings.clone(string(edit.buffer[start:end])),
		inserted = strings.clone(value),
		caret_before = edit.state.caret_byte_offset,
		anchor_before = edit.state.selection_anchor_byte,
		caret_after = start+len(value),
		typing = typing,
	}
	textedit_replace(edit, start, end, value)
	textedit_collapse(edit, start+len(value))
	edit.dirty = true
	textedit_history_clear(&edit.redo)
	if count := len(edit.undo); count > 0 && textedit_merges(&edit.undo[count-1], change) {
		last := &edit.undo[count-1]
		merged := strings.concatenate({last.inserted, change.inserted})
		delete(last.inserted)
		last.inserted = merged
		last.caret_after = change.caret_after
		delete(change.removed)
		delete(change.inserted)
		return
	}
	if len(edit.undo) >= TEXTEDIT_UNDO_MAX {
		textedit_change_free(edit.undo[0])
		ordered_remove(&edit.undo, 0)
	}
	append(&edit.undo, change)
}

// textedit_merges reports that next continues the typing run last started: it
// follows directly, and a space or newline after a word begins a new run.
textedit_merges :: proc(last: ^Text_Edit_Change, next: Text_Edit_Change) -> bool {
	if !last.typing || !next.typing || len(next.removed) > 0 || len(last.removed) > 0 {return false}
	if next.position != last.position+len(last.inserted) {return false}
	previous := last.inserted[len(last.inserted)-1]
	current := next.inserted[0]
	if previous == '\n' || current == '\n' {return false}
	return (previous == ' ' || previous == '\t') == (current == ' ' || current == '\t')
}

// textedit_insert types or pastes value over the selection.
textedit_insert :: proc(edit: ^Text_Edit, value: string) {
	start, end := textedit_selection(edit)
	textedit_apply(edit, start, end, value, typing = len(value) <= 4 && start == end)
}

textedit_delete_range :: proc(edit: ^Text_Edit, start, end: int) {
	textedit_apply(edit, start, end, "")
}

textedit_delete_backward :: proc(edit: ^Text_Edit, word: bool) {
	start, end := textedit_selection(edit)
	if start == end {
		text := textedit_text(edit)
		start = word ? text_input.previous_word_offset(text, end) : text_input.previous_character_offset(text, end)
	}
	textedit_delete_range(edit, start, end)
}

textedit_delete_forward :: proc(edit: ^Text_Edit) {
	start, end := textedit_selection(edit)
	if start == end {end = text_input.next_character_offset(textedit_text(edit), end)}
	textedit_delete_range(edit, start, end)
}

// textedit_indent returns the leading whitespace of the caret's line, which a
// new line repeats.
textedit_indent :: proc(edit: ^Text_Edit) -> string {
	text := textedit_text(edit)
	start := text_input.line_start_for_offset(text, textedit_caret(edit))
	end := start
	for end < len(text) && (text[end] == ' ' || text[end] == '\t') {end += 1}
	return text[start:min(end, textedit_caret(edit))]
}

textedit_newline :: proc(edit: ^Text_Edit) {
	value := strings.concatenate({"\n", textedit_indent(edit)}, context.temp_allocator)
	start, end := textedit_selection(edit)
	textedit_apply(edit, start, end, value)
}

// textedit_undo reverts the latest change, or reapplies it from the redo list.
textedit_undo :: proc(edit: ^Text_Edit, redo: bool) -> bool {
	source := redo ? &edit.redo : &edit.undo
	target := redo ? &edit.undo : &edit.redo
	if len(source) == 0 {return false}
	change := pop(source)
	if redo {
		textedit_replace(edit, change.position, change.position+len(change.removed), change.inserted)
		textedit_collapse(edit, change.caret_after)
	} else {
		textedit_replace(edit, change.position, change.position+len(change.inserted), change.removed)
		text_input.set_selection(&edit.state, textedit_text(edit), change.anchor_before, change.caret_before)
	}
	change.typing = false
	append(target, change)
	edit.dirty = true
	return true
}

// textedit_marked_clear drops the composition without touching the text.
textedit_marked_clear :: proc(edit: ^Text_Edit) {
	text_input.clear_marked_text(&edit.state)
}

// textedit_marked_remove deletes the composed text, which was never recorded.
textedit_marked_remove :: proc(edit: ^Text_Edit) {
	state := &edit.state
	if !state.has_marked_text {return}
	start := state.marked_start_byte
	end := min(start+len(state.marked_text), len(edit.buffer))
	textedit_replace(edit, start, end, "")
	textedit_collapse(edit, start)
	textedit_marked_clear(edit)
}

// textedit_set_marked replaces the composition by value. selected is the UTF-16
// range the input method wants selected inside it, or location < 0.
textedit_set_marked :: proc(edit: ^Text_Edit, value: string, location, length: int) {
	state := &edit.state
	if !state.has_marked_text {
		start, end := textedit_selection(edit)
		if start != end {textedit_delete_range(edit, start, end)}
	} else {
		textedit_marked_remove(edit)
	}
	start := textedit_caret(edit)
	textedit_replace(edit, start, start, value)
	state.marked_text = strings.clone(value)
	state.marked_start_byte = start
	state.has_marked_text = true
	textedit_collapse(edit, start+len(value))
	if location >= 0 {
		first := text_input.byte_offset_for_utf16_index(value, location)
		last := text_input.byte_offset_for_utf16_index(value, location+max(length, 0))
		text_input.set_selection(state, textedit_text(edit), start+first, start+last)
	}
	edit.dirty = true
}

// textedit_commit_marked finishes a composition with value as the final text.
textedit_commit_marked :: proc(edit: ^Text_Edit, value: string) {
	if edit.state.has_marked_text {
		start := edit.state.marked_start_byte
		textedit_marked_remove(edit)
		textedit_collapse(edit, start)
	}
	textedit_insert(edit, value)
}

// textedit_normalize_paste converts pasted line endings to LF and drops NULs.
textedit_normalize_paste :: proc(value: string) -> string {
	builder := make([dynamic]u8, 0, len(value), context.temp_allocator)
	for index := 0; index < len(value); index += 1 {
		switch value[index] {
		case 0:
		case '\r':
			append(&builder, '\n')
			if index+1 < len(value) && value[index+1] == '\n' {index += 1}
		case:
			append(&builder, value[index])
		}
	}
	return string(builder[:])
}

Text_Edit_Save :: enum {
	Saved,
	Conflict,
	Failed,
}

// textedit_modified_on_disk reads the file's current modification time.
textedit_modified_on_disk :: proc(path: string) -> (time.Time, bool) {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {return {}, false}
	return info.modification_time, true
}

// textedit_save writes the buffer atomically: a temp file beside the target takes
// the original's mode, owner, ACL and extended attributes, receives the content
// and replaces the target by rename. A target that changed on disk since it was
// read is reported as a conflict unless force.
textedit_save :: proc(edit: ^Text_Edit, force: bool) -> Text_Edit_Save {
	site := devlog.Site{feature = "files", operation = "save_text"}
	target := edit.path
	if resolved := posix.realpath(strings.clone_to_cstring(edit.path, context.temp_allocator)); resolved != nil {
		target = strings.clone_from_cstring(resolved, context.temp_allocator)
		posix.free(rawptr(resolved))
	}
	if current, ok := textedit_modified_on_disk(target); ok && current != edit.modified && !force {return .Conflict}
	temp := strings.concatenate({target, ".hwfm-save"}, context.temp_allocator)
	temp_c := strings.clone_to_cstring(temp, context.temp_allocator)
	target_c := strings.clone_to_cstring(target, context.temp_allocator)
	descriptor := posix.open(temp_c, {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR})
	if descriptor < 0 {
		devlog.failed(devlog.global(), site, {reason = "temp file could not be created", severity = .Warning})
		return .Failed
	}
	_ = copyfile(target_c, temp_c, nil, COPYFILE_METADATA)
	data := textedit_encode(edit, context.temp_allocator)
	written := 0
	for written < len(data) {
		count := posix.write(descriptor, raw_data(data[written:]), uint(len(data))-uint(written))
		if count <= 0 {break}
		written += count
	}
	synced := written == len(data) && posix.fsync(descriptor) == .OK
	posix.close(descriptor)
	if !synced || posix.rename(temp_c, target_c) != 0 {
		posix.unlink(temp_c)
		devlog.failed(devlog.global(), site, {reason = "text could not be written", severity = .Warning})
		return .Failed
	}
	if current, ok := textedit_modified_on_disk(target); ok {edit.modified = current}
	edit.dirty = false
	devlog.succeeded(devlog.global(), site, {file_id = filepath.base(target)})
	return .Saved
}
