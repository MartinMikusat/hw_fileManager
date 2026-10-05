package file_manager

import "core:fmt"
import "core:path/filepath"
import "core:unicode/utf8"
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
	TabGeneral,
	TabFont,
	Minus,
	Plus,
	LineMinus,
	LinePlus,
	SpacingMinus,
	SpacingPlus,
	Previous,
	Next,
	Animations,
	Hints,
	EditorPrevious,
	EditorNext,
	EditorCustom,
	SyntaxPrevious,
	SyntaxNext,
	FontPrevious,
	FontNext,
	FontCustom,
	WeightPrevious,
	WeightNext,
	WidthPrevious,
	WidthNext,
	CliAction,
	CliCancel,
	DiagCopy,
	DiagExport,
}

Settings_Tab :: enum {
	General,
	Font,
}


Hot_State :: struct {
	control:         int,
	settings_button: bool,
	settings_hot:    Settings_Hot,
	sort_button:     bool,
	sort_row:        int,
	safe_button:     int,
	action:          Action_Kind,
	action_hot:      bool,
}

View_State :: struct {
	settings:         Settings,
	settings_open:    bool,
	sort_open:        bool,
	safe_mode:        bool,
	hot:              Hot_State,
	input_mode:       Input_Mode,
	input:            string,
	search_committed: bool,
	cd_completing:    bool,
	preview:          Preview_View,
	preview_rect:     draw.Rect,
	preview_shown:    bool,
	input_editing:    bool,
	input_caret:      int,
	input_sel_start:  int,
	input_sel_end:    int,
	clip_paths:        []string,
	clip_cut:         bool,
	gathered:         bool,
	current_gathered: bool,
	gather_paths:     []string,
	gather_hot_row:   int,
	gather_hot_clear: bool,
	edit:             View_Edit,
	notice:           string,
	notice_error:     bool,
	shift:            bool,
	settings_tab:     Settings_Tab,
	width_locked:     bool,
	cli_installed:    bool,
	cli_confirm:      bool,
}

CLI_INSTALL_LABEL :: "[Install]"
CLI_REMOVE_LABEL :: "[Remove]"
CLI_CONFIRM_LABEL :: "[Confirm]"
CLI_CANCEL_LABEL :: "[Cancel]"
DIAG_COPY_LABEL :: "[Copy]"
DIAG_EXPORT_LABEL :: "[Export]"
SAFE_TITLE :: "Safe mode"
SAFE_SUBTITLE :: "hw_fileManager crashed on its last two launches."
SAFE_COPY_LABEL :: "[Copy diagnostics]"
SAFE_EXPORT_LABEL :: "[Export]"
SAFE_DISMISS_LABEL :: "[Dismiss]"
SAFE_RESET_LABEL :: "[Reset settings]"
SAFE_LABELS :: [4]string{SAFE_COPY_LABEL, SAFE_EXPORT_LABEL, SAFE_DISMISS_LABEL, SAFE_RESET_LABEL}

SETTINGS_LABEL :: "[⌘, Settings]"
MINUS_LABEL :: "[-]"
PLUS_LABEL :: "[+]"
SETTINGS_TAB_GENERAL_LABEL :: "[General]"
SETTINGS_TAB_FONT_LABEL :: "[Font]"
PREVIOUS_LABEL :: "[<]"
NEXT_LABEL :: "[>]"
EDITOR_CUSTOM_LABEL :: "[Other]"
FONT_BUILT_IN_LABEL :: "Iosevka (built in)"

Settings_Row :: enum {
	Size,
	Family,
	Weight,
	Width,
	Line,
	Spacing,
	Terminal,
	Animations,
	Hints,
	Editor,
	Syntax,
	CommandLine,
	Diagnostics,
}

Settings_Control :: struct {
	rect:  draw.Rect,
	hot:   Settings_Hot,
	label: string,
	row:   Settings_Row,
}

SETTINGS_CONTROLS_MAX :: 24

Settings_Layout :: struct {
	panel:     draw.Rect,
	title_top: f32,
	tabs_top:  f32,
	// Top of each row of the active tab; rows of the other tab are not laid out.
	tops:      [Settings_Row]f32,
	controls:  [SETTINGS_CONTROLS_MAX]Settings_Control,
	count:     int,
	hint_top:  f32,
	cli_hint_top: f32,
}


view_column_width :: proc(column: ^Column, char_advance: f32) -> f32 {
	longest := 0
	for entry, index in column.entries {
		// The selected name is shown in full; the rest are capped.
		count := index == column.selected ? len(entry.name) : min(len(entry.name), NAME_MAX_CHARS)
		longest = max(longest, count)
	}
	for blocks in ([2][dynamic]Block{column.above, column.below}) {
		for block in blocks {
			for entry in block.entries {longest = max(longest, min(len(entry.name), NAME_MAX_CHARS))}
		}
	}
	return f32(longest)*char_advance+2*column_pad
}

view_measure_columns :: proc(tree: ^Tree, metrics: View_Metrics, edit: View_Edit) {
	for index in 0 ..< len(tree.columns) {
		width := view_column_width(&tree.columns[index], metrics.char_advance)
		if edit.active && edit.column == index {
			width = max(width, f32(len(edit.text))*metrics.char_advance+2*column_pad)
		}
		tree.columns[index].width = width
	}
}

// view_column_top is the pre-pan top of a column. Each column starts on the row
// its parent has selected, so a folder's contents open in line with the folder.
view_column_top :: proc(tree: ^Tree, index: int) -> f32 {
	y := chrome_height+column_pad
	for parent_index in 0 ..< index {
		parent := &tree.columns[parent_index]
		if parent.selected >= 0 {y += f32(parent.selected)*tree.row_height}
	}
	return y
}

// view_block_key is the directory a block lists.
view_block_key :: proc(block: Block) -> string {
	if len(block.entries) == 0 {return ""}
	return filepath.dir(block.entries[0].path)
}

