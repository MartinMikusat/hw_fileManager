package file_manager

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import devlog "devlog:."
import ui "ui_framework:core"
import draw "ui_framework:draw"

Action_Kind :: enum {
	Copy,
	Cut,
	Paste,
	Rename,
	NewFile,
}

ACTION_LABELS := [5]string{"[1 Copy]", "[2 Cut]", "[3 Paste]", "[4 Rename]", "[5 New File]"}

action_label :: proc(kind: Action_Kind) -> string {
	return ACTION_LABELS[int(kind)]
}

action_number_key_code :: proc(key: uint) -> (Action_Kind, bool) {
	switch key {
	case 18: return .Copy, true
	case 19: return .Cut, true
	case 20: return .Paste, true
	case 21: return .Rename, true
	case 23: return .NewFile, true
	}
	return .Copy, false
}

action_available :: proc(tree: ^Tree, clip_path: string, kind: Action_Kind) -> bool {
	switch kind {
	case .Copy, .Cut, .Rename:
		_, ok := tree_selected_entry(tree)
		return ok
	case .Paste:
		return len(clip_path) > 0
	case .NewFile:
		return tree.active >= 0 && tree.active < len(tree.columns)
	}
	return false
}

// action_bar_rects are top-origin, in the bottom row of the bar.
action_bar_rects :: proc(metrics: View_Metrics) -> [5]draw.Rect {
	rects: [5]draw.Rect
	top := metrics.height-metrics.row_height
	x := COLUMN_PAD
	for kind in Action_Kind {
		width := f32(len(action_label(kind)))*metrics.char_advance
		rects[int(kind)] = {x, top, width, metrics.row_height}
		x += width+ACTION_GAP_CELLS*metrics.char_advance
	}
	return rects
}

action_bar_at :: proc(metrics: View_Metrics, point: ui.Vec2) -> (Action_Kind, bool) {
	top := metrics.height-metrics.row_height
	if point.y < top || point.y >= top+metrics.row_height {return .Copy, false}
	rects := action_bar_rects(metrics)
	for kind in Action_Kind {
		rect := rects[int(kind)]
		if point.x >= rect.x && point.x < rect.x+rect.w {return kind, true}
	}
	return .Copy, false
}

action_perform :: proc(host: ^Host, kind: Action_Kind) {
	if !action_available(&host.tree, host.clip_path, kind) {return}
	switch kind {
	case .Copy:    action_clip(host, false)
	case .Cut:     action_clip(host, true)
	case .Paste:   action_paste(host)
	case .Rename:  edit_begin(host, .Rename)
	case .NewFile: edit_begin(host, .NewFile)
	}
	host_request_frames(2)
}

// action_clip marks the selection for a Cut (a pending move, drawn red). Copy is
// silent like Finder's, and Paste duplicates.
action_clip :: proc(host: ^Host, cut: bool) {
	entry, ok := tree_selected_entry(&host.tree)
	if !ok {return}
	if len(host.clip_path) > 0 {delete(host.clip_path, context.allocator)}
	host.clip_path = strings.clone(entry.path, context.allocator)
	host.clip_cut = cut
	devlog.succeeded(devlog.global(), {feature = "files", operation = "clip"}, {file_id = entry.name, stage = cut ? "cut" : "copy"})
}

action_paste :: proc(host: ^Host) {
	if len(host.clip_path) == 0 {return}
	directory, has_target := action_paste_directory(&host.tree)
	if !has_target {return}
	source := host.clip_path
	site := devlog.Site{feature = "files", operation = "paste"}
	stage := host.clip_cut ? "move" : "copy"
	file_id := filepath.base(source)
	if directory == source || strings.has_prefix(directory, strings.concatenate({source, "/"}, context.temp_allocator)) {
		devlog.failed(devlog.global(), site, {reason = "folder cannot be pasted into itself", severity = .Info}, {file_id = file_id, stage = stage})
		notice_set(host, "cannot paste a folder into itself")
		return
	}
	if host.clip_cut && filepath.dir(source) == directory {
		action_clear_clip(host)
		return
	}
	plain, _ := filepath.join([]string{directory, file_id}, context.temp_allocator)
	destination := plain
	if path_taken(plain) {
		if host.clip_cut {
			devlog.failed(devlog.global(), site, {reason = "destination name already exists", severity = .Info}, {file_id = file_id, stage = stage})
			notice_set(host, "a file with that name already exists")
			return
		}
		// Finder keeps copied items on the clipboard and duplicates them with a
		// " copy" suffix, including into the same folder.
		destination = action_unique_destination(directory, file_id)
	}
	devlog.started(devlog.global(), site, {file_id = file_id, stage = stage})
	paste_code: i32
	if host.clip_cut {
		paste_code = action_move(source, destination)
	} else {
		paste_code = copy_item(source, destination)
	}
	if paste_code != 0 {
		devlog.failed(devlog.global(), site, {
			reason = host.clip_cut ? "file could not be moved" : "file could not be copied",
			detail = filepath.base(directory),
			code = paste_code,
			severity = .Warning,
		}, {file_id = file_id, stage = stage})
		notice_set(host, host.clip_cut ? "move failed" : "copy failed")
		return
	}
	devlog.succeeded(devlog.global(), site, {file_id = file_id, stage = stage})
	if host.clip_cut {action_clear_clip(host)}
	_ = tree_refresh(&host.tree)
}

// action_paste_directory is the folder shown at the right edge of the cascade: the
// selected entry when it is a folder (its preview column), else the active column.
action_paste_directory :: proc(tree: ^Tree) -> (string, bool) {
	if tree.active < 0 || tree.active >= len(tree.columns) {return "", false}
	if entry, ok := tree_selected_entry(tree); ok && entry.is_dir {return entry.path, true}
	return tree.columns[tree.active].dir, true
}

// action_unique_destination mirrors Finder: "name copy.ext", then
// "name copy 2.ext".
action_unique_destination :: proc(directory, name: string) -> string {
	base, extension := name, ""
	if dot := strings.last_index_byte(name, '.'); dot > 0 {
		base, extension = name[:dot], name[dot:]
	}
	for index := 1; ; index += 1 {
		suffix := index == 1 ? " copy" : fmt.tprintf(" copy %d", index)
		name_with_suffix := strings.concatenate({base, suffix, extension}, context.temp_allocator)
		candidate, _ := filepath.join([]string{directory, name_with_suffix}, context.temp_allocator)
		if !path_taken(candidate) {return candidate}
	}
}

action_clear_clip :: proc(host: ^Host) {
	if len(host.clip_path) > 0 {delete(host.clip_path, context.allocator)}
	host.clip_path = ""
}

// action_move renames, falling back to copy-then-remove across volumes. It
// returns 0 or an errno.
action_move :: proc(source, destination: string) -> i32 {
	move_error := os.rename(source, destination)
	if move_error == nil {return 0}
	code := os_error_code(move_error)
	if code != EXDEV {return code}
	if copy_code := copy_item(source, destination); copy_code != 0 {
		_ = os.remove_all(destination)
		return copy_code
	}
	if os.remove_all(source) != nil {return EXDEV}
	return 0
}
