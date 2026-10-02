package file_manager

import coretext "ui_framework:coretext"
import ui "ui_framework:core"
import draw "ui_framework:draw"

View_Metrics :: struct {
	width:        f32,
	height:       f32,
	char_advance: f32,
}

Hot_State :: struct {
	control: int,
}

view_column_width :: proc(column: ^Column, char_advance: f32) -> f32 {
	longest := 0
	for entry in column.entries {longest = max(longest, len(entry.name))}
	return max(f32(longest)*char_advance+2*COLUMN_PAD, MIN_COLUMN_WIDTH)
}

view_content_width :: proc(tree: ^Tree) -> f32 {
	total := COLUMN_PAD
	for column in tree.columns {total += column.width+COLUMN_GAP}
	return total
}

view_min_pan :: proc(tree: ^Tree, metrics: View_Metrics) -> f32 {
	return min(metrics.width-view_content_width(tree), 0)
}

view_measure_columns :: proc(tree: ^Tree, metrics: View_Metrics) {
	for index in 0 ..< len(tree.columns) {
		tree.columns[index].width = view_column_width(&tree.columns[index], metrics.char_advance)
	}
}

view_place_columns :: proc(tree: ^Tree, metrics: View_Metrics) {
	x := COLUMN_PAD+tree.pan_x
	for index in 0 ..< len(tree.columns) {
		column := &tree.columns[index]
		column.x = x
		column.y = CHROME_HEIGHT+COLUMN_PAD
		x += column.width+COLUMN_GAP
	}
}

view_active_shift :: proc(tree: ^Tree, metrics: View_Metrics) -> f32 {
	if tree.active < 0 || tree.active >= len(tree.columns) {return 0}
	column := &tree.columns[tree.active]
	limit := metrics.width-COLUMN_PAD
	if right := column.x+column.width; right > limit {return limit-right}
	if column.x < COLUMN_PAD {return COLUMN_PAD-column.x}
	return 0
}

view_layout :: proc(tree: ^Tree, metrics: View_Metrics) {
	if tree.viewport_height != metrics.height {
		tree.viewport_height = metrics.height
		for index in 0 ..< len(tree.columns) {tree_ensure_visible(tree, index)}
	}
	view_measure_columns(tree, metrics)
	tree.pan_x = clamp(tree.pan_x, view_min_pan(tree, metrics), 0)
	view_place_columns(tree, metrics)
	shift := view_active_shift(tree, metrics)
	if shift != 0 {
		tree.pan_x = clamp(tree.pan_x+shift, view_min_pan(tree, metrics), 0)
		view_place_columns(tree, metrics)
	}
}

view_control_rect :: proc(index: int, metrics: View_Metrics) -> draw.Rect {
	x := CONTROL_INSET+f32(index)*(CONTROL_SIZE+CONTROL_GAP)
	y := (CHROME_HEIGHT-CONTROL_SIZE)/2
	return {x, metrics.height-y-CONTROL_SIZE, CONTROL_SIZE, CONTROL_SIZE}
}

view_control_at :: proc(point: ui.Vec2, metrics: View_Metrics) -> int {
	if point.y >= CHROME_HEIGHT {return -1}
	for index in 0 ..< 3 {
		rect := view_control_rect(index, metrics)
		if point.x >= rect.x && point.x < rect.x+rect.w && point.y >= metrics.height-rect.y-rect.h && point.y < metrics.height-rect.y {
			return index
		}
	}
	return -1
}

view_draw_text :: proc(
	text: ^coretext.Context,
	list: ^draw.List,
	value: string,
	x, top, height: f32,
	size: f32,
	color: draw.Color,
	viewport_height: f32,
	max_width: f32 = 0,
) {
	run := coretext.shape(text, FONT_MONO, value, size, 0, max_width, max_width > 0)
	if run == nil {return}
	text_top := top+(height-(run.metrics.ascent+run.metrics.descent))/2
	origin := ui.Vec2{x, viewport_height-(text_top+run.metrics.ascent)}
	coretext.emit_shaped_run(text, list, run, origin, color, "")
}

