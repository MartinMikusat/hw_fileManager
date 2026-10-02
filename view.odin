package file_manager

import "core:fmt"
import coretext "ui_framework:coretext"
import ui "ui_framework:core"
import draw "ui_framework:draw"

View_Metrics :: struct {
	width:        f32,
	height:       f32,
	char_advance: f32,
}

Settings_Hot :: enum {
	None,
	Minus,
	Plus,
}

Hot_State :: struct {
	control:         int,
	settings_button: bool,
	settings_hot:    Settings_Hot,
}

// Iconoir regular paths, in the icon's 24x24 coordinate space.
XMARK_PATHS :: [][4]f32{
	{6.75827, 17.2426, 12.0009, 12.0},
	{17.2435, 6.75736, 12.0009, 12.0},
	{12.0009, 12.0, 6.75827, 6.75736},
	{12.0009, 12.0, 17.2435, 17.2426},
}
MINUS_PATHS :: [][4]f32{{6.0, 12.0, 18.0, 12.0}}
MAXIMIZE_PATHS :: [][4]f32{
	{7.0, 4.0, 4.0, 4.0},
	{4.0, 4.0, 4.0, 7.0},
	{17.0, 4.0, 20.0, 4.0},
	{20.0, 4.0, 20.0, 7.0},
	{7.0, 20.0, 4.0, 20.0},
	{4.0, 20.0, 4.0, 17.0},
	{17.0, 20.0, 20.0, 20.0},
	{20.0, 20.0, 20.0, 17.0},
}
ICON_BOX :: f32(24)