// view_place_columns lays out every listing at its target row, then shifts each by
// its slot offset so listings that change row slide there instead of jumping.
view_place_columns :: proc(tree: ^Tree, metrics: View_Metrics, dt: f32, snap: bool) {
	tree_slots_begin(tree)
	defer tree_slots_end(tree)
	x := column_pad+tree.pan_x
	gap := view_context_gap(tree)
	for index in 0 ..< len(tree.columns) {
		column := &tree.columns[index]
		column.x = x
		column.y = view_column_top(tree, index)+tree.pan_y
		cursor := column.y
		for &block in column.above {
			cursor -= gap+f32(len(block.entries))*tree.row_height
			block.y = cursor
		}
		cursor = column.y+f32(len(column.entries))*tree.row_height
		for &block in column.below {
			cursor += gap
			block.y = cursor
			cursor += f32(len(block.entries))*tree.row_height
		}
		x += column.width+column_gap
		_ = trail_place(tree, column, gap)
		// The stack moves rigidly: the first listing also present last frame
		// sets how far the whole stack jumped, and the spring unwinds that jump.
		// A trail is kept after the selection leaves its file but is not shown,
		// and its folders then also appear as other columns' listings.
		trail_shown := view_trail_shown(column)
		stacks := [3][]Block{column.above[:], column.below[:], trail_shown ? column.trail[:] : nil}
		jump, anchored := tree_slot_jump(tree, column.dir, column.y-tree.pan_y)
		for blocks in stacks {
			for block in blocks {
				block_jump, known := tree_slot_jump(tree, view_block_key(block), block.y-tree.pan_y)
				if known && !anchored {jump, anchored = block_jump, true}
			}
		}
		stack := &tree.offsets[index]
		if snap {
			stack^ = {}
		} else {
			stack.value += jump
			// Sibling listings load only near the view, so a slide longer than half
			// of it (a huge folder passing by) would reveal listings never read.
			if abs(stack.value) > (metrics.height-metrics.bar_height-chrome_height)/2 {stack^ = {}}
			if !spring_step(&stack.value, &stack.velocity, 0, dt) {tree.pan_moving = true}
		}
		for blocks in stacks {
			for &block in blocks {block.y += stack.value}
		}
		column.y += stack.value
	}
}

// view_context_gap is the 2rem of whitespace between a column's own entries and
// the sibling folders listed around them; one rem is the font size.
view_context_gap :: proc(tree: ^Tree) -> f32 {
	return 2*tree.font_size
}

// view_pan_y_target puts the active selection's row on the middle line.
view_pan_y_target :: proc(tree: ^Tree, metrics: View_Metrics) -> f32 {
	if tree.active < 0 || tree.active >= len(tree.columns) {return tree.pan_y}
	column := &tree.columns[tree.active]
	if column.selected < 0 {return tree.pan_y}
	center := (chrome_height+(metrics.height-metrics.bar_height))/2
	row_center := view_column_top(tree, tree.active)+f32(column.selected)*tree.row_height+tree.row_height/2
	return center-row_center
}

// view_pan_x_target pins the active column's left edge to the vertical center
// line, so a name growing or shrinking never shifts the cascade.
view_pan_x_target :: proc(tree: ^Tree, metrics: View_Metrics) -> f32 {
	if tree.active < 0 || tree.active >= len(tree.columns) {return tree.pan_x}
	left := column_pad
	for index in 0 ..< tree.active {left += tree.columns[index].width+column_gap}
	if view_preview_stacked(tree, metrics) {
		// Portrait: the active column and the folders beside it sit flush right.
		active := &tree.columns[tree.active]
		right := left+active.width
		if view_trail_shown(active) {right += column_gap+column_pad+view_trail_chars(active)*metrics.char_advance}
		return metrics.width-column_pad-right
	}
	return metrics.width/2-left
}

// view_layout returns false when sibling listings are still being read, so the
// caller should draw another frame. A positive dt springs the pan toward its
// target (tree.pan_moving stays set until it rests); zero, a resize or a font
// change snaps. Columns hang off the pan, so the child column and sibling blocks
// follow the same spring.
view_layout :: proc(tree: ^Tree, metrics: View_Metrics, edit := View_Edit{}, dt := f32(0)) -> bool {
	snap := dt <= 0 || tree.pan_snap || metrics.width != tree.layout_width || metrics.height != tree.layout_height || tree.font_size != tree.layout_font
	tree.layout_width, tree.layout_height, tree.layout_font = metrics.width, metrics.height, tree.font_size
	tree.pan_snap = false
	target_y := view_pan_y_target(tree, metrics)
	settled_y := true
	if snap {
		tree.pan_y, tree.pan_vy = target_y, 0
	} else {
		settled_y = spring_step(&tree.pan_y, &tree.pan_vy, target_y, dt)
	}
	complete := tree_load_context(tree, chrome_height, metrics.height-metrics.bar_height, view_context_gap(tree))
	view_measure_columns(tree, metrics, edit)
	target_x := view_pan_x_target(tree, metrics)
	settled_x := true
	if snap {
		tree.pan_x, tree.pan_vx = target_x, 0
	} else {
		settled_x = spring_step(&tree.pan_x, &tree.pan_vx, target_x, dt)
	}
	tree.pan_moving = !(settled_x && settled_y)
	view_place_columns(tree, metrics, dt, snap)
	return complete
}

// symbol_cells is the measured width of ⌘ and ⇧ in character cells; they come
// from a fallback font, so counting them as one cell would misalign right-aligned
// labels. measure_char_advance refreshes it.
symbol_cells := f32(1)

// label_cells is the width of a label in character cells.
label_cells :: proc(label: string) -> f32 {
	cells := f32(0)
	for character in label {cells += character < 0x2000 ? 1 : symbol_cells}
	return cells
}

bar_height_of :: proc(row_height: f32) -> f32 {return 2*row_height+bar_bottom_pad}

// view_rect_draw flips a top-origin rect into the bottom-origin space the draw
// list renders in. Chrome controls are the only rects kept bottom-origin.
view_rect_draw :: proc(rect: draw.Rect, metrics: View_Metrics) -> draw.Rect {
	return {rect.x, metrics.height-rect.y-rect.h, rect.w, rect.h}
}

// The semaphore strip is the right-most item of the chrome row: three bracketed
// controls, edge to edge, flush with the right inset.
view_control_rect :: proc(index: int, metrics: View_Metrics) -> draw.Rect {
	height := min(metrics.row_height, chrome_height)
	x := metrics.width-(CONTROL_INSET_CELLS+f32(3-index)*CONTROL_CELLS)*metrics.char_advance
	y := (chrome_height-height)/2
	return {x, metrics.height-y-height, CONTROL_CELLS*metrics.char_advance, height}
}

view_control_at :: proc(point: ui.Vec2, metrics: View_Metrics) -> int {
	if point.y >= chrome_height {return -1}
	for index in 0 ..< 3 {
		rect := view_control_rect(index, metrics)
		if point.x >= rect.x && point.x < rect.x+rect.w && point.y >= metrics.height-rect.y-rect.h && point.y < metrics.height-rect.y {
			return index
		}
	}
	return -1
}

view_settings_control_rect :: proc(metrics: View_Metrics) -> draw.Rect {
	height := min(metrics.row_height, chrome_height)
	width := label_cells(SETTINGS_LABEL)*metrics.char_advance
	strip := (CONTROL_INSET_CELLS+3*CONTROL_CELLS)*metrics.char_advance
	x := metrics.width-strip-metrics.char_advance-width
	y := (chrome_height-height)/2
	return {x, metrics.height-y-height, width, height}
}

view_settings_control_at :: proc(point: ui.Vec2, metrics: View_Metrics) -> bool {
	if point.y >= chrome_height {return false}
	rect := view_settings_control_rect(metrics)
	return point.x >= rect.x && point.x < rect.x+rect.w && point.y >= metrics.height-rect.y-rect.h && point.y < metrics.height-rect.y
}