view_draw_controls :: proc(list: ^draw.List, metrics: View_Metrics, hot: Hot_State) {
	for index in 0 ..< 3 {
		rect := view_control_rect(index, metrics)
		color := COLOR_CONTROL_CLOSE
		switch index {
		case 1: color = COLOR_CONTROL_MIN
		case 2: color = COLOR_CONTROL_ZOOM
		}
		if index == hot.control {color = {1.0, 1.0, 1.0, 1.0}}
		draw.solid(list, rect, color, corner_radius = CONTROL_SIZE/2)
		mark := draw.Rect{rect.x+CONTROL_SIZE*0.28, rect.y+CONTROL_SIZE/2-0.75, CONTROL_SIZE*0.44, 1.5}
		if index != 0 {draw.solid(list, mark, COLOR_CONTROL_EDGE)}
		if index == 2 {
			draw.solid(list, {rect.x+CONTROL_SIZE/2-0.75, rect.y+CONTROL_SIZE*0.28, 1.5, CONTROL_SIZE*0.44}, COLOR_CONTROL_EDGE)
		}
	}
}

view_draw_chrome :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, metrics: View_Metrics, hot: Hot_State) {
	draw.solid(list, {0, metrics.height-CHROME_HEIGHT, metrics.width, CHROME_HEIGHT}, COLOR_CHROME)
	draw.solid(list, {0, metrics.height-CHROME_HEIGHT-1, metrics.width, 1}, COLOR_CHROME_EDGE)
	view_draw_controls(list, metrics, hot)
	title := tree_root_directory(tree)
	if entry, ok := tree_selected_entry(tree); ok {title = entry.path}
	if len(title) == 0 {return}
	x := CONTROL_INSET+3*(CONTROL_SIZE+CONTROL_GAP)+CONTROL_GAP
	available := max(metrics.width-x-COLUMN_PAD, 0)
	view_draw_text(text, list, title, x, 0, CHROME_HEIGHT, FONT_SIZE, COLOR_DIM, metrics.height, available)
}

view_draw_connector :: proc(tree: ^Tree, list: ^draw.List, index: int, metrics: View_Metrics) {
	parent := &tree.columns[index]
	child := &tree.columns[index+1]
	if parent.selected < 0 {return}
	parent_y := parent.y+f32(parent.selected)*ROW_HEIGHT-parent.scroll+ROW_HEIGHT/2
	child_y := clamp(child.y-child.scroll, CHROME_HEIGHT+1, metrics.height-ROW_HEIGHT)+ROW_HEIGHT/2
	x0 := parent.x+parent.width
	x1 := child.x
	spine := x0+(x1-x0)/2
	color := COLOR_CONNECTOR
	if index+1 == tree.active {color = COLOR_CONNECTOR_HOT}
	width := CONNECTOR_WIDTH
	draw.solid(list, {x0, metrics.height-parent_y-width/2, spine-x0, width}, color)
	draw.solid(list, {spine-width/2, metrics.height-max(parent_y, child_y), width, abs(parent_y-child_y)}, color)
	draw.solid(list, {spine, metrics.height-child_y-width/2, x1-spine, width}, color)
}

view_draw_column :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, index: int, metrics: View_Metrics) {
	column := &tree.columns[index]
	top := column.y
	bottom := max(metrics.height-COLUMN_PAD, top+ROW_HEIGHT)
	draw.push_clip(list, {column.x-COLUMN_PAD, metrics.height-bottom, column.width, bottom-top})
	defer draw.pop_clip(list)
	for entry, row in column.entries {
		row_top := column.y+f32(row)*ROW_HEIGHT-column.scroll
		if row_top+ROW_HEIGHT < top || row_top > bottom {continue}
		selected := row == column.selected
		if selected {
			draw.solid(list, {column.x-COLUMN_PAD, metrics.height-row_top-ROW_HEIGHT, column.width, ROW_HEIGHT}, COLOR_SELECTION_BG)
		}
		color := entry_color(entry.kind, entry.hidden)
		if selected {color = COLOR_SELECTED}
		view_draw_text(text, list, entry.name, column.x+COLUMN_PAD, row_top, ROW_HEIGHT, FONT_SIZE, color, metrics.height)
	}
}

view_draw :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, metrics: View_Metrics, hot: Hot_State) {
	view_draw_chrome(tree, list, text, metrics, hot)
	for index in 0 ..< max(len(tree.columns)-1, 0) {view_draw_connector(tree, list, index, metrics)}
	for index in 0 ..< len(tree.columns) {view_draw_column(tree, list, text, index, metrics)}
}
