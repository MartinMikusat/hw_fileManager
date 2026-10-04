package file_manager

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import coretext "ui_framework:coretext"
import draw "ui_framework:draw"
import metal "ui_framework:metal"

// Preview_View is what the draw pass needs of the loaded preview.
Preview_View :: struct {
	kind:    Preview_Kind,
	lines:   []string,
	// text is the buffer the lines slice; kinds classifies each of its bytes.
	text:    string,
	kinds:   []Syntax_Kind,
	texture: draw.Texture_Handle,
	width:   int,
	height:  int,
	// Backing pixels per point, so images are never shown larger than 1:1.
	scale:   f32,
	scroll:  f32,
	focused: bool,
	theme:   Syntax_Theme,
}

// view_preview_rect is the top-origin area the preview covers: everything left of
// the active column's grandparent, so both ancestor levels stay visible beside it;
// in the portrait layout only the parent stays, and the grandparent is dropped.
view_preview_rect :: proc(tree: ^Tree, metrics: View_Metrics) -> (draw.Rect, bool) {
	if tree.active < 0 || tree.active >= len(tree.columns) {return {}, false}
	keep := &tree.columns[max(tree.active-(view_preview_stacked(tree, metrics) ? 1 : 2), 0)]
	left := f32(0)
	right := keep.x-COLUMN_PAD-1
	top := CHROME_HEIGHT
	bottom := metrics.height-metrics.bar_height
	if right-left < 12*metrics.char_advance || bottom-top < 4*tree.row_height {return {}, false}
	return {left, top, right-left, bottom-top}, true
}

view_draw_preview :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, rect: draw.Rect, preview: Preview_View, metrics: View_Metrics) {
	draw.solid(list, view_rect_draw(rect, metrics), COLOR_BACKGROUND, edge_softness = 0)
	// The panel reaches the window edge so no column peeks out beside it; the
	// content keeps the usual inset, and is clipped to it, wide glyphs included.
	area := draw.Rect{rect.x+2*COLUMN_PAD, rect.y+COLUMN_PAD, rect.w-3*COLUMN_PAD, rect.h-2*COLUMN_PAD}
	draw.push_clip(list, view_rect_draw(area, metrics))
	defer draw.pop_clip(list)
	switch preview.kind {
	case .None:
	case .Cloud:
		view_draw_text(text, list, "In iCloud, not downloaded", area.x, area.y, tree.row_height, tree.font_size, COLOR_DIM, metrics.height, area.w)
	case .Text:
		rows := int(area.h/tree.row_height)
		columns := int(area.w/metrics.char_advance)
		first := int(preview.scroll)
		for index := first; index < min(len(preview.lines), first+rows+2); index += 1 {
			line := preview.lines[index]
			if len(line) == 0 {continue}
			offset := int(uintptr(raw_data(line))-uintptr(raw_data(preview.text)))
			view_draw_code_line(tree, list, text, line, preview.kinds[offset:offset+len(line)], preview.theme, area.x, area.y+(f32(index)-preview.scroll)*tree.row_height, columns, metrics)
		}
		// The line counter is the scroll cue: dim when everything fits, inverted when
		// the file scrolls, red once the preview has the focus.
		position := fmt.tprintf("%d/%d", min(first+1, len(preview.lines)), len(preview.lines))
		width := f32(len(position)+2)*metrics.char_advance
		bar := draw.Rect{area.x+area.w-width, area.y+area.h-tree.row_height, width, tree.row_height}
		color := COLOR_DIM
		if len(preview.lines) > rows {
			background := preview.focused ? COLOR_SELECTED_ROW : COLOR_TEXT
			draw.solid(list, view_rect_draw(bar, metrics), background, edge_softness = 0)
			color = preview.focused ? COLOR_SELECTED : COLOR_BACKGROUND
		}
		view_draw_text(text, list, position, bar.x+metrics.char_advance, bar.y, bar.h, tree.font_size, color, metrics.height)
	case .Image:
		natural_w := f32(preview.width)/preview.scale
		natural_h := f32(preview.height)/preview.scale
		fit := min(area.w/natural_w, area.h/natural_h, 1)
		width, height := natural_w*fit, natural_h*fit
		dst := draw.Rect{area.x+(area.w-width)/2, area.y+(area.h-height)/2, width, height}
		draw.image(list, preview.texture, view_rect_draw(dst, metrics), {0, 1, 1, -1})
	}
}

// preview_view_make registers the preview texture for this frame's draw pass.
preview_view_make :: proc(preview: ^Preview, renderer: ^metal.Renderer, scale: f32, theme: Syntax_Theme) -> Preview_View {
	view := Preview_View{theme = theme, kind = preview.kind, scroll = preview.scroll, lines = preview.lines[:], text = preview.text, kinds = preview.kinds, width = preview.width, height = preview.height, scale = scale}
	if preview.kind == .Image {view.texture = metal.register_texture(renderer, rawptr(preview.texture))}
	return view
}

// view_draw_code_line draws one line as runs of equal syntax kind on the
// monospace grid, ending in an ellipsis when it exceeds columns.
view_draw_code_line :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, line: string, kinds: []Syntax_Kind, theme: Syntax_Theme, x, top: f32, columns: int, metrics: View_Metrics) {
	total := utf8.rune_count_in_string(line)
	limit := total > columns ? columns-1 : total
	column, index := 0, 0
	for index < len(line) && column < limit {
		kind := kinds[index]
		run_start, run_columns := index, 0
		for index < len(line) && kinds[index] == kind && column+run_columns < limit {
			_, size := utf8.decode_rune_in_string(line[index:])
			index += size
			run_columns += 1
		}
		run := line[run_start:index]
		if len(strings.trim_space(run)) > 0 {
			view_draw_text(text, list, run, x+f32(column)*metrics.char_advance, top, tree.row_height, tree.font_size, theme[kind], metrics.height)
		}
		column += run_columns
	}
	if total > columns {
		view_draw_text(text, list, "…", x+f32(limit)*metrics.char_advance, top, tree.row_height, tree.font_size, COLOR_DIM, metrics.height)
	}
}