// The sort control sits one cell left of Settings, in the same borderless style.
view_sort_control_rect :: proc(tree: ^Tree, metrics: View_Metrics) -> draw.Rect {
	height := min(metrics.row_height, chrome_height)
	width := label_cells(sort_label(tree.sort))*metrics.char_advance
	settings := view_settings_control_rect(metrics)
	x := settings.x-metrics.char_advance-width
	y := (chrome_height-height)/2
	return {x, metrics.height-y-height, width, height}
}

view_sort_control_at :: proc(point: ui.Vec2, tree: ^Tree, metrics: View_Metrics) -> bool {
	if point.y >= chrome_height {return false}
	rect := view_sort_control_rect(tree, metrics)
	return view_rect_has(rect, {point.x, metrics.height-point.y})
}

Sort_Menu :: struct {
	panel: draw.Rect,
	rows:  [SORT_OPTION_COUNT]draw.Rect,
}

// view_sort_menu_layout drops the menu just under the chrome, right-aligned to
// the button but kept inside the window.
view_sort_menu_layout :: proc(tree: ^Tree, metrics: View_Metrics) -> Sort_Menu {
	row := metrics.row_height
	width := f32(0)
	for option in sort_options {
		width = max(width, f32(len(sort_option_label(option)))*metrics.char_advance)
	}
	width += 2*column_pad
	button := view_sort_control_rect(tree, metrics)
	x := clamp(button.x+button.w-width, column_pad, max(metrics.width-width-column_pad, column_pad))
	menu := Sort_Menu{panel = {x, chrome_height, width, f32(SORT_OPTION_COUNT)*row}}
	for index in 0 ..< SORT_OPTION_COUNT {
		menu.rows[index] = {x, chrome_height+f32(index)*row, width, row}
	}
	return menu
}

// view_sort_menu_at returns the row under the point; inside is true anywhere on
// the panel, so a click on its padding still closes it.
view_sort_menu_at :: proc(layout: Sort_Menu, point: ui.Vec2) -> (row: int, inside: bool) {
	if !rect_contains(layout.panel, point) {return -1, false}
	for index in 0 ..< SORT_OPTION_COUNT {
		if rect_contains(layout.rows[index], point) {return index, true}
	}
	return -1, true
}

Safe_Panel :: struct {
	panel:   draw.Rect,
	buttons: [4]draw.Rect,
	count:   int,
}

// safe_panel_layout centres the recovery panel under the chrome.
safe_panel_layout :: proc(metrics: View_Metrics) -> Safe_Panel {
	ch := metrics.char_advance
	row := metrics.row_height
	pad := 2*ch
	labels := SAFE_LABELS
	buttons_width := f32(len(SAFE_COPY_LABEL)+len(SAFE_EXPORT_LABEL)+len(SAFE_DISMISS_LABEL)+len(SAFE_RESET_LABEL))*ch+3*ACTION_GAP_CELLS*ch
	width := min(max(buttons_width, f32(len(SAFE_SUBTITLE))*ch)+2*pad, metrics.width-2*pad)
	height := 3*row+2*pad
	panel := draw.Rect{(metrics.width-width)/2, chrome_height+pad, width, height}
	result := Safe_Panel{panel = panel, count = len(labels)}
	cursor := panel.x+pad
	button_top := panel.y+pad+2*row
	for label, index in labels {
		result.buttons[index] = {cursor, button_top, f32(len(label))*ch, row}
		cursor += result.buttons[index].w+ACTION_GAP_CELLS*ch
	}
	return result
}

safe_panel_at :: proc(layout: Safe_Panel, point: ui.Vec2) -> (index: int, inside: bool) {
	if !rect_contains(layout.panel, point) {return -1, false}
	for button in 0 ..< layout.count {
		if rect_contains(layout.buttons[button], point) {return button, true}
	}
	return -1, true
}

view_settings_layout :: proc(tree: ^Tree, metrics: View_Metrics, tab := Settings_Tab.General) -> Settings_Layout {
	ch := metrics.char_advance
	row := tree.row_height
	pad := 2*ch
	width := min(settings_panel_width, max(metrics.width-4*ch, 0))
	height := 11*row+2*pad
	layout := Settings_Layout{}
	layout.panel = draw.Rect{(metrics.width-width)/2, (metrics.height-height)/2, width, height}
	layout.title_top = layout.panel.y+pad
	layout.tabs_top = layout.title_top+row
	first := layout.tabs_top+row
	button := 3*ch
	right := layout.panel.x+layout.panel.w-pad
	add :: proc(layout: ^Settings_Layout, rect: draw.Rect, hot: Settings_Hot, label: string, row: Settings_Row) {
		layout.controls[layout.count] = {rect, hot, label, row}
		layout.count += 1
	}
	tab_width := f32(len(SETTINGS_TAB_GENERAL_LABEL))*ch
	add(&layout, {layout.panel.x+pad, layout.tabs_top, tab_width, row}, .TabGeneral, SETTINGS_TAB_GENERAL_LABEL, .Size)
	add(&layout, {layout.panel.x+pad+tab_width+ch, layout.tabs_top, f32(len(SETTINGS_TAB_FONT_LABEL))*ch, row}, .TabFont, SETTINGS_TAB_FONT_LABEL, .Size)
	// stepper adds a [-]/[+]-style pair at the right edge of a row.
	stepper :: proc(layout: ^Settings_Layout, top, right, button, ch, row: f32, first, second: Settings_Hot, labels: [2]string, which: Settings_Row) {
		add(layout, {right-button, top, button, row}, second, labels[1], which)
		add(layout, {right-2*button-ch, top, button, row}, first, labels[0], which)
	}
	other := f32(len(EDITOR_CUSTOM_LABEL))*ch
	switch tab {
	case .Font:
		layout.tops[.Size] = first
		layout.tops[.Family] = first+row
		layout.tops[.Weight] = first+2*row
		layout.tops[.Width] = first+3*row
		layout.tops[.Line] = first+4*row
		layout.tops[.Spacing] = first+5*row
		layout.hint_top = first+6*row
		stepper(&layout, layout.tops[.Size], right, button, ch, row, .Minus, .Plus, {MINUS_LABEL, PLUS_LABEL}, .Size)
		stepper(&layout, layout.tops[.Family], right, button, ch, row, .FontPrevious, .FontNext, {PREVIOUS_LABEL, NEXT_LABEL}, .Family)
		add(&layout, {right-2*button-ch-ch-other, layout.tops[.Family], other, row}, .FontCustom, EDITOR_CUSTOM_LABEL, .Family)
		stepper(&layout, layout.tops[.Weight], right, button, ch, row, .WeightPrevious, .WeightNext, {PREVIOUS_LABEL, NEXT_LABEL}, .Weight)
		stepper(&layout, layout.tops[.Width], right, button, ch, row, .WidthPrevious, .WidthNext, {PREVIOUS_LABEL, NEXT_LABEL}, .Width)
		stepper(&layout, layout.tops[.Line], right, button, ch, row, .LineMinus, .LinePlus, {MINUS_LABEL, PLUS_LABEL}, .Line)
		stepper(&layout, layout.tops[.Spacing], right, button, ch, row, .SpacingMinus, .SpacingPlus, {MINUS_LABEL, PLUS_LABEL}, .Spacing)
	case .General:
		layout.tops[.Terminal] = first
		layout.tops[.Animations] = first+row
		layout.tops[.Hints] = first+2*row
		layout.tops[.Editor] = first+3*row
		layout.tops[.Syntax] = first+4*row
		layout.tops[.CommandLine] = first+5*row
		layout.tops[.Diagnostics] = first+6*row
		layout.cli_hint_top = first+7*row
		layout.hint_top = first+8*row
		stepper(&layout, layout.tops[.Terminal], right, button, ch, row, .Previous, .Next, {PREVIOUS_LABEL, NEXT_LABEL}, .Terminal)
		add(&layout, {right-5*ch, layout.tops[.Animations], 5*ch, row}, .Animations, "", .Animations)
		add(&layout, {right-5*ch, layout.tops[.Hints], 5*ch, row}, .Hints, "", .Hints)
		stepper(&layout, layout.tops[.Editor], right, button, ch, row, .EditorPrevious, .EditorNext, {PREVIOUS_LABEL, NEXT_LABEL}, .Editor)
		add(&layout, {right-2*button-ch-ch-other, layout.tops[.Editor], other, row}, .EditorCustom, EDITOR_CUSTOM_LABEL, .Editor)
		stepper(&layout, layout.tops[.Syntax], right, button, ch, row, .SyntaxPrevious, .SyntaxNext, {PREVIOUS_LABEL, NEXT_LABEL}, .Syntax)
		cli_action := f32(len(CLI_CONFIRM_LABEL))*ch
		add(&layout, {right-cli_action, layout.tops[.CommandLine], cli_action, row}, .CliAction, CLI_INSTALL_LABEL, .CommandLine)
		add(&layout, {right-cli_action-ch-f32(len(CLI_CANCEL_LABEL))*ch, layout.tops[.CommandLine], f32(len(CLI_CANCEL_LABEL))*ch, row}, .CliCancel, CLI_CANCEL_LABEL, .CommandLine)
		export_width := f32(len(DIAG_EXPORT_LABEL))*ch
		copy_width := f32(len(DIAG_COPY_LABEL))*ch
		add(&layout, {right-export_width, layout.tops[.Diagnostics], export_width, row}, .DiagExport, DIAG_EXPORT_LABEL, .Diagnostics)
		add(&layout, {right-export_width-ch-copy_width, layout.tops[.Diagnostics], copy_width, row}, .DiagCopy, DIAG_COPY_LABEL, .Diagnostics)
	}
	return layout
}

