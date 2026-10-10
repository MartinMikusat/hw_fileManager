package file_manager

import "core:os"
import "core:path/filepath"
import "core:strings"
import coretext "ui_framework:coretext"
import draw "ui_framework:draw"

// favorites is the list of kept folders ("f" shows it, shift+F keeps or drops the
// current folder). It takes the preview's place, so a preview hides it.

favorites_sync :: proc(window: ^Window) {
	window.tree.favorites = app.settings.favorites
}

favorites_row_top :: proc(tree: ^Tree, row: int) -> f32 {
	return chrome_height+column_pad+f32(row)*tree.row_height
}

favorites_row_at :: proc(tree: ^Tree, y: f32) -> int {
	row := int((y-chrome_height-column_pad)/tree.row_height)
	if y < chrome_height+column_pad || row >= len(tree.favorites) {return -1}
	return row
}

// tree_current_directory is the folder the selection is in or on.
tree_current_directory :: proc(tree: ^Tree) -> string {
	if entry, ok := tree_selected_entry(tree); ok && entry.is_dir {return entry.path}
	if tree.active < 0 || tree.active >= len(tree.columns) {return ""}
	return tree.columns[tree.active].dir
}

// favorites_open_path reopens the cascade on a favorite; a folder that is gone
// leaves the tree as it was.
favorites_open_path :: proc(tree: ^Tree, path: string) -> bool {
	if !os.is_dir(path) {return false}
	return tree_open(tree, path)
}

favorites_toggle_list :: proc(window: ^Window) {
	window.tree.favorites_open = !window.tree.favorites_open
}

// favorites_toggle_current keeps the current folder, or drops it when kept, and
// shows the list so the change is visible.
favorites_toggle_current :: proc(window: ^Window) {
	path := tree_current_directory(&window.tree)
	if len(path) == 0 {return}
	current := app.settings.favorites
	kept := make([dynamic]string, 0, len(current)+1)
	found := false
	for favorite in current {
		if favorite == path {
			found = true
			delete(favorite)
			continue
		}
		append(&kept, favorite)
	}
	if !found {append(&kept, strings.clone(path))}
	delete(current)
	app.settings.favorites = kept[:]
	window.tree.favorites_open = true
	favorites_sync(window)
	_ = settings_save(settings_path(context.temp_allocator), app.settings)
}

view_draw_favorites :: proc(tree: ^Tree, list: ^draw.List, text: ^coretext.Context, metrics: View_Metrics, state: View_State) {
	rect := tree.favorites_rect
	draw.solid(list, view_rect_draw(rect, metrics), COLOR_BACKGROUND, edge_softness = 0)
	draw.push_clip(list, view_rect_draw(rect, metrics))
	defer draw.pop_clip(list)
	current := tree_current_directory(tree)
	searching := state.input_mode == .Search && len(state.input) > 0
	for path, row in tree.favorites {
		top := favorites_row_top(tree, row)
		if top > rect.y+rect.h {break}
		name := filepath.base(path)
		color := COLOR_TEXT
		if path == current {
			draw.solid(list, view_rect_draw({rect.x+column_pad, top, rect.w-2*column_pad, tree.row_height}, metrics), COLOR_SELECTED_ROW)
			color = COLOR_SELECTED
		} else if searching && name_contains_fold(name, state.input) {
			color = COLOR_SEARCH
		}
		view_draw_text(text, list, name, rect.x+2*column_pad, top, tree.row_height, tree.font_size, color, metrics.height, rect.w-3*column_pad)
	}
}
