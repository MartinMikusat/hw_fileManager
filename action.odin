package file_manager

import "core:os"
import "core:path/filepath"
import "core:strings"
import devlog "devlog:."
import ui "ui_framework:core"
import draw "ui_framework:draw"

Action_Kind :: enum {
	Copy,
	Paste,
	Rename,
	NewFile,
}

ACTION_LABELS := [4]string{"[1 Copy]", "[2 Paste]", "[3 Rename]", "[4 New File]"}

action_label :: proc(kind: Action_Kind) -> string {
	return ACTION_LABELS[int(kind)]
}

action_number_key_code :: proc(key: uint) -> (Action_Kind, bool) {
	switch key {
	case 18: return .Copy, true
	case 19: return .Paste, true
	case 20: return .Rename, true
	case 21: return .NewFile, true
	}
	return .Copy, false
}

action_available :: proc(tree: ^Tree, copy_path: string, kind: Action_Kind) -> bool {
	switch kind {
	case .Copy, .Rename:
		_, ok := tree_selected_entry(tree)
		return ok
	case .Paste:
		return len(copy_path) > 0
	case .NewFile:
		return tree.active >= 0 && tree.active < len(tree.columns)
	}
	return false
}

// action_bar_rects are top-origin, in the bottom row of the bar.
action_bar_rects :: proc(metrics: View_Metrics) -> [4]draw.Rect {
	rects: [4]draw.Rect
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
	if !action_available(&host.tree, host.copy_path, kind) {return}
	switch kind {
	case .Copy:    action_copy(host)
	case .Paste:   action_paste(host)
	case .Rename:  edit_begin(host, .Rename)
	case .NewFile: edit_begin(host, .NewFile)
	}
	host_request_frames(2)
}

// Copy marks the selection red; Paste moves it into the active column's folder.
action_copy :: proc(host: ^Host) {
	entry, ok := tree_selected_entry(&host.tree)
	if !ok {return}
	if len(host.copy_path) > 0 {delete(host.copy_path, context.allocator)}
	host.copy_path = strings.clone(entry.path, context.allocator)
}

action_paste :: proc(host: ^Host) {
	if len(host.copy_path) == 0 {return}
	if host.tree.active < 0 || host.tree.active >= len(host.tree.columns) {return}
	directory := host.tree.columns[host.tree.active].dir
	if filepath.dir(host.copy_path) == directory {
		delete(host.copy_path, context.allocator)
		host.copy_path = ""
		return
	}
	destination, _ := filepath.join([]string{directory, filepath.base(host.copy_path)}, context.temp_allocator)
	if move_error := os.rename(host.copy_path, destination); move_error != nil {
		devlog.failed(devlog.global(), {feature = "files", operation = "paste"}, {
			reason = "file could not be moved",
			severity = .Warning,
		})
	} else {
		_ = tree_refresh(&host.tree)
	}
	delete(host.copy_path, context.allocator)
	host.copy_path = ""
}
