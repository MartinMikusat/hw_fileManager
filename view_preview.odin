package file_manager

import coretext "ui_framework:coretext"
import draw "ui_framework:draw"
import metal "ui_framework:metal"

// Preview_View is what the draw pass needs of the loaded preview.
Preview_View :: struct {
	kind:    Preview_Kind,
	lines:   []string,
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
		for line, index in preview.lines {
			if index >= rows {break}
			if len(line) == 0 {continue}
			view_draw_text(text, list, line, area.x, area.y+f32(index)*tree.row_height, tree.row_height, tree.font_size, COLOR_TEXT, metrics.height, area.w)
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
	view := Preview_View{kind = preview.kind, lines = preview.lines[:], width = preview.width, height = preview.height, scale = scale}
	if preview.kind == .Image {view.texture = metal.register_texture(renderer, rawptr(preview.texture))}
	return view
}