view_rect_has :: proc(rect: draw.Rect, point: ui.Vec2) -> bool {
	return point.x >= rect.x && point.x < rect.x+rect.w && point.y >= rect.y && point.y < rect.y+rect.h
}

view_settings_hot :: proc(layout: Settings_Layout, point: ui.Vec2) -> (Settings_Hot, bool) {
	for index in 0 ..< layout.count {
		control := layout.controls[index]
		if view_rect_has(control.rect, point) {return control.hot, true}
	}
	return .None, view_rect_has(layout.panel, point)
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
	run := coretext.shape(text, FONT_MONO, value, size, text_tracking, max_width, max_width > 0)
	if run == nil {return}
	text_top := top+(height-(run.metrics.ascent+run.metrics.descent))/2
	origin := ui.Vec2{x, viewport_height-(text_top+run.metrics.ascent)}
	coretext.emit_shaped_run(text, list, run, origin, color, "")
}

view_draw_controls :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, metrics: View_Metrics, hot: Hot_State) {
	for index in 0 ..< 3 {
		rect := view_control_rect(index, metrics)
		inverted := index == hot.control
		if inverted {draw.solid(list, rect, COLOR_TEXT, edge_softness = 0)}
		color := inverted ? COLOR_BACKGROUND : COLOR_TEXT
		top := metrics.height-rect.y-rect.h
		cell := rect.w/3
		label := ""
		switch index {
		case CONTROL_MINIMIZE: label = "_"
		case CONTROL_ZOOM:     label = "+"
		case CONTROL_CLOSE:    label = "x"
		}
		view_draw_text(text, list, "[", rect.x, top, rect.h, tree.font_size, color, metrics.height)
		view_draw_text(text, list, label, rect.x+cell, top, rect.h, tree.font_size, color, metrics.height)
		view_draw_text(text, list, "]", rect.x+2*cell, top, rect.h, tree.font_size, color, metrics.height)
	}
}

view_draw_chrome :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, metrics: View_Metrics, hot: Hot_State) {
	view_draw_controls(tree, list, text, metrics, hot)
	settings := view_settings_control_rect(metrics)
	if hot.settings_button {draw.solid(list, settings, COLOR_TEXT, edge_softness = 0)}
	settings_top := metrics.height-settings.y-settings.h
	view_draw_text(text, list, SETTINGS_LABEL, settings.x, settings_top, settings.h, tree.font_size, hot.settings_button ? COLOR_BACKGROUND : COLOR_TEXT, metrics.height)
	sort := view_sort_control_rect(tree, metrics)
	if hot.sort_button {draw.solid(list, sort, COLOR_TEXT, edge_softness = 0)}
	view_draw_text(text, list, sort_label(tree.sort), sort.x, settings_top, sort.h, tree.font_size, hot.sort_button ? COLOR_BACKGROUND : COLOR_TEXT, metrics.height)
	// The version sits just left of the sort control; the title yields the room.
	version_width := f32(len(APP_VERSION))*metrics.char_advance
	version_x := sort.x-metrics.char_advance-version_width
	view_draw_text(text, list, APP_VERSION, version_x, settings_top, settings.h, tree.font_size, COLOR_DIM, metrics.height)
	title := tree_root_directory(tree)
	if entry, ok := tree_selected_entry(tree); ok {title = entry.path}
	if len(title) == 0 {return}
	x := CONTROL_INSET_CELLS*metrics.char_advance
	available := max(version_x-x-metrics.char_advance, 0)
	view_draw_text(text, list, title, x, 0, chrome_height, tree.font_size, COLOR_DIM, metrics.height, available)
}

// The child's first entry opens on the parent's selected row, so the connector is
// one horizontal line from the parent's right edge to the child.
view_draw_connector :: proc(tree: ^Tree, list: ^draw.List, index: int, metrics: View_Metrics) {
	parent := &tree.columns[index]
	child := &tree.columns[index+1]
	if parent.selected < 0 {return}
	row_y := parent.y+f32(parent.selected)*tree.row_height+tree.row_height/2
	// The links of the chain down to the active column are drawn at full strength.
	color := COLOR_CONNECTOR
	if index+1 <= tree.active {color = COLOR_CONNECTOR_HOT}
	x0 := parent.x+parent.width
	draw.solid(list, {x0, metrics.height-row_y-connector_width/2, child.x-x0, connector_width}, color)
}

