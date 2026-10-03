package file_manager

import "core:mem"
import "core:path/filepath"
import "core:strings"
import devlog "devlog:."

Column :: struct {
	dir:      string,
	entries:  []Entry,
	selected: int,
	width:    f32,
	x:        f32,
	y:        f32,
	above:    [dynamic]Block,
	below:    [dynamic]Block,
	// Next parent rows to read into above/below; valid once context_ready.
	above_next:    int,
	below_next:    int,
	context_ready: bool,
	// Contents of the folders above a selected file, drawn to the column's right.
	trail:         [dynamic]Block,
	trail_next:    int,
	trail_ready:   bool,
}

Tree :: struct {
	columns:    [dynamic]Column,
	active:     int,
	pan_x:      f32,
	pan_y:      f32,
	// pan_x/pan_y spring toward the layout's targets; the rest is spring state.
	pan_vx:     f32,
	pan_vy:     f32,
	pan_snap:   bool,
	pan_moving: bool,
	slots:      [dynamic]Slot,
	offsets:    [dynamic]Stack_Offset,
	layout_width:  f32,
	layout_height: f32,
	layout_font:   f32,
	font_size:  f32,
	row_height: f32,
	line_ratio: f32,
	sort:       Sort,
	allocator:  mem.Allocator,
}

tree_init :: proc(tree: ^Tree, allocator := context.allocator) {
	assert(tree != nil)
	tree.allocator = allocator
	tree.columns = make([dynamic]Column, 0, 8, allocator)
	tree.active = 0
	tree.font_size = DEFAULT_FONT_SIZE
	tree.line_ratio = ROW_HEIGHT_RATIO
	tree.row_height = row_height_for(DEFAULT_FONT_SIZE, tree.line_ratio)
	tree.sort = SORT_DEFAULT
}

tree_set_font_size :: proc(tree: ^Tree, font_size: f32) -> bool {
	assert(tree != nil)
	size := clamp(font_size, f32(FONT_SIZE_MIN), f32(FONT_SIZE_MAX))
	if size == tree.font_size {return false}
	tree.font_size = size
	tree.row_height = row_height_for(size, tree.line_ratio)
	return true
}

tree_set_line_ratio :: proc(tree: ^Tree, ratio: f32) {
	tree.line_ratio = ratio
	tree.row_height = row_height_for(tree.font_size, ratio)
}

tree_destroy :: proc(tree: ^Tree) {
	assert(tree != nil)
	for &column in tree.columns {column_destroy(&column, tree.allocator)}
	tree_slots_destroy(tree)
	delete(tree.columns)
	tree.columns = nil
	tree.allocator = {}
}

column_destroy :: proc(column: ^Column, allocator: mem.Allocator) {
	column_context_destroy(column, allocator)
	delete(column.dir, allocator)
	entries_destroy(column.entries, allocator)
	column^ = {}
}

column_load :: proc(column: ^Column, directory: string, sort: Sort, allocator: mem.Allocator) -> bool {
	site := devlog.Site{feature = "files", operation = "read_directory"}
	devlog.started(devlog.global(), site, {file_id = filepath.base(directory)})
	entries, ok := read_entries(directory, sort, allocator)
	if !ok {
		devlog.failed(devlog.global(), site, {
			reason = "directory could not be read",
			detail = filepath.base(directory),
		})
		return false
	}
	devlog.succeeded(devlog.global(), site, {file_id = filepath.base(directory)}, {rows = i64(len(entries))})
	// directory may alias column.dir (tree_refresh), so clone it before the destroy frees it.
	owned := strings.clone(directory, allocator)
	column_destroy(column, allocator)
	column.dir = owned
	column.entries = entries
	column.selected = len(entries) > 0 ? 0 : -1
	return true
}

tree_truncate :: proc(tree: ^Tree, length: int) {
	assert(length >= 0 && length <= len(tree.columns))
	for index in length ..< len(tree.columns) {column_destroy(&tree.columns[index], tree.allocator)}
	resize(&tree.columns, length)
	if tree.active >= length {tree.active = max(length-1, 0)}
}

// tree_open shows the starting directory as a selected entry inside its parent
// column, so the cascade and its connector are visible on the first frame;
// grandparent adds the parent's own parent in front.
tree_open :: proc(tree: ^Tree, directory: string, grandparent := false) -> bool {
	if !tree_open_columns(tree, directory) {return false}
	if grandparent {_ = tree_prepend(tree)}
	return true
}

