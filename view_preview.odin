package file_manager

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
}

// view_preview_rect is the top-origin area the preview covers: everything left of
// the active column's parent column, which stays visible beside it.
view_preview_rect :: proc(tree: ^Tree, metrics: View_Metrics) -> (draw.Rect, bool) {
	if tree.active < 0 || tree.active >= len(tree.columns) {return {}, false}
	keep := &tree.columns[max(tree.active-1, 0)]
	left := COLUMN_PAD
	right := keep.x-COLUMN_PAD-1
	top := CHROME_HEIGHT
	bottom := metrics.height-metrics.bar_height
	if right-left < 12*metrics.char_advance || bottom-top < 4*tree.row_height {return {}, false}
	return {left, top, right-left, bottom-top}, true
}

view_draw_preview :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, rect: draw.Rect, preview: Preview_View, metrics: View_Metrics) {
	draw.solid(list, view_rect_draw(rect, metrics), COLOR_BACKGROUND, edge_softness = 0)
	inset := COLUMN_PAD
	area := draw.Rect{rect.x+inset, rect.y+inset, rect.w-2*inset, rect.h-2*inset}
	switch preview.kind {
	case .None:
	case .Text:
		rows := int(area.h/tree.row_height)
		columns := int(area.w/metrics.char_advance)
		for line, index in preview.lines {
			if index >= rows {break}
			if len(line) == 0 {continue}
			offset := int(uintptr(raw_data(line))-uintptr(raw_data(preview.text)))
			view_draw_code_line(tree, list, text, line, preview.kinds[offset:offset+len(line)], area.x, area.y+f32(index)*tree.row_height, columns, metrics)
		}
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
preview_view_make :: proc(preview: ^Preview, renderer: ^metal.Renderer, scale: f32) -> Preview_View {
	view := Preview_View{kind = preview.kind, lines = preview.lines[:], text = preview.text, kinds = preview.kinds, width = preview.width, height = preview.height, scale = scale}
	if preview.kind == .Image {view.texture = metal.register_texture(renderer, rawptr(preview.texture))}
	return view
}

view_syntax_color :: proc(kind: Syntax_Kind) -> draw.Color {
	switch kind {
	case .Plain:     return COLOR_TEXT
	case .Keyword:   return COLOR_SYNTAX_KEYWORD
	case .Type:      return COLOR_SYNTAX_TYPE
	case .Function:  return COLOR_SYNTAX_FUNCTION
	case .String:    return COLOR_SYNTAX_STRING
	case .Number:    return COLOR_SYNTAX_NUMBER
	case .Comment:   return COLOR_DIM
	case .Directive: return COLOR_SYNTAX_DIRECTIVE
	case .Tag:       return COLOR_SYNTAX_TAG
	case .Property:  return COLOR_SYNTAX_PROPERTY
	}
	return COLOR_TEXT
}

// view_draw_code_line draws one line as runs of equal syntax kind on the
// monospace grid, ending in an ellipsis when it exceeds columns.
view_draw_code_line :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, line: string, kinds: []Syntax_Kind, x, top: f32, columns: int, metrics: View_Metrics) {
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
			view_draw_text(text, list, run, x+f32(column)*metrics.char_advance, top, tree.row_height, tree.font_size, view_syntax_color(kind), metrics.height)
		}
		column += run_columns
	}
	if total > columns {
		view_draw_text(text, list, "…", x+f32(limit)*metrics.char_advance, top, tree.row_height, tree.font_size, COLOR_DIM, metrics.height)
	}
}