// view_connector_line draws an axis-aligned segment between two top-origin points.
view_connector_line :: proc(list: ^draw.List, metrics: View_Metrics, x0, y0, x1, y1: f32, color: draw.Color) {
	left, right := min(x0, x1), max(x0, x1)
	top, bottom := min(y0, y1), max(y0, y1)
	rect: draw.Rect
	if y0 == y1 {
		if right-left < 0.01 {return}
		rect = {left, y0-connector_width/2, right-left, connector_width}
	} else {
		if bottom-top < 0.01 {return}
		rect = {x0-connector_width/2, top, connector_width, bottom-top}
	}
	draw.solid(list, view_rect_draw(rect, metrics), color, edge_softness = 0.5)
}

// view_connector_corner draws a quarter circle of radius radius about (cx, cy) in the
// quadrant (qx, qy), each +1 or -1 (top-origin), as the elbow of a connector.
view_connector_corner :: proc(list: ^draw.List, metrics: View_Metrics, cx, cy, radius, qx, qy: f32, color: draw.Color) {
	quadrant := draw.Rect{qx > 0 ? cx : cx-radius, qy > 0 ? cy : cy-radius, radius, radius}
	draw.push_clip(list, view_rect_draw(quadrant, metrics))
	defer draw.pop_clip(list)
	circle := draw.Rect{cx-radius, cy-radius, 2*radius, 2*radius}
	draw.solid(list, view_rect_draw(circle, metrics), color, corner_radius = radius, border_thickness = connector_width, edge_softness = 0.5)
}

// view_draw_context_connector links a folder in the parent column to the listing of
// its contents in the child column: out of the folder's name, across to a vertical
// channel, along it, and into the listing's first row. channel is the channel's x.
view_draw_context_connector :: proc(tree: ^Tree, list: ^draw.List, parent: ^Column, child: ^Column, block: Block, channel: f32, metrics: View_Metrics) {
	if block.row < 0 || block.row >= len(parent.entries) {return}
	name := parent.entries[block.row].name
	name_cells := min(utf8.rune_count_in_string(name), NAME_MAX_CHARS)
	x0 := min(parent.x+column_pad+(f32(name_cells)+0.5)*metrics.char_advance, parent.x+parent.width)
	y0 := parent.y+f32(block.row)*tree.row_height+tree.row_height/2
	x1 := child.x
	y1 := block.y+tree.row_height/2
	color := COLOR_CONNECTOR_CONTEXT
	if abs(y1-y0) < 1 {
		view_connector_line(list, metrics, x0, y0, x1, y1, color)
		return
	}
	sign := y1 > y0 ? f32(1) : f32(-1)
	radius := min(scaled(5), abs(y1-y0)/2, channel-x0, x1-channel)
	if radius < 0.5 {
		view_connector_line(list, metrics, x0, y0, channel, y0, color)
		view_connector_line(list, metrics, channel, y0, channel, y1, color)
		view_connector_line(list, metrics, channel, y1, x1, y1, color)
		return
	}
	view_connector_line(list, metrics, x0, y0, channel-radius, y0, color)
	view_connector_corner(list, metrics, channel-radius, y0+sign*radius, radius, 1, -sign, color)
	view_connector_line(list, metrics, channel, y0+sign*radius, channel, y1-sign*radius, color)
	view_connector_corner(list, metrics, channel+radius, y1-sign*radius, radius, -1, sign, color)
	view_connector_line(list, metrics, channel+radius, y1, x1, y1, color)
}

// view_draw_context_connectors draws one connector per sibling listing around a child
// column. Farther listings take channels further left, so the lines nest without
// crossing, as in references/03-expanded-levels.jpg.
view_draw_context_connectors :: proc(tree: ^Tree, list: ^draw.List, index: int, metrics: View_Metrics) {
	parent := &tree.columns[index]
	child := &tree.columns[index+1]
	top := chrome_height
	bottom := metrics.height-metrics.bar_height
	draw.push_clip(list, view_rect_draw({0, top, metrics.width, bottom-top}, metrics))
	defer draw.pop_clip(list)
	x0 := parent.x+parent.width
	x1 := child.x
	for blocks in ([2][]Block{child.above[:], child.below[:]}) {
		visible := 0
		for block in blocks {
			y0 := parent.y+f32(block.row)*tree.row_height
			y1 := block.y
			if max(y0, y1)+tree.row_height < top || min(y0, y1) > bottom {continue}
			visible += 1
		}
		step := min(f32(4), (x1-x0-6)/f32(max(visible, 1)+1))
		drawn := 0
		for block in blocks {
			y0 := parent.y+f32(block.row)*tree.row_height
			y1 := block.y
			if max(y0, y1)+tree.row_height < top || min(y0, y1) > bottom {continue}
			drawn += 1
			view_draw_context_connector(tree, list, parent, child, block, x1-scaled(3)-f32(drawn)*step+step, metrics)
		}
	}
}

view_draw_gather_marker :: proc(list: ^draw.List, metrics: View_Metrics, x, row_top, row_height: f32) {
	draw.solid(list, view_rect_draw({x, row_top+(row_height-scaled(5))/2, scaled(5), scaled(5)}, metrics), COLOR_RED, edge_softness = 0)
}

view_draw_blocks :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, blocks: []Block, x, top, bottom: f32, metrics: View_Metrics, state: View_State) {
	searching := state.input_mode == .Search && len(state.input) > 0
	for block in blocks {
		for entry, row in block.entries {
			row_top := block.y+f32(row)*tree.row_height
			if row_top+tree.row_height < top || row_top > bottom {continue}
			if path_list_contains(state.gather_paths, entry.path) {
				view_draw_gather_marker(list, metrics, x-column_pad+scaled(3), row_top, tree.row_height)
			}
			max_width := f32(min(len(entry.name), NAME_MAX_CHARS))*metrics.char_advance
			color := entry_color(entry.recency, entry.hidden)
			if searching && search_matches(entry, state.input) {color = COLOR_SEARCH}
			view_draw_text(text, list, entry.name, x+column_pad, row_top, tree.row_height, tree.font_size, color, metrics.height, max_width)
		}
	}
}

// view_trail_shown reports whether a column's trail is drawn: only beside a selected file.
view_trail_shown :: proc(column: ^Column) -> bool {
	return len(column.trail) > 0 && column.selected >= 0 && !column.entries[column.selected].is_dir
}

// view_trail_chars is the width in cells of the widest name in a column's trail.
view_trail_chars :: proc(column: ^Column) -> f32 {
	longest := 0
	for block in column.trail {
		for entry in block.entries {longest = max(longest, min(len(entry.name), NAME_MAX_CHARS))}
	}
	return f32(longest)
}