tree_open_columns :: proc(tree: ^Tree, directory: string) -> bool {
	tree_truncate(tree, 0)
	tree.pan_snap = true
	parent := filepath.dir(directory)
	if len(parent) == 0 || parent == directory {
		root: Column
		if !column_load(&root, directory, tree.sort, tree.allocator) {return false}
		append(&tree.columns, root)
		tree.active = 0
		return true
	}
	root: Column
	if !column_load(&root, parent, tree.sort, tree.allocator) {return false}
	append(&tree.columns, root)
	tree.active = 0
	name := filepath.base(directory)
	for entry, index in root.entries {
		if entry.is_dir && entry.name == name {
			return tree_select(tree, 0, index)
		}
	}
	devlog.failed(devlog.global(), {feature = "files", operation = "open_starting_directory"}, {
		reason = "starting directory was not found",
		detail = name,
	})
	return false
}

tree_refresh :: proc(tree: ^Tree) -> bool {
	directories := make([]string, len(tree.columns), context.temp_allocator)
	defer delete(directories, context.temp_allocator)
	selected := make([]string, len(tree.columns), context.temp_allocator)
	defer delete(selected, context.temp_allocator)
	rows := make([]int, len(tree.columns), context.temp_allocator)
	defer delete(rows, context.temp_allocator)
	for column, index in tree.columns {
		directories[index] = column.dir
		rows[index] = column.selected
		if column.selected >= 0 && column.selected < len(column.entries) {
			// Clone: column_load destroys the entry strings it points into.
			selected[index] = strings.clone(column.entries[column.selected].path, context.temp_allocator)
		}
	}
	for directory, index in directories {
		if !column_load(&tree.columns[index], directory, tree.sort, tree.allocator) {
			// A trashed or deleted folder leaves a column with no directory: drop it
			// and the columns that hang off it instead of keeping stale rows.
			if index == 0 {return false}
			tree_truncate(tree, index)
			parent := &tree.columns[index-1]
			if parent.selected >= 0 {_ = tree_select(tree, index-1, parent.selected, enter = false)}
			return true
		}
		column := &tree.columns[index]
		// A removed selection falls to the entry now in its row, or the last one.
		if len(column.entries) > 0 && rows[index] >= 0 {column.selected = min(rows[index], len(column.entries)-1)}
		for entry, entry_index in column.entries {
			if entry.path == selected[index] {
				column.selected = entry_index
				break
			}
		}
	}
	return true
}

// tree_select previews the selected directory in the column to its right. enter
// moves the focus into that preview (the right arrow and clicks); up/down and
// Home/End keep the focus on the column being navigated.
tree_select :: proc(tree: ^Tree, column_index, entry_index: int, enter := true) -> bool {
	if column_index < 0 || column_index >= len(tree.columns) {return false}
	column := &tree.columns[column_index]
	if entry_index < 0 || entry_index >= len(column.entries) {return false}
	column.selected = entry_index
	entry := column.entries[entry_index]
	if !entry.is_dir {
		tree_truncate(tree, column_index+1)
		tree.active = column_index
		return true
	}
	if column_index+1 < len(tree.columns) && tree.columns[column_index+1].dir == entry.path {
		tree_extend(tree, column_index+1)
		tree.active = enter ? column_index+1 : column_index
		return true
	}
	tree_truncate(tree, column_index+1)
	child: Column
	if !column_load(&child, entry.path, tree.sort, tree.allocator) {
		tree.active = column_index
		return false
	}
	append(&tree.columns, child)
	tree_extend(tree, column_index+1)
	tree.active = enter ? column_index+1 : column_index
	return true
}

tree_move :: proc(tree: ^Tree, delta: int) -> bool {
	if tree.active < 0 || tree.active >= len(tree.columns) {return false}
	column := &tree.columns[tree.active]
	if len(column.entries) == 0 {return false}
	next := clamp(column.selected+delta, 0, len(column.entries)-1)
	if next == column.selected {
		if delta == 1 || delta == -1 {return tree_move_to_sibling(tree, delta)}
		return false
	}
	return tree_select(tree, tree.active, next, enter = false)
}

// tree_move_to_sibling continues past the end of a child column into the next
// non-empty folder of its parent column, landing on that folder's first entry
// going down and its last going up. Nothing changes when there is none.
tree_move_to_sibling :: proc(tree: ^Tree, direction: int) -> bool {
	if tree.active < 1 {return false}
	parent_index := tree.active-1
	original_row := tree.columns[parent_index].selected
	child_row := tree.columns[tree.active].selected
	for row := original_row+direction; row >= 0 && row < len(tree.columns[parent_index].entries); row += direction {
		if !tree.columns[parent_index].entries[row].is_dir {continue}
		if !tree_select(tree, parent_index, row) {continue}
		child := &tree.columns[tree.active]
		if len(child.entries) == 0 {continue}
		if direction < 0 {_ = tree_select(tree, tree.active, len(child.entries)-1, enter = false)}
		return true
	}
	if tree_select(tree, parent_index, original_row) {_ = tree_select(tree, tree.active, child_row, enter = false)}
	return false
}

