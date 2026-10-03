package file_manager

import "core:fmt"
import "core:time"
import coretext "ui_framework:coretext"
import text_input "components:text_input"
import ui "ui_framework:core"
import draw "ui_framework:draw"

View_Metrics :: struct {
	width:        f32,
	height:       f32,
	char_advance: f32,
	row_height:   f32,
	bar_height:   f32,
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
	action:          Action_Kind,
	action_hot:      bool,
}

View_State :: struct {
	settings:         Settings,
	settings_open:    bool,
	hot:              Hot_State,
	input_mode:       Input_Mode,
	input:            string,
	search_committed: bool,
	cd_completing:    bool,
	input_editing:    bool,
	input_caret:      int,
	input_sel_start:  int,
	input_sel_end:    int,
	clip_path:        string,
	clip_cut:         bool,
	edit:             View_Edit,
	notice:           string,
	notice_error:     bool,
	now:              time.Time,
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
ICON_STROKE :: f32(1.5)

SETTINGS_LABEL :: "[Settings]"
MINUS_LABEL :: "[-]"
PLUS_LABEL :: "[+]"

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
	for entry, index in column.entries {
		// The selected name is shown in full; the rest are capped.
		count := index == column.selected ? len(entry.name) : min(len(entry.name), NAME_MAX_CHARS)
		longest = max(longest, count)
	}
	return f32(longest)*char_advance+2*COLUMN_PAD
}

view_measure_columns :: proc(tree: ^Tree, metrics: View_Metrics, edit: View_Edit) {
	for index in 0 ..< len(tree.columns) {
		width := view_column_width(&tree.columns[index], metrics.char_advance)
		if edit.active && edit.column == index {
			width = max(width, f32(len(edit.text))*metrics.char_advance+2*COLUMN_PAD)
		}
		tree.columns[index].width = width
	}
}

// view_column_top is the pre-pan top of a column. Each column starts on the row
// its parent has selected, so a folder's contents open in line with the folder.
view_column_top :: proc(tree: ^Tree, index: int) -> f32 {
	y := CHROME_HEIGHT+COLUMN_PAD
	for parent_index in 0 ..< index {
		parent := &tree.columns[parent_index]
		if parent.selected >= 0 {y += f32(parent.selected)*tree.row_height}
	}
	return y
}

view_place_columns :: proc(tree: ^Tree, metrics: View_Metrics) {
	x := COLUMN_PAD+tree.pan_x
	for index in 0 ..< len(tree.columns) {
		column := &tree.columns[index]
		column.x = x
		column.y = view_column_top(tree, index)+tree.pan_y
		x += column.width+COLUMN_GAP
	}
}

// view_center_pan pins the active selection to the viewport center: its column's
// left edge sits on the vertical center line, so a name growing or shrinking
// never shifts the cascade, and its row sits on the middle line.
view_center_pan :: proc(tree: ^Tree, metrics: View_Metrics) {
	if tree.active < 0 || tree.active >= len(tree.columns) {return}
	column := &tree.columns[tree.active]
	left := COLUMN_PAD
	for index in 0 ..< tree.active {left += tree.columns[index].width+COLUMN_GAP}
	tree.pan_x = metrics.width/2-left
	if column.selected < 0 {return}
	center := (CHROME_HEIGHT+(metrics.height-metrics.bar_height))/2
	row_center := view_column_top(tree, tree.active)+f32(column.selected)*tree.row_height+tree.row_height/2
	tree.pan_y = center-row_center
}

view_layout :: proc(tree: ^Tree, metrics: View_Metrics, edit := View_Edit{}) {
	view_measure_columns(tree, metrics, edit)
	view_center_pan(tree, metrics)
	view_place_columns(tree, metrics)
}

// view_rect_draw flips a top-origin rect into the bottom-origin space the draw
// list renders in. Chrome controls are the only rects kept bottom-origin.
view_rect_draw :: proc(rect: draw.Rect, metrics: View_Metrics) -> draw.Rect {
	return {rect.x, metrics.height-rect.y-rect.h, rect.w, rect.h}
}

view_control_rect :: proc(index: int, metrics: View_Metrics) -> draw.Rect {
	height := min(metrics.row_height, CHROME_HEIGHT)
	x := (CONTROL_INSET_CELLS+f32(index)*CONTROL_STRIDE_CELLS)*metrics.char_advance
	y := (CHROME_HEIGHT-height)/2
	return {x, metrics.height-y-height, CONTROL_CELLS*metrics.char_advance, height}
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
	height := min(metrics.row_height, CHROME_HEIGHT)
	width := f32(len(SETTINGS_LABEL))*metrics.char_advance
	x := metrics.width-CONTROL_INSET_CELLS*metrics.char_advance-width
	y := (CHROME_HEIGHT-height)/2
	return {x, metrics.height-y-height, width, height}
}

