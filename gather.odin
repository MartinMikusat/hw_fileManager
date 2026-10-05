package file_manager

import "core:strings"
import ui "ui_framework:core"
import draw "ui_framework:draw"

// The gathered set is absolute paths in the order they were marked, session
// only. A folder and anything inside it are one operation, so the shallowest
// path wins.
gather_add :: proc(paths: ^[dynamic]string, path: string) {
	if path_list_contains(paths[:], path) {return}
	for index := len(paths)-1; index >= 0; index -= 1 {
		existing := paths[index]
		if strings.has_prefix(existing, strings.concatenate({path, "/"}, context.temp_allocator)) {
			delete(existing, context.allocator)
			ordered_remove(paths, index)
		} else if strings.has_prefix(path, strings.concatenate({existing, "/"}, context.temp_allocator)) {
			return
		}
	}
	append(paths, strings.clone(path, context.allocator))
}

gather_remove :: proc(paths: ^[dynamic]string, path: string) {
	for index in 0 ..< len(paths) {
		if paths[index] == path {
			delete(paths[index], context.allocator)
			ordered_remove(paths, index)
			return
		}
	}
}

gather_clear :: proc(paths: ^[dynamic]string) {
	for path in paths {delete(path, context.allocator)}
	clear(paths)
}

gather_destroy :: proc(paths: ^[dynamic]string) {
	gather_clear(paths)
	delete(paths^)
	paths^ = nil
}

// gather_remap follows an in-app rename or move of one entry, gathered children
// included.
gather_remap :: proc(paths: ^[dynamic]string, old, new: string) {
	prefix := strings.concatenate({old, "/"}, context.temp_allocator)
	for index in 0 ..< len(paths) {
		existing := paths[index]
		if existing == old {
			delete(existing, context.allocator)
			paths[index] = strings.clone(new, context.allocator)
		} else if strings.has_prefix(existing, prefix) {
			tail := existing[len(old):]
			delete(existing, context.allocator)
			paths[index] = strings.concatenate({new, tail}, context.allocator)
		}
	}
}

// gather_prune drops paths that no longer exist and returns how many.
gather_prune :: proc(paths: ^[dynamic]string) -> int {
	dropped := 0
	for index := len(paths)-1; index >= 0; index -= 1 {
		if !path_taken(paths[index]) {
			delete(paths[index], context.allocator)
			ordered_remove(paths, index)
			dropped += 1
		}
	}
	return dropped
}

Gather_Panel :: struct {
	panel:    draw.Rect,
	header:   draw.Rect,
	clear:    draw.Rect,
	rows:     [GATHER_PANEL_MAX_ROWS]draw.Rect,
	count:    int,
	overflow: int,
}

// gather_panel_layout pins the panel flush to the right edge above the action
// bar. It is top-origin like every other rect.
gather_panel_layout :: proc(metrics: View_Metrics, count: int) -> Gather_Panel {
	row := metrics.row_height
	width := f32(NAME_MAX_CHARS)*metrics.char_advance+2*column_pad
	shown := min(count, GATHER_PANEL_MAX_ROWS)
	height := f32(shown+1)*row
	if count > shown {height += row}
	top := metrics.height-metrics.bar_height-height
	panel := draw.Rect{metrics.width-width, top, width, height}
	clear_width := f32(len(action_label(.Clear)))*metrics.char_advance
	panel_hit := Gather_Panel{
		panel = panel,
		header = {panel.x, top, width, row},
		clear = {panel.x+width-column_pad-clear_width, top, clear_width, row},
		count = shown,
		overflow = count-shown,
	}
	for index in 0 ..< shown {
		panel_hit.rows[index] = {panel.x, top+row+f32(index)*row, width, row}
	}
	return panel_hit
}

// gather_panel_at returns a row index (clear = false) or the clear button
// (clear = true) under the point.
gather_panel_at :: proc(layout: Gather_Panel, point: ui.Vec2) -> (index: int, clear: bool, inside: bool) {
	if !rect_contains(layout.panel, point) {return -1, false, false}
	if rect_contains(layout.clear, point) {return -1, true, true}
	for row in 0 ..< layout.count {
		if rect_contains(layout.rows[row], point) {return row, false, true}
	}
	return -1, false, true
}

rect_contains :: proc(rect: draw.Rect, point: ui.Vec2) -> bool {
	return point.x >= rect.x && point.x < rect.x+rect.w && point.y >= rect.y && point.y < rect.y+rect.h
}