// view_preview_stacked reports the portrait layout: with a file selected in a
// window taller than wide, the preview takes the left and the tree moves right.
view_preview_stacked :: proc(tree: ^Tree, metrics: View_Metrics) -> bool {
	if metrics.height <= metrics.width {return false}
	entry, ok := tree_selected_entry(tree)
	return ok && !entry.is_dir
}

// view_draw_trail draws the folders above a selected file to the right of its column.
view_draw_trail :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, index: int, metrics: View_Metrics, state: View_State) {
	column := &tree.columns[index]
	if !view_trail_shown(column) {return}
	longest := int(view_trail_chars(column))
	x := column.x+column.width+column_gap
	top := chrome_height
	bottom := max(metrics.height-metrics.bar_height-column_pad, top+tree.row_height)
	draw.push_clip(list, {x-column_pad, metrics.height-bottom, f32(longest)*metrics.char_advance+2*column_pad, bottom-top})
	defer draw.pop_clip(list)
	view_draw_blocks(tree, list, text, column.trail[:], x, top, bottom, metrics, state)
}

view_draw_column :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, index: int, metrics: View_Metrics, state: View_State) {
	column := &tree.columns[index]
	top := chrome_height
	bottom := max(metrics.height-metrics.bar_height-column_pad, top+tree.row_height)
	draw.push_clip(list, {column.x-column_pad, metrics.height-bottom, column.width+metrics.char_advance, bottom-top})
	defer draw.pop_clip(list)
	searching := state.input_mode == .Search && len(state.input) > 0
	completing := state.input_mode == .Cd && state.cd_completing && len(state.input) > 0 && index == tree.active
	for entry, row in column.entries {
		row_top := column.y+f32(row)*tree.row_height
		if row_top+tree.row_height < top || row_top > bottom {continue}
		// The selection in the focused column and in each column before it (the chain
		// down to it) is highlighted; those in the previews after it just keep their
		// names untruncated, the column being sized for them.
		selected := row == column.selected
		current := selected && index <= tree.active
		if current {
			left := column.x+column_pad-metrics.char_advance
			right := column.x+column.width-column_pad+metrics.char_advance
			draw.solid(list, {left, metrics.height-row_top-tree.row_height, right-left, tree.row_height}, COLOR_SELECTED_ROW)
		}
		if path_list_contains(state.gather_paths, entry.path) {
			view_draw_gather_marker(list, metrics, column.x-column_pad+scaled(3), row_top, tree.row_height)
		}
		color := entry_color(entry.recency, entry.hidden)
		max_width := selected ? f32(0) : f32(min(len(entry.name), NAME_MAX_CHARS))*metrics.char_advance
		if current {
			color = COLOR_SELECTED
		} else {
			if searching && search_matches(entry, state.input) {color = COLOR_SEARCH}
			if completing && entry.is_dir && name_has_prefix_fold(entry.name, state.input) {color = COLOR_SEARCH}
			if state.clip_cut && path_list_contains(state.clip_paths, entry.path) {color = COLOR_RED}
		}
		view_draw_text(text, list, entry.name, column.x+column_pad, row_top, tree.row_height, tree.font_size, color, metrics.height, max_width)
	}
	view_draw_blocks(tree, list, text, column.above[:], column.x, top, bottom, metrics, state)
	view_draw_blocks(tree, list, text, column.below[:], column.x, top, bottom, metrics, state)
	if state.edit.active && state.edit.column == index {
		view_draw_inline_edit(text, list, tree, metrics, column, state.edit)
	}
}

// view_draw_inline_edit renders the rename/new-file field on the entry's row with
// its selection and caret, scrolled to keep the caret visible.
view_draw_inline_edit :: proc(text: ^coretext.Context, list: ^draw.List, tree: ^Tree, metrics: View_Metrics, column: ^Column, edit: View_Edit) {
	row_top := column.y+f32(edit.row)*tree.row_height
	row_bottom := metrics.height-row_top-tree.row_height
	draw.solid(list, {column.x-column_pad, row_bottom, column.width, tree.row_height}, COLOR_SELECTION_BG)
	content_width := max(column.width-2*column_pad, metrics.char_advance)
	run := coretext.shape(text, FONT_MONO, edit.text, tree.font_size, text_tracking, 0, false)
	caret_x := view_edit_offset(text, run, edit.text, edit.caret)
	start_x := view_edit_offset(text, run, edit.text, edit.selection_start)
	end_x := view_edit_offset(text, run, edit.text, edit.selection_end)
	scroll := max(caret_x-(content_width-metrics.char_advance), 0)
	left := column.x+column_pad-scroll
	if edit.selection_end > edit.selection_start {
		draw.solid(list, {left+start_x, row_bottom, end_x-start_x, tree.row_height}, COLOR_SELECTION_INK, edge_softness = 0)
	}
	view_draw_text(text, list, edit.text, left, row_top, tree.row_height, tree.font_size, edit.error ? COLOR_RED : COLOR_TEXT, metrics.height)
	draw.solid(list, {left+caret_x, row_bottom+2*scaled(2), caret_width, tree.row_height-4*scaled(2)}, COLOR_CARET, edge_softness = 0)
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
		if caret >= 0 {draw.solid(list, {column_pad, row_bottom+scaled(2), caret_width, tree.row_height-2*scaled(2)}, COLOR_CARET, edge_softness = 0)}
		return
	}
	run := coretext.shape(text, FONT_MONO, value, tree.font_size, text_tracking, 0, false)
	if run == nil {return}
	x := column_pad
	if right_align {
		if width := run.metrics.width; x+width > metrics.width-column_pad {x = metrics.width-column_pad-width}
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
		draw.solid(list, {x+view_edit_offset(text, run, value, caret), row_bottom+scaled(2), caret_width, tree.row_height-2*scaled(2)}, COLOR_CARET, edge_softness = 0)
	}
}

view_draw_actions :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, metrics: View_Metrics, state: View_State) {
	bar := action_bar_layout(metrics, state.gathered, state.current_gathered, state.shift)
	for index in 0 ..< bar.count {
		kind := bar.kinds[index]
		rect := bar.rects[index]
		available := action_available(tree, state.gathered, len(state.clip_paths) > 0, kind)
		color := available ? COLOR_TEXT : COLOR_DIM
		if available && state.shift && kind == .Trash {color = COLOR_RED}
		if available && state.hot.action_hot && state.hot.action == kind {
			draw.solid(list, view_rect_draw(rect, metrics), COLOR_TEXT, edge_softness = 0)
			color = COLOR_BACKGROUND
		}
		view_draw_text(text, list, action_label(kind, state.current_gathered, state.shift), rect.x, rect.y, rect.h, tree.font_size, color, metrics.height)
	}
}