view_settings_control_at :: proc(point: ui.Vec2, metrics: View_Metrics) -> bool {
	if point.y >= CHROME_HEIGHT {return false}
	rect := view_settings_control_rect(metrics)
	return point.x >= rect.x && point.x < rect.x+rect.w && point.y >= metrics.height-rect.y-rect.h && point.y < metrics.height-rect.y
}

view_settings_layout :: proc(tree: ^Tree, metrics: View_Metrics) -> Settings_Layout {
	ch := metrics.char_advance
	row := tree.row_height
	pad := 2*ch
	width := min(SETTINGS_PANEL_WIDTH, max(metrics.width-4*ch, 0))
	height := 4*row+2*pad
	panel := draw.Rect{(metrics.width-width)/2, (metrics.height-height)/2, width, height}
	title_top := panel.y+pad
	row_top := title_top+row
	button := 3*ch
	plus := draw.Rect{panel.x+panel.w-pad-button, row_top, button, row}
	minus := draw.Rect{plus.x-button-ch, row_top, button, row}
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

view_draw_glyph :: proc(list: ^draw.List, paths: [][4]f32, box: draw.Rect, color: draw.Color) {
	size := min(box.w, box.h)
	scale := size/ICON_BOX
	left := box.x+(box.w-size)/2
	bottom := box.y+(box.h-size)/2
	draw.path_begin(list)
	for segment in paths {
		draw.path_move_to(list, left+segment[0]*scale, bottom+size-segment[1]*scale)
		draw.path_line_to(list, left+segment[2]*scale, bottom+size-segment[3]*scale)
	}
	draw.path_stroke(list, color, ICON_STROKE*scale, .Round, .Round)
}

view_draw_controls :: proc(list: ^draw.List, metrics: View_Metrics, hot: Hot_State) {
	for index in 0 ..< 3 {
		rect := view_control_rect(index, metrics)
		if index == hot.control {draw.solid(list, rect, COLOR_TEXT, edge_softness = 0)}
		color := index == hot.control ? COLOR_BACKGROUND : COLOR_TEXT
		switch index {
		case CONTROL_CLOSE:    view_draw_glyph(list, XMARK_PATHS, rect, color)
		case CONTROL_MINIMIZE: view_draw_glyph(list, MINUS_PATHS, rect, color)
		case CONTROL_ZOOM:     view_draw_glyph(list, MAXIMIZE_PATHS, rect, color)
		}
	}
}

view_draw_chrome :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, metrics: View_Metrics, hot: Hot_State) {
	view_draw_controls(list, metrics, hot)
	settings := view_settings_control_rect(metrics)
	if hot.settings_button {draw.solid(list, settings, COLOR_TEXT, edge_softness = 0)}
	settings_top := metrics.height-settings.y-settings.h
	view_draw_text(text, list, SETTINGS_LABEL, settings.x, settings_top, settings.h, tree.font_size, hot.settings_button ? COLOR_BACKGROUND : COLOR_TEXT, metrics.height)
	title := tree_root_directory(tree)
	if entry, ok := tree_selected_entry(tree); ok {title = entry.path}
	if len(title) == 0 {return}
	x := (CONTROL_INSET_CELLS+3*CONTROL_STRIDE_CELLS)*metrics.char_advance
	available := max(settings.x-x-metrics.char_advance, 0)
	view_draw_text(text, list, title, x, 0, CHROME_HEIGHT, tree.font_size, COLOR_DIM, metrics.height, available)
}

// The child's first entry opens on the parent's selected row, so the connector is
// one horizontal line from the parent's right edge to the child.
view_draw_connector :: proc(tree: ^Tree, list: ^draw.List, index: int, metrics: View_Metrics) {
	parent := &tree.columns[index]
	child := &tree.columns[index+1]
	if parent.selected < 0 {return}
	row_y := parent.y+f32(parent.selected)*tree.row_height+tree.row_height/2
	color := COLOR_CONNECTOR
	if index+1 == tree.active {color = COLOR_CONNECTOR_HOT}
	x0 := parent.x+parent.width
	draw.solid(list, {x0, metrics.height-row_y-CONNECTOR_WIDTH/2, child.x-x0, CONNECTOR_WIDTH}, color)
}