Settings_Layout :: struct {
	panel:     draw.Rect,
	title_top: f32,
	row_top:   f32,
	minus:     draw.Rect,
	plus:      draw.Rect,
	hint_top:  f32,
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

// view_rect_draw flips a top-origin rect into the bottom-origin space the draw
// list renders in. Chrome controls are the only rects kept bottom-origin.
view_rect_draw :: proc(rect: draw.Rect, metrics: View_Metrics) -> draw.Rect {
	return {rect.x, metrics.height-rect.y-rect.h, rect.w, rect.h}
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

view_settings_control_rect :: proc(metrics: View_Metrics) -> draw.Rect {
	y := (CHROME_HEIGHT-CONTROL_SIZE)/2
	return {
		metrics.width-CONTROL_INSET-CONTROL_SIZE,
		metrics.height-y-CONTROL_SIZE,
		CONTROL_SIZE,
		CONTROL_SIZE,
	}
}

view_settings_control_at :: proc(point: ui.Vec2, metrics: View_Metrics) -> bool {
	if point.y >= CHROME_HEIGHT {return false}
	rect := view_settings_control_rect(metrics)
	return point.x >= rect.x && point.x < rect.x+rect.w && point.y >= metrics.height-rect.y-rect.h && point.y < metrics.height-rect.y
}

view_settings_layout :: proc(tree: ^Tree, metrics: View_Metrics) -> Settings_Layout {
	row := tree.row_height
	pad := COLUMN_PAD
	height := 3*row+4*pad
	panel := draw.Rect{(metrics.width-SETTINGS_PANEL_WIDTH)/2, (metrics.height-height)/2, SETTINGS_PANEL_WIDTH, height}
	title_top := panel.y+pad
	row_top := title_top+row
	control := max(row, f32(18))
	plus := draw.Rect{panel.x+panel.w-pad-control, row_top, control, control}
	minus := draw.Rect{plus.x-control-COLUMN_GAP, row_top, control, control}
	return {
		panel = panel,
		title_top = title_top,
		row_top = row_top,
		minus = minus,
		plus = plus,
		hint_top = row_top+row,
	}
}

view_settings_hot :: proc(layout: Settings_Layout, point: ui.Vec2) -> (Settings_Hot, bool) {
	if point.x >= layout.minus.x && point.x < layout.minus.x+layout.minus.w &&
	   point.y >= layout.minus.y && point.y < layout.minus.y+layout.minus.h {
		return .Minus, true
	}
	if point.x >= layout.plus.x && point.x < layout.plus.x+layout.plus.w &&
	   point.y >= layout.plus.y && point.y < layout.plus.y+layout.plus.h {
		return .Plus, true
	}
	if point.x >= layout.panel.x && point.x < layout.panel.x+layout.panel.w &&
	   point.y >= layout.panel.y && point.y < layout.panel.y+layout.panel.h {
		return .None, true
	}
	return .None, false
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

view_draw_glyph :: proc(list: ^draw.List, paths: [][4]f32, center: draw.Rect, color: draw.Color) {
	scale := CONTROL_SIZE*0.62/ICON_BOX
	cx := center.x+center.w/2
	cy := center.y+center.h/2
	draw.path_begin(list)
	for segment in paths {
		draw.path_move_to(list, cx+(segment[0]-ICON_BOX/2)*scale, cy+(segment[1]-ICON_BOX/2)*scale)
		draw.path_line_to(list, cx+(segment[2]-ICON_BOX/2)*scale, cy+(segment[3]-ICON_BOX/2)*scale)
	}
	draw.path_stroke(list, color, CONTROL_SIZE*0.1, .Round, .Round)
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
		switch index {
		case CONTROL_CLOSE:    view_draw_glyph(list, XMARK_PATHS, rect, COLOR_CONTROL_EDGE)
		case CONTROL_MINIMIZE: view_draw_glyph(list, MINUS_PATHS, rect, COLOR_CONTROL_EDGE)
		case CONTROL_ZOOM:     view_draw_glyph(list, MAXIMIZE_PATHS, rect, COLOR_CONTROL_EDGE)
		}
	}
	rect := view_settings_control_rect(metrics)
	if hot.settings_button {draw.solid(list, rect, COLOR_ROW_HOT, corner_radius = 4)}
	for index in 0 ..< 3 {
		bar := draw.Rect{rect.x+rect.w*0.22, rect.y+rect.h*0.3+f32(index)*rect.h*0.2, rect.w*0.56, 1.5}
		draw.solid(list, bar, hot.settings_button ? COLOR_SELECTED : COLOR_DIM)
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
	available := max(metrics.width-x-2*CONTROL_INSET-CONTROL_SIZE-COLUMN_PAD, 0)
	view_draw_text(text, list, title, x, 0, CHROME_HEIGHT, tree.font_size, COLOR_DIM, metrics.height, available)
}

view_draw_connector :: proc(tree: ^Tree, list: ^draw.List, index: int, metrics: View_Metrics) {
	parent := &tree.columns[index]
	child := &tree.columns[index+1]
	if parent.selected < 0 {return}
	parent_y := parent.y+f32(parent.selected)*tree.row_height-parent.scroll+tree.row_height/2
	child_y := clamp(child.y-child.scroll, CHROME_HEIGHT+1, metrics.height-tree.row_height)+tree.row_height/2
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
	bottom := max(metrics.height-COLUMN_PAD, top+tree.row_height)
	draw.push_clip(list, {column.x-COLUMN_PAD, metrics.height-bottom, column.width, bottom-top})
	defer draw.pop_clip(list)
	for entry, row in column.entries {
		row_top := column.y+f32(row)*tree.row_height-column.scroll
		if row_top+tree.row_height < top || row_top > bottom {continue}
		selected := row == column.selected
		if selected {
			draw.solid(list, {column.x-COLUMN_PAD, metrics.height-row_top-tree.row_height, column.width, tree.row_height}, COLOR_SELECTION_BG)
		}
		color := entry_color(entry.kind, entry.hidden)
		if selected {color = COLOR_SELECTED}
		view_draw_text(text, list, entry.name, column.x+COLUMN_PAD, row_top, tree.row_height, tree.font_size, color, metrics.height)
	}
}

view_draw_settings_button :: proc(list: ^draw.List, rect: draw.Rect, plus: bool, hot: bool) {
	color := hot ? COLOR_ROW_HOT : COLOR_ROW
	draw.solid(list, rect, color, corner_radius = 6)
	draw.solid(list, {rect.x+rect.w/2-7, rect.y+rect.h/2-1, 14, 2}, COLOR_TEXT)
	if plus {draw.solid(list, {rect.x+rect.w/2-1, rect.y+rect.h/2-7, 2, 14}, COLOR_TEXT)}
}

view_draw_settings :: proc(
	tree: ^Tree,
	list: ^draw.List,
	text: ^coretext.Context,
	metrics: View_Metrics,
	settings: Settings,
	settings_open: bool,
	hot: Hot_State,
) {
	if !settings_open {return}
	layout := view_settings_layout(tree, metrics)
	draw.solid(list, {0, 0, metrics.width, metrics.height}, COLOR_MODAL_BACKDROP)
	draw.solid(list, view_rect_draw(layout.panel, metrics), COLOR_PANEL, corner_radius = 8)
	draw.solid(list, view_rect_draw({layout.panel.x, layout.title_top, layout.panel.w, 1}, metrics), COLOR_PANEL_EDGE)
	view_draw_text(text, list, "Settings", layout.panel.x+COLUMN_PAD, layout.title_top, tree.row_height, tree.font_size, COLOR_TEXT, metrics.height)
	view_draw_text(text, list, "Font size", layout.panel.x+COLUMN_PAD, layout.row_top, tree.row_height, tree.font_size, COLOR_TEXT, metrics.height)
	value := fmt.tprintf("%d", settings.font_size)
	value_x := (layout.minus.x+layout.minus.w+layout.plus.x)/2-f32(len(value))*metrics.char_advance/2
	view_draw_text(text, list, value, value_x, layout.row_top, tree.row_height, tree.font_size, COLOR_SELECTED, metrics.height)
	view_draw_settings_button(list, view_rect_draw(layout.minus, metrics), false, hot.settings_hot == .Minus)
	view_draw_settings_button(list, view_rect_draw(layout.plus, metrics), true, hot.settings_hot == .Plus)
	view_draw_text(text, list, "⌘, opens - esc closes", layout.panel.x+COLUMN_PAD, layout.hint_top, tree.row_height, tree.font_size*0.85, COLOR_DIM, metrics.height)
}

view_draw :: proc(
	tree: ^Tree,
	list: ^draw.List,
	text: ^coretext.Context,
	metrics: View_Metrics,
	settings: Settings,
	settings_open: bool,
	hot: Hot_State,
) {
	view_draw_chrome(tree, list, text, metrics, hot)
	for index in 0 ..< max(len(tree.columns)-1, 0) {view_draw_connector(tree, list, index, metrics)}
	for index in 0 ..< len(tree.columns) {view_draw_column(tree, list, text, index, metrics)}
	view_draw_settings(tree, list, text, metrics, settings, settings_open, hot)
}