view_draw_bar :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, metrics: View_Metrics, state: View_State) {
	draw.push_clip(list, {0, 0, metrics.width, metrics.bar_height})
	defer draw.pop_clip(list)
	switch state.input_mode {
	case .Cd:
		view_bar_text(text, list, state.input, tree, metrics, COLOR_TEXT, false, state.input_caret, state.input_sel_start, state.input_sel_end)
	case .OpenWith, .FontFamily:
		// The field lives in the settings modal.
	case .Search:
		if len(state.input) == 0 {
			view_bar_text(text, list, "/", tree, metrics, COLOR_SEARCH, false, 1)
			break
		}
		if state.search_committed {
			view_top, view_bottom := chrome_height, metrics.height-metrics.bar_height
			current, total := search_progress(tree, state.input, view_top, view_bottom)
			view_bar_text(text, list, fmt.tprintf("/%s [%d/%d]", state.input, current, total), tree, metrics, COLOR_SEARCH, true)
			break
		}
		_, total := search_progress(tree, state.input, chrome_height, metrics.height-metrics.bar_height)
		view_bar_text(text, list, fmt.tprintf("/%s [%d]", state.input, total), tree, metrics, COLOR_SEARCH, true, 1+state.input_caret, 1+state.input_sel_start, 1+state.input_sel_end)
	case .None:
		if len(state.notice) > 0 {
			view_bar_text(text, list, state.notice, tree, metrics, state.notice_error ? COLOR_RED : COLOR_DIM, false)
		}
	}
	view_draw_actions(tree, list, text, metrics, state)
}

view_draw_gather :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, metrics: View_Metrics, state: View_State) {
	count := len(state.gather_paths)
	if count == 0 {return}
	layout := gather_panel_layout(metrics, count)
	draw.solid(list, view_rect_draw(layout.panel, metrics), COLOR_SELECTION_BG, edge_softness = 0)
	view_draw_text(text, list, fmt.tprintf("Gathered (%d)", count), layout.header.x+column_pad, layout.header.y, layout.header.h, tree.font_size, COLOR_TEXT, metrics.height)
	if state.gather_hot_clear {draw.solid(list, view_rect_draw(layout.clear, metrics), COLOR_TEXT, edge_softness = 0)}
	view_draw_text(text, list, action_label(.Clear), layout.clear.x, layout.clear.y, layout.clear.h, tree.font_size, state.gather_hot_clear ? COLOR_BACKGROUND : COLOR_DIM, metrics.height)
	max_width := f32(NAME_MAX_CHARS)*metrics.char_advance
	for index in 0 ..< layout.count {
		rect := layout.rows[index]
		hot := index == state.gather_hot_row
		if hot {draw.solid(list, view_rect_draw(rect, metrics), COLOR_TEXT, edge_softness = 0)}
		view_draw_text(text, list, filepath.base(state.gather_paths[index]), rect.x+column_pad, rect.y, rect.h, tree.font_size, hot ? COLOR_BACKGROUND : COLOR_TEXT, metrics.height, max_width)
	}
	if layout.overflow > 0 {
		last := layout.rows[layout.count-1]
		view_draw_text(text, list, fmt.tprintf("+%d more", layout.overflow), layout.panel.x+column_pad, last.y+last.h, tree.row_height, tree.font_size, COLOR_DIM, metrics.height)
	}
}

view_draw_safe :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, metrics: View_Metrics, state: View_State) {
	if !state.safe_mode {return}
	layout := safe_panel_layout(metrics)
	draw.solid(list, view_rect_draw(layout.panel, metrics), COLOR_SELECTION_BG, edge_softness = 0)
	pad := 2*metrics.char_advance
	left := layout.panel.x+pad
	view_draw_text(text, list, SAFE_TITLE, left, layout.panel.y+pad, tree.row_height, tree.font_size, COLOR_TEXT, metrics.height)
	view_draw_text(text, list, SAFE_SUBTITLE, left, layout.panel.y+pad+tree.row_height, tree.row_height, tree.font_size, COLOR_DIM, metrics.height)
	labels := SAFE_LABELS
	for index in 0 ..< layout.count {
		rect := layout.buttons[index]
		hot := index == state.hot.safe_button
		if hot {draw.solid(list, view_rect_draw(rect, metrics), COLOR_TEXT, edge_softness = 0)}
		view_draw_text(text, list, labels[index], rect.x, rect.y, rect.h, tree.font_size, hot ? COLOR_BACKGROUND : COLOR_TEXT, metrics.height)
	}
}

view_draw_sort_menu :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, metrics: View_Metrics, state: View_State) {
	if !state.sort_open {return}
	layout := view_sort_menu_layout(tree, metrics)
	draw.solid(list, view_rect_draw(layout.panel, metrics), COLOR_SELECTION_BG, edge_softness = 0)
	for index in 0 ..< SORT_OPTION_COUNT {
		option := sort_options[index]
		rect := layout.rows[index]
		active := option == tree.sort
		hot := index == state.hot.sort_row
		if active || hot {draw.solid(list, view_rect_draw(rect, metrics), COLOR_TEXT, edge_softness = 0)}
		color := (active || hot) ? COLOR_BACKGROUND : COLOR_TEXT
		view_draw_text(text, list, sort_option_label(option), rect.x+column_pad, rect.y, rect.h, tree.font_size, color, metrics.height)
	}
}

// view_draw_field draws an editable single-line field on a dark box, with its
// selection and caret, scrolled to keep the caret in view. rect is top-origin.
view_draw_field :: proc(text: ^coretext.Context, list: ^draw.List, value: string, rect: draw.Rect, tree: ^Tree, metrics: View_Metrics, caret, sel_start, sel_end: int) {
	draw.solid(list, view_rect_draw(rect, metrics), COLOR_SELECTION_BG, edge_softness = 0)
	draw.push_clip(list, view_rect_draw(rect, metrics))
	defer draw.pop_clip(list)
	inner := max(rect.w-2*metrics.char_advance, metrics.char_advance)
	run := coretext.shape(text, FONT_MONO, value, tree.font_size, text_tracking, 0, false)
	caret_x := view_edit_offset(text, run, value, caret)
	scroll := max(caret_x-(inner-metrics.char_advance), 0)
	left := rect.x+metrics.char_advance-scroll
	bottom := metrics.height-rect.y-rect.h
	if sel_end > sel_start {
		start_x := view_edit_offset(text, run, value, sel_start)
		end_x := view_edit_offset(text, run, value, sel_end)
		draw.solid(list, {left+start_x, bottom, end_x-start_x, rect.h}, COLOR_SELECTION_INK, edge_softness = 0)
	}
	view_draw_text(text, list, value, left, rect.y, rect.h, tree.font_size, COLOR_TEXT, metrics.height)
	draw.solid(list, {left+caret_x, bottom+scaled(4), caret_width, rect.h-scaled(8)}, COLOR_CARET, edge_softness = 0)
}