view_draw_column :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, index: int, metrics: View_Metrics, state: View_State) {
	column := &tree.columns[index]
	top := CHROME_HEIGHT
	bottom := max(metrics.height-metrics.bar_height-COLUMN_PAD, top+tree.row_height)
	draw.push_clip(list, {column.x-COLUMN_PAD, metrics.height-bottom, column.width, bottom-top})
	defer draw.pop_clip(list)
	searching := state.input_mode == .Search && len(state.input) > 0
	completing := state.input_mode == .Cd && state.cd_completing && len(state.input) > 0 && index == tree.active
	for entry, row in column.entries {
		row_top := column.y+f32(row)*tree.row_height
		if row_top+tree.row_height < top || row_top > bottom {continue}
		selected := row == column.selected
		if selected {
			draw.solid(list, {column.x-COLUMN_PAD, metrics.height-row_top-tree.row_height, column.width, tree.row_height}, COLOR_SELECTION_BG)
		}
		color := entry_color(entry.modified, state.now, entry.hidden)
		max_width := f32(0)
		if selected {
			color = COLOR_SELECTED
		} else {
			max_width = f32(min(len(entry.name), NAME_MAX_CHARS))*metrics.char_advance
			if searching && search_matches(entry, state.input) {color = COLOR_SEARCH}
			if completing && entry.is_dir && name_has_prefix_fold(entry.name, state.input) {color = COLOR_SEARCH}
		}
		if state.clip_cut && len(state.clip_path) > 0 && entry.path == state.clip_path {
			color = COLOR_COPY
		}
		view_draw_text(text, list, entry.name, column.x+COLUMN_PAD, row_top, tree.row_height, tree.font_size, color, metrics.height, max_width)
	}
	if state.edit.active && state.edit.column == index {
		view_draw_inline_edit(text, list, tree, metrics, column, state.edit)
	}
}

// view_draw_inline_edit renders the rename/new-file field on the entry's row with
// its selection and caret, scrolled to keep the caret visible.
view_draw_inline_edit :: proc(text: ^coretext.Context, list: ^draw.List, tree: ^Tree, metrics: View_Metrics, column: ^Column, edit: View_Edit) {
	row_top := column.y+f32(edit.row)*tree.row_height
	row_bottom := metrics.height-row_top-tree.row_height
	draw.solid(list, {column.x-COLUMN_PAD, row_bottom, column.width, tree.row_height}, COLOR_SELECTION_BG)
	content_width := max(column.width-2*COLUMN_PAD, metrics.char_advance)
	run := coretext.shape(text, FONT_MONO, edit.text, tree.font_size, 0, 0, false)
	caret_x := view_edit_offset(text, run, edit.text, edit.caret)
	start_x := view_edit_offset(text, run, edit.text, edit.selection_start)
	end_x := view_edit_offset(text, run, edit.text, edit.selection_end)
	scroll := max(caret_x-(content_width-metrics.char_advance), 0)
	left := column.x+COLUMN_PAD-scroll
	if edit.selection_end > edit.selection_start {
		draw.solid(list, {left+start_x, row_bottom, end_x-start_x, tree.row_height}, COLOR_SELECTION_INK, edge_softness = 0)
	}
	view_draw_text(text, list, edit.text, left, row_top, tree.row_height, tree.font_size, edit.error ? COLOR_ERROR : COLOR_TEXT, metrics.height)
	draw.solid(list, {left+caret_x, row_bottom+4, 1.5, tree.row_height-8}, COLOR_CARET, edge_softness = 0)
}

// CTLine offsets are in backing pixels; the draw list works in logical points.
view_edit_offset :: proc(text: ^coretext.Context, run: ^coretext.Shaped_Run, value: string, offset: int) -> f32 {
	if run == nil || run.line == nil {return 0}
	utf16 := text_input.utf16_index_for_byte_offset(value, offset)
	return f32(coretext.CTLineGetOffsetForStringIndex(run.line, utf16, nil))/text.backing_scale
}

// view_bar_text right-aligns on overflow so the search counter stays visible.
// A caret at or above zero draws the field's caret and selection (byte offsets
// into value).
view_bar_text :: proc(text: ^coretext.Context, list: ^draw.List, value: string, tree: ^Tree, metrics: View_Metrics, color: draw.Color, right_align: bool, caret := -1, sel_start := 0, sel_end := 0) {
	row_bottom := metrics.bar_height-tree.row_height
	if len(value) == 0 {
		if caret >= 0 {draw.solid(list, {COLUMN_PAD, row_bottom+4, 1.5, tree.row_height-8}, COLOR_CARET, edge_softness = 0)}
		return
	}
	run := coretext.shape(text, FONT_MONO, value, tree.font_size, 0, 0, false)
	if run == nil {return}
	x := COLUMN_PAD
	if right_align {
		if width := run.metrics.width; x+width > metrics.width-COLUMN_PAD {x = metrics.width-COLUMN_PAD-width}
	}
	if caret >= 0 && sel_end > sel_start {
		start_x := view_edit_offset(text, run, value, sel_start)
		end_x := view_edit_offset(text, run, value, sel_end)
		draw.solid(list, {x+start_x, row_bottom, end_x-start_x, tree.row_height}, COLOR_SELECTION_INK, edge_softness = 0)
	}
	top := metrics.height-metrics.bar_height
	text_top := top+(tree.row_height-(run.metrics.ascent+run.metrics.descent))/2
	origin := ui.Vec2{x, metrics.height-(text_top+run.metrics.ascent)}
	coretext.emit_shaped_run(text, list, run, origin, color, "")
	if caret >= 0 {
		draw.solid(list, {x+view_edit_offset(text, run, value, caret), row_bottom+4, 1.5, tree.row_height-8}, COLOR_CARET, edge_softness = 0)
	}
}

