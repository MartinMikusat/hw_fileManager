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
}

action_paste :: proc(host: ^Host) {
	if len(host.clip_path) == 0 {return}
	if host.tree.active < 0 || host.tree.active >= len(host.tree.columns) {return}
	directory := host.tree.columns[host.tree.active].dir
	source := host.clip_path
	if host.clip_cut {
		if filepath.dir(source) == directory {
			action_clear_clip(host)
			return
		}
		destination, _ := filepath.join([]string{directory, filepath.base(source)}, context.temp_allocator)
		if os.exists(destination) {
			notice_set(host, "a file with that name already exists")
			return
		}
		if move_error := os.rename(source, destination); move_error != nil {
			devlog.failed(devlog.global(), {feature = "files", operation = "paste"}, {
				reason = "file could not be moved",
				detail = filepath.base(directory),
				code = os_error_code(move_error),
				severity = .Warning,
			})
			notice_set(host, "move failed")
			return
		}
		action_clear_clip(host)
		_ = tree_refresh(&host.tree)
		return
	}
	// Finder keeps copied items on the clipboard and duplicates them with a
	// " copy" suffix, including into the same folder.
	plain, _ := filepath.join([]string{directory, filepath.base(source)}, context.temp_allocator)
	destination := plain
	if os.exists(plain) {destination = action_unique_destination(directory, filepath.base(source))}
	if !action_copy_path(source, destination) {
		devlog.failed(devlog.global(), {feature = "files", operation = "paste"}, {
			reason = "file could not be copied",
			severity = .Warning,
		})
		notice_set(host, "copy failed")
		return
	}
	_ = tree_refresh(&host.tree)
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
		if !os.exists(candidate) {return candidate}
	}
}

action_clear_clip :: proc(host: ^Host) {
	if len(host.clip_path) > 0 {delete(host.clip_path, context.allocator)}
	host.clip_path = ""
}

action_copy_path :: proc(source, destination: string) -> bool {
	if os.is_dir(source) {
		if os.make_directory_all(destination) != nil {return false}
		handle, open_error := os.open(source)
		if open_error != nil {return false}
		defer os.close(handle)
		infos, read_error := os.read_dir(handle, -1, context.temp_allocator)
		if read_error != nil {return false}
		defer os.file_info_slice_delete(infos, context.temp_allocator)
		for info in infos {
			if info.name == "." || info.name == ".." {continue}
			child, _ := filepath.join([]string{destination, info.name}, context.temp_allocator)
			if !action_copy_path(info.fullpath, child) {return false}
		}
		return true
	}
	data, read_error := os.read_entire_file(source, context.temp_allocator)
	if read_error != nil {return false}
	return os.write_entire_file(destination, data) == nil
}
