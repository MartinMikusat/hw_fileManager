package file_manager

import "core:fmt"
import "core:unicode/utf8"
import coretext "ui_framework:coretext"
import draw "ui_framework:draw"

TEXTEDIT_TAB_COLUMNS :: len(PREVIEW_TAB_SPACES)
TEXTEDIT_CARET_WIDTH :: f32(1.5)

// textedit_rune_columns is the width of a character on the monospace grid.
textedit_rune_columns :: proc(value: rune) -> int {
	return value == '\t' ? TEXTEDIT_TAB_COLUMNS : 1
}

// textedit_column is the grid column of offset within the line starting at line_start.
textedit_column :: proc(text: string, line_start, offset: int) -> int {
	column, index := 0, line_start
	for index < offset && index < len(text) {
		value, size := utf8.decode_rune_in_string(text[index:])
		column += textedit_rune_columns(value)
		index += size
	}
	return column
}

// textedit_offset_at_column maps a fractional grid column to the nearest
// character boundary of the line.
textedit_offset_at_column :: proc(text: string, line_start, line_end: int, column: f32) -> int {
	index, at := line_start, 0
	for index < line_end {
		value, size := utf8.decode_rune_in_string(text[index:line_end])
		width := textedit_rune_columns(value)
		if column < f32(at)+f32(width)/2 {return index}
		at += width
		index += size
	}
	return line_end
}

// textedit_status is the label of the preview's corner badge.
textedit_status :: proc(edit: ^Text_Edit) -> string {
	switch edit.prompt {
	case .Leave:    return "unsaved changes   s save   d discard   esc keep editing"
	case .Conflict: return "file changed on disk   o overwrite   r reload   esc cancel"
	case .None:
	}
	text := textedit_text(edit)
	caret := textedit_caret(edit)
	line := textedit_line_of(edit, caret)
	column := textedit_column(text, edit.starts[line], caret)+1
	return fmt.tprintf("%s%d:%d", edit.dirty ? "● " : "", line+1, column)
}

// textedit_draw paints the visible lines with selection, composition underline and
// caret, then the status badge.
textedit_draw :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, area: draw.Rect, edit: ^Text_Edit, scroll: f32, theme: Syntax_Theme, metrics: View_Metrics) {
	textedit_sync(edit)
	buffer := textedit_text(edit)
	rows := int(area.h/tree.row_height)
	columns := int(area.w/metrics.char_advance)
	first := int(scroll)
	select_start, select_end := textedit_selection(edit)
	caret := textedit_caret(edit)
	marked_start, marked_end := -1, -1
	if edit.state.has_marked_text {
		marked_start = edit.state.marked_start_byte
		marked_end = marked_start+len(edit.state.marked_text)
	}
	for index := first; index < min(len(edit.starts), first+rows+2); index += 1 {
		line_start, line_end := textedit_line_range(edit, index)
		top := area.y+(f32(index)-scroll)*tree.row_height
		if select_end > select_start && select_end > line_start && select_start <= line_end {
			low, high := max(select_start, line_start), min(select_end, line_end)
			from := textedit_column(buffer, line_start, low)
			to := textedit_column(buffer, line_start, high)
			if select_end > line_end {to += 1}
			rect := draw.Rect{area.x+f32(from-edit.hscroll)*metrics.char_advance, top, f32(to-from)*metrics.char_advance, tree.row_height}
			draw.solid(list, view_rect_draw(rect, metrics), COLOR_SELECTED_ROW, edge_softness = 0)
		}
		textedit_draw_line(tree, list, text, buffer, edit, line_start, line_end, area.x, top, columns, select_start, select_end, theme, metrics)
		if marked_start >= 0 && marked_end > line_start && marked_start <= line_end {
			from := textedit_column(buffer, line_start, max(marked_start, line_start))
			to := textedit_column(buffer, line_start, min(marked_end, line_end))
			rect := draw.Rect{area.x+f32(from-edit.hscroll)*metrics.char_advance, top+tree.row_height-2, f32(to-from)*metrics.char_advance, 1}
			draw.solid(list, view_rect_draw(rect, metrics), COLOR_TEXT, edge_softness = 0)
		}
		if caret >= line_start && caret <= line_end && edit.prompt == .None {
			at := textedit_column(buffer, line_start, caret)
			rect := draw.Rect{area.x+f32(at-edit.hscroll)*metrics.char_advance, top, TEXTEDIT_CARET_WIDTH, tree.row_height}
			draw.solid(list, view_rect_draw(rect, metrics), COLOR_TEXT, edge_softness = 0)
		}
	}
	label := textedit_status(edit)
	width := f32(utf8.rune_count_in_string(label)+2)*metrics.char_advance
	bar := draw.Rect{area.x+area.w-width, area.y+area.h-tree.row_height, width, tree.row_height}
	draw.solid(list, view_rect_draw(bar, metrics), COLOR_SELECTED_ROW, edge_softness = 0)
	view_draw_text(text, list, label, bar.x+metrics.char_advance, bar.y, bar.h, tree.font_size, COLOR_SELECTED, metrics.height)
}

// textedit_draw_line draws the columns of one line that the horizontal scroll
// shows, as runs of equal syntax kind; selected characters take the selection ink.
textedit_draw_line :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, buffer: string, edit: ^Text_Edit, line_start, line_end: int, x, top: f32, columns, select_start, select_end: int, theme: Syntax_Theme, metrics: View_Metrics) {
	run := make([dynamic]u8, 0, 64, context.temp_allocator)
	run_column, run_kind, run_selected := 0, Syntax_Kind.Plain, false
	column, index := 0, line_start
	flush :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, run: ^[dynamic]u8, column: int, kind: Syntax_Kind, selected: bool, x, top: f32, hscroll: int, theme: Syntax_Theme, metrics: View_Metrics) {
		defer clear(run)
		blank := true
		for value in run {
			if value != ' ' {blank = false; break}
		}
		if blank {return}
		view_draw_text(text, list, string(run[:]), x+f32(column-hscroll)*metrics.char_advance, top, tree.row_height, tree.font_size, selected ? COLOR_SELECTED : theme[kind], metrics.height)
	}
	for index < line_end {
		value, size := utf8.decode_rune_in_string(buffer[index:line_end])
		width := textedit_rune_columns(value)
		if column+width > edit.hscroll+columns {break}
		if column >= edit.hscroll {
			kind := edit.kinds[index]
			selected := index >= select_start && index < select_end
			if len(run) > 0 && (kind != run_kind || selected != run_selected) {
				flush(tree, list, text, &run, run_column, run_kind, run_selected, x, top, edit.hscroll, theme, metrics)
			}
			if len(run) == 0 {run_column, run_kind, run_selected = column, kind, selected}
			if value == '\t' {
				append(&run, PREVIEW_TAB_SPACES)
			} else {
				append(&run, buffer[index:index+size])
			}
		}
		column += width
		index += size
	}
	flush(tree, list, text, &run, run_column, run_kind, run_selected, x, top, edit.hscroll, theme, metrics)
}