tree_expand :: proc(tree: ^Tree) -> bool {
	if tree.active < 0 || tree.active >= len(tree.columns) {return false}
	column := &tree.columns[tree.active]
	if column.selected < 0 || column.selected >= len(column.entries) {return false}
	if !column.entries[column.selected].is_dir {return false}
	if tree.active+1 < len(tree.columns) {
		tree.active += 1
		tree_extend(tree, tree.active+1)
		return true
	}
	return tree_select(tree, tree.active, column.selected)
}

// tree_prepend puts the root column's parent in front of it, with the old root
// selected; the active column keeps its place in the cascade.
tree_prepend :: proc(tree: ^Tree) -> bool {
	if len(tree.columns) == 0 {return false}
	root := tree.columns[0].dir
	parent_dir := filepath.dir(root)
	if len(parent_dir) == 0 || parent_dir == root {return false}
	name := filepath.base(root)
	parent: Column
	if !column_load(&parent, parent_dir, tree.sort, tree.allocator) {return false}
	parent.selected = -1
	for entry, index in parent.entries {
		if entry.name == name {parent.selected = index}
	}
	inject_at(&tree.columns, 0, parent)
	tree.active += 1
	tree.pan_snap = true
	return true
}

// tree_ascend focuses a new parent column in front of the root column, so the
// cascade can be walked above where it was opened.
tree_ascend :: proc(tree: ^Tree) -> bool {
	if !tree_prepend(tree) {return false}
	tree.active = 0
	return true
}

// tree_extend keeps the column after parent_index previewing that column's selected
// folder, reusing it when it already does. Each selection is thereby shown two
// levels deep: its own contents and those of the folder selected inside them.
tree_extend :: proc(tree: ^Tree, parent_index: int) {
	if parent_index < 0 || parent_index >= len(tree.columns) {return}
	parent := &tree.columns[parent_index]
	if parent.selected < 0 || parent.selected >= len(parent.entries) || !parent.entries[parent.selected].is_dir {
		tree_truncate(tree, parent_index+1)
		return
	}
	path := parent.entries[parent.selected].path
	if parent_index+1 < len(tree.columns) && tree.columns[parent_index+1].dir == path {
		tree_truncate(tree, parent_index+2)
		return
	}
	tree_truncate(tree, parent_index+1)
	child: Column
	if column_load(&child, path, tree.sort, tree.allocator) {append(&tree.columns, child)}
}

tree_collapse :: proc(tree: ^Tree) -> bool {
	if tree.active == 0 {return tree_ascend(tree)}
	if tree.active < 0 {return false}
	target := tree.active-1
	selected := tree.columns[target].selected
	tree_truncate(tree, tree.active)
	if selected < 0 {return true}
	// Keep the parent focused but show its selected folder in the child column,
	// the same preview up/down gives; otherwise the folder's contents vanish
	// until the next move re-creates the column.
	return tree_select(tree, target, selected, enter = false)
}

tree_focus_column :: proc(tree: ^Tree, column_index: int) -> bool {
	if column_index < 0 || column_index >= len(tree.columns) {return false}
	tree.active = column_index
	return true
}

tree_select_name :: proc(tree: ^Tree, column_index: int, name: string) -> bool {
	if column_index < 0 || column_index >= len(tree.columns) {return false}
	column := &tree.columns[column_index]
	for entry, index in column.entries {
		if entry.name == name {return tree_select(tree, column_index, index, enter = false)}
	}
	return false
}

tree_selected_entry :: proc(tree: ^Tree) -> (Entry, bool) {
	if tree.active < 0 || tree.active >= len(tree.columns) {return {}, false}
	column := &tree.columns[tree.active]
	if column.selected < 0 || column.selected >= len(column.entries) {return {}, false}
	return column.entries[column.selected], true
}

tree_root_directory :: proc(tree: ^Tree) -> string {
	if len(tree.columns) == 0 {return ""}
	return tree.columns[0].dir
}

tree_column_at :: proc(tree: ^Tree, x: f32) -> int {
	for column, index in tree.columns {
		if x >= column.x-COLUMN_PAD && x < column.x+column.width {return index}
	}
	return -1
}

tree_row_at :: proc(tree: ^Tree, column_index: int, y: f32) -> int {
	if column_index < 0 || column_index >= len(tree.columns) {return -1}
	column := &tree.columns[column_index]
	offset := y-column.y
	if offset < 0 {return -1}
	index := int(offset/tree.row_height)
	if index < 0 || index >= len(column.entries) {return -1}
	return index
}