view_draw_actions :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, metrics: View_Metrics, state: View_State) {
	rects := action_bar_rects(metrics)
	for kind in Action_Kind {
		rect := rects[int(kind)]
		available := action_available(tree, state.clip_path, kind)
		color := available ? COLOR_TEXT : COLOR_DIM
		if available && state.hot.action_hot && state.hot.action == kind {
			draw.solid(list, view_rect_draw(rect, metrics), COLOR_TEXT, edge_softness = 0)
			color = COLOR_BACKGROUND
		}
		view_draw_text(text, list, action_label(kind), rect.x, rect.y, rect.h, tree.font_size, color, metrics.height)
	}
}

view_draw_bar :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, metrics: View_Metrics, state: View_State) {
	draw.push_clip(list, {0, 0, metrics.width, metrics.bar_height})
	defer draw.pop_clip(list)
	switch state.input_mode {
	case .Cd:
		view_bar_text(text, list, state.input, tree, metrics, COLOR_TEXT, false, state.input_caret, state.input_sel_start, state.input_sel_end)
	case .Search:
		if len(state.input) == 0 {
			view_bar_text(text, list, "/", tree, metrics, COLOR_SEARCH, false, 1)
			break
		}
		if state.search_committed {
			current, total := search_progress(tree, state.input)
			view_bar_text(text, list, fmt.tprintf("/%s [%d/%d]", state.input, current, total), tree, metrics, COLOR_SEARCH, true)
			break
		}
		total := 0
		if tree.active >= 0 && tree.active < len(tree.columns) {total = search_match_count(&tree.columns[tree.active], state.input)}
		view_bar_text(text, list, fmt.tprintf("/%s [%d]", state.input, total), tree, metrics, COLOR_SEARCH, true, 1+state.input_caret, 1+state.input_sel_start, 1+state.input_sel_end)
	case .None:
		if len(state.notice) > 0 {
			view_bar_text(text, list, state.notice, tree, metrics, state.notice_error ? COLOR_ERROR : COLOR_DIM, false)
		}
	}
	view_draw_actions(tree, list, text, metrics, state)
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
	draw.solid(list, {0, 0, metrics.width, metrics.height}, COLOR_MODAL_BACKDROP, edge_softness = 0)
	panel := view_rect_draw(layout.panel, metrics)
	draw.solid(list, panel, COLOR_BACKGROUND, edge_softness = 0)
	left := layout.panel.x+2*metrics.char_advance
	view_draw_text(text, list, "Settings", left, layout.title_top, tree.row_height, tree.font_size, COLOR_TEXT, metrics.height)
	label := fmt.tprintf("Font size: %d", settings.font_size)
	view_draw_text(text, list, label, left, layout.row_top, tree.row_height, tree.font_size, COLOR_TEXT, metrics.height)
	minus := view_rect_draw(layout.minus, metrics)
	plus := view_rect_draw(layout.plus, metrics)
	if hot.settings_hot == .Minus {draw.solid(list, minus, COLOR_TEXT, edge_softness = 0)}
	if hot.settings_hot == .Plus {draw.solid(list, plus, COLOR_TEXT, edge_softness = 0)}
	view_draw_text(text, list, MINUS_LABEL, layout.minus.x, layout.row_top, tree.row_height, tree.font_size, hot.settings_hot == .Minus ? COLOR_BACKGROUND : COLOR_TEXT, metrics.height)
	view_draw_text(text, list, PLUS_LABEL, layout.plus.x, layout.row_top, tree.row_height, tree.font_size, hot.settings_hot == .Plus ? COLOR_BACKGROUND : COLOR_TEXT, metrics.height)
	view_draw_text(text, list, "⌘, opens · esc closes", left, layout.hint_top, tree.row_height, tree.font_size, COLOR_DIM, metrics.height)
}

view_draw :: proc(
	tree: ^Tree,
	list: ^draw.List,
	text: ^coretext.Context,
	metrics: View_Metrics,
	state: View_State,
) {
	view_draw_chrome(tree, list, text, metrics, state.hot)
	for index in 0 ..< max(len(tree.columns)-1, 0) {view_draw_connector(tree, list, index, metrics)}
	for index in 0 ..< len(tree.columns) {view_draw_column(tree, list, text, index, metrics, state)}
	view_draw_bar(tree, list, text, metrics, state)
	view_draw_settings(tree, list, text, metrics, state.settings, state.settings_open, state.hot)
}
