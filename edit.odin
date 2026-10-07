package file_manager

import "base:intrinsics"
import "core:os"
import "core:path/filepath"
import "core:strings"
import NS "core:sys/darwin/Foundation"
import text_input "components:text_input"
import devlog "devlog:."

EDIT_FIELD :: text_input.Field_ID(1)

Edit_Mode :: enum {
	None,
	Rename,
	NewFile,
	NewFolder,
}

View_Edit :: struct {
	active:          bool,
	column:          int,
	row:             int,
	text:            string,
	error:           bool,
	caret:           int,
	selection_start: int,
	selection_end:   int,
}

edit_text :: proc(host: ^Window) -> string {
	return host.edit_value
}

// edit_begin seeds the inline editor: the selected name for Rename, an empty name
// on the active column's first row for NewFile.
edit_begin :: proc(host: ^Window, mode: Edit_Mode) {
	edit_cancel(host)
	input_reset(host)
	initial := ""
	if mode == .Rename {
		entry, ok := tree_selected_entry(&host.tree)
		if !ok {return}
		host.edit_column = host.tree.active
		host.edit_row = host.tree.columns[host.tree.active].selected
		initial = entry.name
	} else {
		if host.tree.active < 0 || host.tree.active >= len(host.tree.columns) {return}
		host.edit_column = host.tree.active
		host.edit_row = 0
	}
	host.edit_value = strings.clone(initial, context.allocator)
	_ = text_input.focus(&host.text_state, EDIT_FIELD, host.edit_value)
	host.edit_mode = mode
}

edit_cancel :: proc(host: ^Window) {
	if host.text_state.active_field != text_input.NO_FIELD {
		_ = text_input.blur(&host.text_state, &host.edit_value)
	}
	if len(host.edit_value) > 0 {delete(host.edit_value, context.allocator)}
	host.edit_value = ""
	host.edit_mode = .None
}

edit_invalid :: proc(name: string) -> bool {
	if len(name) == 0 {return true}
	if name == "." || name == ".." {return true}
	for index in 0 ..< len(name) {
		if name[index] == '/' {return true}
	}
	return false
}

edit_stage :: proc(mode: Edit_Mode) -> string {
	switch mode {
	case .Rename:    return "rename"
	case .NewFolder: return "new_folder"
	case .NewFile, .None: return "new_file"
	}
	return "new_file"
}

// edit_target_directory is the folder the edit applies to. Rename uses the
// selected entry's own parent so it can never diverge from the entry; New file
// uses the active column.
edit_target_directory :: proc(host: ^Window) -> string {
	if host.edit_mode == .Rename {
		if entry, ok := tree_selected_entry(&host.tree); ok {return filepath.dir(entry.path)}
	}
	if host.edit_column >= 0 && host.edit_column < len(host.tree.columns) {return host.tree.columns[host.edit_column].dir}
	return ""
}

// edit_conflict reports whether the typed name already exists in the target
// directory, other than the entry being renamed.
edit_conflict :: proc(host: ^Window) -> bool {
	if host.edit_mode == .None {return false}
	name := host.edit_value
	if len(name) == 0 {return false}
	directory := edit_target_directory(host)
	if len(directory) == 0 {return false}
	original := ""
	if host.edit_mode == .Rename {
		if entry, ok := tree_selected_entry(&host.tree); ok {original = entry.path}
	}
	destination, _ := filepath.join([]string{directory, name}, context.temp_allocator)
	if destination == original || path_same_file(original, destination) {return false}
	if entry, ok := tree_selected_entry(&host.tree); ok && entry.path == destination {return true}
	if host.edit_column >= 0 && host.edit_column < len(host.tree.columns) {
		column := &host.tree.columns[host.edit_column]
		for entry in column.entries {
			if entry.path == destination {return true}
		}
	}
	return path_taken(destination)
}

edit_commit :: proc(host: ^Window) {
	if host.edit_mode == .None {return}
	name := strings.clone(host.edit_value, context.temp_allocator)
	mode := host.edit_mode
	if edit_invalid(name) {
		notice_set(host, "invalid name")
		return
	}
	if edit_conflict(host) {
		notice_set(host, "an item with that name already exists")
		return
	}
	directory := edit_target_directory(host)
	destination, join_error := filepath.join([]string{directory, name}, context.temp_allocator)
	if join_error != nil || len(destination) == 0 || destination[0] != '/' {
		devlog.failed(devlog.global(), {feature = "files", operation = "edit_name"}, {
			reason = "edit target path is invalid",
			severity = .Warning,
		})
		notice_set(host, "could not build the target path")
		return
	}
	original := ""
	if mode == .Rename {
		if entry, ok := tree_selected_entry(&host.tree); ok {original = entry.path}
	}
	applied := false
	rename_code := i32(0)
	switch mode {
	case .Rename:
		if destination == original {
			applied = true
		} else if rename_error := os.rename(original, destination); rename_error == nil {
			applied = true
		} else {
			rename_code = os_error_code(rename_error)
		}
	case .NewFile:
		if file, create_error := os.create(destination); create_error == nil {
			os.close(file)
			applied = true
		}
	case .NewFolder:
		if make_error := os.make_directory(destination); make_error == nil {applied = true}
	case .None:
	}
	if !applied {
		devlog.failed(devlog.global(), {feature = "files", operation = "edit_name"}, {
			reason = "name could not be applied",
			detail = filepath.base(directory),
			code = rename_code,
			severity = .Warning,
		})
		notice_set(host, "name could not be applied")
		return
	}
	devlog.succeeded(devlog.global(), {feature = "files", operation = "edit_name"}, {file_id = name, stage = edit_stage(mode)})
	if mode == .Rename {
		gather_remap(&host.gather_paths, original, destination)
		gather_remap(&app.clip_paths, original, destination)
	}
	column := host.edit_column
	edit_cancel(host)
	_ = tree_refresh(&host.tree)
	_ = tree_select_name(&host.tree, column, name)
}

