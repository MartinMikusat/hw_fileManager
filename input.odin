package file_manager

import "core:strings"
import NS "core:sys/darwin/Foundation"
import text_input "components:text_input"

HISTORY_MAX :: 32
INPUT_FIELD :: text_input.Field_ID(2)

Input_Mode :: enum {
	None,
	Cd,
	Search,
	// The app typed in settings to open text files with.
	OpenWith,
	// The font family typed in settings.
	FontFamily,
}

// input_begin focuses the bottom-bar field for a cd query or a search.
input_begin :: proc(host: ^Host, mode: Input_Mode) {
	input_reset(host)
	host.input_mode = mode
	_ = text_input.focus(&host.text_state, INPUT_FIELD, host.input_value)
}

input_reset :: proc(host: ^Host) {
	if host.text_state.active_field == INPUT_FIELD {_ = text_input.blur(&host.text_state, &host.input_value)}
	if len(host.input_value) > 0 {delete(host.input_value, context.allocator)}
	host.input_value = ""
	host.input_mode = .None
	host.search_committed = false
	host.history_index = -1
	host.cd_completing = false
}

input_destroy :: proc(host: ^Host) {
	input_reset(host)
	for index in 0 ..< host.history_count {delete(host.history[index], context.allocator)}
	delete(host.draft, context.allocator)
	host.history_count = 0
	host.draft = ""
}

input_text :: proc(host: ^Host) -> string {
	return host.input_value
}

// input_set replaces the field text and puts the caret at its end.
input_set :: proc(host: ^Host, text: string) {
	text_input.replace_owned(&host.input_value, text)
	text_input.collapse_selection(&host.text_state, host.input_value, len(host.input_value))
	host.history_index = -1
}

// input_editing is true while the field takes caret, selection and word commands;
// a committed search uses the keys for navigation instead.
input_editing :: proc(host: ^Host) -> bool {
	return host.input_mode == .Cd || host.input_mode == .OpenWith || host.input_mode == .FontFamily || (host.input_mode == .Search && !host.search_committed)
}

// input_handle_key routes text-editing keys to the bar field.
input_handle_key :: proc(host: ^Host, event: ^NS.Event, key: uint, command, option, control, shift: bool) -> bool {
	if !field_handle_key(host, &host.input_value, event, key, command, option, control, shift) {return false}
	host.history_index = -1
	host.cd_completing = false
	return true
}

// input_history_push records a submitted query, newest first, dropping duplicates
// of the most recent entry.
input_history_push :: proc(host: ^Host) {
	if len(host.input_value) == 0 {return}
	if host.history_count > 0 && host.history[0] == host.input_value {return}
	if host.history_count == HISTORY_MAX {delete(host.history[HISTORY_MAX-1], context.allocator)}
	count := min(host.history_count+1, HISTORY_MAX)
	for index := count-1; index > 0; index -= 1 {host.history[index] = host.history[index-1]}
	host.history[0] = strings.clone(host.input_value, context.allocator)
	host.history_count = count
	host.history_index = -1
}

// input_history_move walks the history like a shell prompt: +1 is older, -1 is
// newer, and stepping past the newest restores the line being edited.
input_history_move :: proc(host: ^Host, delta: int) {
	if host.history_count == 0 {return}
	if host.history_index < 0 {text_input.replace_owned(&host.draft, host.input_value)}
	next := clamp(host.history_index+delta, -1, host.history_count-1)
	input_set(host, next < 0 ? host.draft : host.history[next])
	host.history_index = next
	host.cd_completing = false
}