view_draw_settings :: proc(
	tree: ^Tree,
	list: ^draw.List,
	text: ^coretext.Context,
	metrics: View_Metrics,
	settings: Settings,
	settings_open: bool,
	hot: Hot_State,
	state: View_State,
) {
	if !settings_open {return}
	layout := view_settings_layout(tree, metrics, state.settings_tab)
	draw.solid(list, {0, 0, metrics.width, metrics.height}, COLOR_MODAL_BACKDROP, edge_softness = 0)
	draw.solid(list, view_rect_draw(layout.panel, metrics), COLOR_BACKGROUND, edge_softness = 0)
	left := layout.panel.x+2*metrics.char_advance
	row_height := tree.row_height
	size := tree.font_size
	view_draw_text(text, list, "Settings", left, layout.title_top, row_height, size, COLOR_TEXT, metrics.height)

	editing_row := Settings_Row.Size
	editing := false
	#partial switch state.input_mode {
	case .OpenWith:   editing_row, editing = .Editor, true
	case .FontFamily: editing_row, editing = .Family, true
	}

	label_for :: proc(row: Settings_Row, settings: Settings) -> string {
		switch row {
		case .Size:       return fmt.tprintf("Font size: %d", settings.font_size)
		case .Family:     return fmt.tprintf("Font: %s", len(settings.font_family) > 0 ? settings.font_family : FONT_BUILT_IN_LABEL)
		case .Weight:     return fmt.tprintf("Weight: %s", settings.font_weight)
		case .Width:      return fmt.tprintf("Width: %s", font_width_label(settings.font_width))
		case .Line:       return fmt.tprintf("Line height: %d%%", settings.line_height)
		case .Spacing:    return fmt.tprintf("Letter spacing: %.1f pt", f32(settings.letter_spacing)/10)
		case .Terminal:   return fmt.tprintf("Terminal: %s", settings.terminal)
		case .Animations: return "Animations"
		case .Hints:      return "Key hints"
		case .Editor:     return fmt.tprintf("Text editor: %s", editor_label(settings.editor))
		case .Syntax:     return fmt.tprintf("Syntax theme: %s", SYNTAX_THEME_NAMES[syntax_theme_index(settings.syntax_theme)])
		case .CommandLine: return "Command line tool"
		case .Diagnostics: return "Diagnostics"
		}
		return ""
	}

	locked :: proc(row: Settings_Row, settings: Settings, state: View_State) -> bool {
		#partial switch row {
		case .Weight: return len(settings.font_family) == 0
		case .Width:  return state.width_locked
		}
		return false
	}

	rows_shown := state.settings_tab == .Font ? []Settings_Row{.Size, .Family, .Weight, .Width, .Line, .Spacing} : []Settings_Row{.Terminal, .Animations, .Hints, .Editor, .Syntax, .CommandLine, .Diagnostics}
	for row in rows_shown {
		// The label yields to the row's controls.
		limit := layout.panel.x+layout.panel.w
		for index in 0 ..< layout.count {
			control := layout.controls[index]
			if control.row == row && control.hot != .TabGeneral && control.hot != .TabFont {limit = min(limit, control.rect.x)}
		}
		dim := locked(row, settings, state)
		if editing && row == editing_row {
			prefix := state.input_mode == .FontFamily ? "Font: " : "Text editor: "
			field_x := left+f32(len(prefix))*metrics.char_advance
			view_draw_text(text, list, prefix, left, layout.tops[row], row_height, size, COLOR_TEXT, metrics.height)
			field := draw.Rect{field_x, layout.tops[row], layout.panel.x+layout.panel.w-2*metrics.char_advance-field_x, row_height}
			view_draw_field(text, list, state.input, field, tree, metrics, state.input_caret, state.input_sel_start, state.input_sel_end)
			continue
		}
		view_draw_text(text, list, label_for(row, settings), left, layout.tops[row], row_height, size, dim ? COLOR_DIM : COLOR_TEXT, metrics.height, max(limit-left-metrics.char_advance, 0))
	}
	for index in 0 ..< layout.count {
		control := layout.controls[index]
		is_tab := control.hot == .TabGeneral || control.hot == .TabFont
		if !is_tab && editing && control.row == editing_row {continue}
		if control.hot == .CliCancel && !state.cli_confirm {continue}
		disabled := !is_tab && locked(control.row, settings, state)
		inverted := hot.settings_hot == control.hot && !disabled
		label := control.label
		if control.hot == .Animations {label = settings.animations_off ? "[off]" : "[on]"}
		if control.hot == .Hints {label = settings.hints_off ? "[off]" : "[on]"}
		if control.hot == .CliAction {label = state.cli_confirm ? CLI_CONFIRM_LABEL : (state.cli_installed ? CLI_REMOVE_LABEL : CLI_INSTALL_LABEL)}
		color := disabled ? COLOR_DIM : COLOR_TEXT
		if is_tab {
			active := (control.hot == .TabGeneral) == (state.settings_tab == .General)
			inverted = inverted || active
			color = active ? COLOR_TEXT : COLOR_DIM
		}
		if inverted {draw.solid(list, view_rect_draw(control.rect, metrics), COLOR_TEXT, edge_softness = 0)}
		view_draw_text(text, list, label, control.rect.x, control.rect.y, row_height, size, inverted ? COLOR_BACKGROUND : color, metrics.height)
	}
	switch {
	case editing && len(state.notice) > 0:
		view_draw_text(text, list, state.notice, left, layout.hint_top, row_height, size, COLOR_RED, metrics.height)
	case editing:
		hint := state.input_mode == .FontFamily ? "enter saves · esc cancels · empty = built-in font" : "enter saves · esc cancels · empty = system default"
		view_draw_text(text, list, hint, left, layout.hint_top, row_height, size, COLOR_DIM, metrics.height)
	case:
		if state.settings_tab == .General {
			view_draw_text(text, list, "Adds hfm to open folders from a terminal.", left, layout.cli_hint_top, row_height, size, COLOR_DIM, metrics.height, layout.panel.w-4*metrics.char_advance)
		}
		view_draw_text(text, list, "⌘, opens · tab switches · esc closes", left, layout.hint_top, row_height, size, COLOR_DIM, metrics.height)
	}
}

view_draw :: proc(
	tree: ^Tree,
	list: ^draw.List,
	text: ^coretext.Context,
	metrics: View_Metrics,
	state: View_State,
) {
	view_draw_chrome(tree, list, text, metrics, state.hot)
	for index in 0 ..< max(len(tree.columns)-1, 0) {
		view_draw_connector(tree, list, index, metrics)
		view_draw_context_connectors(tree, list, index, metrics)
	}
	for index in 0 ..< len(tree.columns) {
		view_draw_column(tree, list, text, index, metrics, state)
		view_draw_trail(tree, list, text, index, metrics, state)
	}
	if state.preview_shown {view_draw_preview(tree, list, text, state.preview_rect, state.preview, metrics)}
	view_draw_bar(tree, list, text, metrics, state)
	view_draw_gather(tree, list, text, metrics, state)
	view_draw_sort_menu(tree, list, text, metrics, state)
	view_draw_safe(tree, list, text, metrics, state)
	view_draw_settings(tree, list, text, metrics, state.settings, state.settings_open, state.hot, state)
}
