package file_manager

import "core:mem"
import "core:path/filepath"
import "core:strings"
import devlog "devlog:."

Column :: struct {
	dir:      string,
	entries:  []Entry,
	selected: int,
	scroll:   f32,
	width:    f32,
	x:        f32,
	y:        f32,
}

Tree :: struct {
	columns:         [dynamic]Column,
	active:          int,
	pan_x:           f32,
	viewport_height: f32,
	allocator:       mem.Allocator,
}

tree_init :: proc(tree: ^Tree, allocator := context.allocator) {
	assert(tree != nil)
	tree.allocator = allocator
	tree.columns = make([dynamic]Column, 0, 8, allocator)
	tree.active = 0
	tree.viewport_height = 0
}

tree_destroy :: proc(tree: ^Tree) {
	assert(tree != nil)
	for &column in tree.columns {column_destroy(&column, tree.allocator)}
	delete(tree.columns)
	tree.columns = nil
	tree.allocator = {}
}

column_destroy :: proc(column: ^Column, allocator: mem.Allocator) {
	delete(column.dir, allocator)
	entries_destroy(column.entries, allocator)
	column^ = {}
}

column_load :: proc(column: ^Column, directory: string, allocator: mem.Allocator) -> bool {
	site := devlog.Site{feature = "files", operation = "read_directory"}
	devlog.started(devlog.global(), site, {file_id = filepath.base(directory)})
	entries, ok := read_entries(directory, allocator)
	if !ok {
		devlog.failed(devlog.global(), site, {
			reason = "directory could not be read",
			detail = filepath.base(directory),
		})
		return false
	}
	devlog.succeeded(devlog.global(), site, {file_id = filepath.base(directory)}, {rows = i64(len(entries))})
	column_destroy(column, allocator)
	column.dir = strings.clone(directory, allocator)
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
// column, so the cascade and its connector are visible on the first frame.
tree_open :: proc(tree: ^Tree, directory: string) -> bool {
	tree_truncate(tree, 0)
	tree.pan_x = 0
	parent := filepath.dir(directory)
	if len(parent) == 0 || parent == directory {
		root: Column
		if !column_load(&root, directory, tree.allocator) {return false}
		append(&tree.columns, root)
		tree.active = 0
		tree_ensure_visible(tree, 0)
		return true
	}
	root: Column
	if !column_load(&root, parent, tree.allocator) {return false}
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
	for column, index in tree.columns {directories[index] = column.dir}
	for directory, index in directories {
		if !column_load(&tree.columns[index], directory, tree.allocator) {return false}
	}
	return true
}

tree_select :: proc(tree: ^Tree, column_index, entry_index: int) -> bool {
	if column_index < 0 || column_index >= len(tree.columns) {return false}
	column := &tree.columns[column_index]
	if entry_index < 0 || entry_index >= len(column.entries) {return false}
	column.selected = entry_index
	entry := column.entries[entry_index]
	if !entry.is_dir {
		tree_truncate(tree, column_index+1)
		tree.active = column_index
		tree_ensure_visible(tree, column_index)
		return true
	}
	if column_index+1 < len(tree.columns) && tree.columns[column_index+1].dir == entry.path {
		tree_truncate(tree, column_index+2)
		tree.active = column_index+1
		tree_ensure_visible(tree, column_index)
		tree_ensure_visible(tree, column_index+1)
		return true
	}
	tree_truncate(tree, column_index+1)
	child: Column
	if !column_load(&child, entry.path, tree.allocator) {
		tree.active = column_index
		tree_ensure_visible(tree, column_index)
		return false
	}
	append(&tree.columns, child)
	tree.active = column_index+1
	tree_ensure_visible(tree, column_index)
	tree_ensure_visible(tree, column_index+1)
	return true
}

tree_move :: proc(tree: ^Tree, delta: int) -> bool {
	if tree.active < 0 || tree.active >= len(tree.columns) {return false}
	column := &tree.columns[tree.active]
	if len(column.entries) == 0 {return false}
	next := clamp(column.selected+delta, 0, len(column.entries)-1)
	if next == column.selected {return false}
	return tree_select(tree, tree.active, next)
}

tree_expand :: proc(tree: ^Tree) -> bool {
	if tree.active < 0 || tree.active >= len(tree.columns) {return false}
	column := &tree.columns[tree.active]
	if column.selected < 0 || column.selected >= len(column.entries) {return false}
	if !column.entries[column.selected].is_dir {return false}
	if tree.active+1 < len(tree.columns) {
		tree.active += 1
		tree_ensure_visible(tree, tree.active)
		return true
	}
	return tree_select(tree, tree.active, column.selected)
}

tree_collapse :: proc(tree: ^Tree) -> bool {
	if tree.active <= 0 {return false}
	target := tree.active-1
	tree_truncate(tree, tree.active)
	tree.active = target
	tree_ensure_visible(tree, tree.active)
	return true
}

tree_focus_column :: proc(tree: ^Tree, column_index: int) -> bool {
	if column_index < 0 || column_index >= len(tree.columns) {return false}
	tree.active = column_index
	return true
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

tree_content_extent :: proc(tree: ^Tree) -> f32 {
	if len(tree.columns) == 0 {return 0}
	last := tree.columns[len(tree.columns)-1]
	return last.x+last.width+COLUMN_PAD
}

tree_scroll_column :: proc(tree: ^Tree, column_index: int, delta: f32) {
	if column_index < 0 || column_index >= len(tree.columns) {return}
	column := &tree.columns[column_index]
	visible := tree_column_visible_height(tree)
	content := f32(len(column.entries))*ROW_HEIGHT
	column.scroll = clamp(column.scroll+delta, 0, max(content-visible, 0))
}

tree_column_visible_height :: proc(tree: ^Tree) -> f32 {
	top := CHROME_HEIGHT+COLUMN_PAD
	bottom := max(tree.viewport_height-COLUMN_PAD, top+ROW_HEIGHT)
	return bottom-top
}

tree_ensure_visible :: proc(tree: ^Tree, column_index: int) {
	if column_index < 0 || column_index >= len(tree.columns) {return}
	column := &tree.columns[column_index]
	if column.selected < 0 {return}
	visible := tree_column_visible_height(tree)
	row_top := f32(column.selected)*ROW_HEIGHT
	row_bottom := row_top+ROW_HEIGHT
	if row_top-column.scroll < 0 {column.scroll = row_top}
	if row_bottom-column.scroll > visible {column.scroll = row_bottom-visible}
	content := f32(len(column.entries))*ROW_HEIGHT
	column.scroll = clamp(column.scroll, 0, max(content-visible, 0))
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
	offset := y-column.y+column.scroll
	if offset < 0 {return -1}
	index := int(offset/ROW_HEIGHT)
	if index < 0 || index >= len(column.entries) {return -1}
	return index
}