edit_insertable :: proc(value: string) -> bool {
	if len(value) == 0 {return false}
	for rune in value {
		if rune < 32 || rune == 127 {return false}
		if rune >= 0xF700 && rune <= 0xF8FF {return false}
	}
	return true
}

// field_handle_key applies the shared text-field commands (insertion, caret,
// selection, word and line motion, deletion, clipboard) to target.
field_handle_key :: proc(host: ^Window, target: ^string, event: ^NS.Event, key: uint, command, option, control, shift: bool) -> bool {
	state := &host.text_state
	if !command && !control {
		if characters := event->characters(); characters != nil {
			if value := NS.String_odinString(characters); edit_insertable(value) {
				_ = text_input.remove_marked_text(state, target)
				_ = text_input.insert_text(state, target, value)
				return true
			}
		}
	}
	switch {
	case command && key == 0:
		text_input.set_selection(state, target^, 0, len(target^))
	case command && key == 8:
		edit_clipboard_copy(&host.text_state, target^)
	case command && key == 7:
		edit_clipboard_copy(&host.text_state, target^)
		_ = text_input.remove_selection(state, target)
	case command && key == 9:
		edit_clipboard_paste(host, target)
	case key == 123:
		switch {
		case command: text_input.move_line_start(state, target^, shift)
		case option:  text_input.move_word_left(state, target^, shift)
		case:         text_input.move_left(state, target^, shift)
		}
	case key == 124:
		switch {
		case command: text_input.move_line_end(state, target^, shift)
		case option:  text_input.move_word_right(state, target^, shift)
		case:         text_input.move_right(state, target^, shift)
		}
	case key == 125:
		text_input.move_line_end(state, target^, shift)
	case key == 126:
		text_input.move_line_start(state, target^, shift)
	case key == 115:
		text_input.move_line_start(state, target^, shift)
	case key == 119:
		text_input.move_line_end(state, target^, shift)
	case key == 51:
		if option {_ = text_input.delete_word_backward(state, target)} else {_ = text_input.delete_backward(state, target)}
	case key == 117:
		_ = text_input.delete_forward(state, target)
	case:
		return false
	}
	return true
}

// edit_handle_key adds Return and Escape to the shared field commands.
edit_handle_key :: proc(host: ^Window, event: ^NS.Event, key: uint, command, option, control, shift: bool) -> bool {
	if field_handle_key(host, &host.edit_value, event, key, command, option, control, shift) {return true}
	switch key {
	case 36, 76: edit_commit(host)
	case 53:     edit_cancel(host)
	case:        return false
	}
	return true
}

// os_error_code extracts the numeric errno/general code from an os.Error union
// for the dev log's failure records.
os_error_code :: proc(err: os.Error) -> i32 {
	#partial switch value in err {
	case os.Platform_Error: return i32(value)
	case os.General_Error:  return i32(value)
	}
	return 0
}

edit_nsstring :: proc(value: string) -> ^NS.String {
	cstring := strings.clone_to_cstring(value, context.temp_allocator)
	return intrinsics.objc_send(^NS.String, cast(^NS.Object)intrinsics.objc_find_class("NSString"), "stringWithUTF8String:", cstring)
}

edit_pasteboard :: proc() -> ^NS.Object {
	return intrinsics.objc_send(^NS.Object, cast(^NS.Object)intrinsics.objc_find_class("NSPasteboard"), "generalPasteboard")
}

edit_clipboard_copy :: proc(state: ^text_input.State, value: string) {
	selected := text_input.selected_text(state, value)
	if len(selected) == 0 {return}
	pasteboard := edit_pasteboard()
	if pasteboard == nil {return}
	_ = intrinsics.objc_send(i64, pasteboard, "clearContents")
	_ = intrinsics.objc_send(NS.BOOL, pasteboard, "setString:forType:", edit_nsstring(selected), edit_nsstring("public.utf8-plain-text"))
}

edit_clipboard_paste :: proc(host: ^Window, target: ^string) {
	pasteboard := edit_pasteboard()
	if pasteboard == nil {return}
	value := intrinsics.objc_send(^NS.String, pasteboard, "stringForType:", edit_nsstring("public.utf8-plain-text"))
	if value == nil {return}
	text := NS.String_odinString(value)
	if !edit_insertable(text) {return}
	_ = text_input.remove_marked_text(&host.text_state, target)
	_ = text_input.insert_text(&host.text_state, target, text)
}
