package file_manager

import "core:mem"
import devlog "devlog:."

// Block is the listing of a sibling folder shown above or below a child column's
// own entries.
Block :: struct {
	entries: []Entry,
	y:       f32,
	// Row of the folder in its parent column.
	row:     int,
}

CONTEXT_READS_PER_PASS :: 32

block_destroy :: proc(block: ^Block, allocator: mem.Allocator) {
	entries_destroy(block.entries, allocator)
	block^ = {}
}

column_context_destroy :: proc(column: ^Column, allocator: mem.Allocator) {
	for &block in column.trail {block_destroy(&block, allocator)}
	delete(column.trail)
	for &block in column.above {block_destroy(&block, allocator)}
	for &block in column.below {block_destroy(&block, allocator)}
	delete(column.above)
	delete(column.below)
}

context_block_read :: proc(directory: Entry, sort: Sort, allocator: mem.Allocator) -> (Block, bool) {
	entries, ok := read_entries(directory.path, sort, allocator)
	if !ok {
		devlog.failed(devlog.global(), {feature = "files", operation = "read_context"}, {
			reason = "sibling folder could not be read",
			severity = .Warning,
		}, {file_id = directory.name})
		return {}, false
	}
	if len(entries) == 0 {
		entries_destroy(entries, allocator)
		return {}, false
	}
	return Block{entries = entries}, true
}

// tree_load_context lists, for each child column, the folders above and below the
// parent's selection, nearest first, only as far as the viewport needs them, and
// caches the listings on the column. It returns false when the read budget ran
// out before the viewport was filled, so the caller should lay out again.
tree_load_context :: proc(tree: ^Tree, view_top, view_bottom, gap: f32) -> bool {
	complete := true
	for index in 1 ..< len(tree.columns) {
		column := &tree.columns[index]
		parent := &tree.columns[index-1]
		if parent.selected < 0 {continue}
		if !column.context_ready {
			column.context_ready = true
			column.above_next = parent.selected-1
			column.below_next = parent.selected+1
		}
		top := view_column_top(tree, index)+tree.pan_y
		bottom := top+f32(len(column.entries))*tree.row_height
		for block in column.above {top -= gap+f32(len(block.entries))*tree.row_height}
		for block in column.below {bottom += gap+f32(len(block.entries))*tree.row_height}
		reads := 0
		for top > view_top && column.above_next >= 0 {
			if reads >= CONTEXT_READS_PER_PASS {
				complete = false
				break
			}
			row := column.above_next
			entry := parent.entries[row]
			column.above_next -= 1
			if !entry.is_dir {continue}
			reads += 1
			if block, ok := context_block_read(entry, tree.sort, tree.allocator); ok {
				block.row = row
				append(&column.above, block)
				top -= gap+f32(len(block.entries))*tree.row_height
			}
		}
		for bottom < view_bottom && column.below_next < len(parent.entries) {
			if reads >= CONTEXT_READS_PER_PASS {
				complete = false
				break
			}
			row := column.below_next
			entry := parent.entries[row]
			column.below_next += 1
			if !entry.is_dir {continue}
			reads += 1
			if block, ok := context_block_read(entry, tree.sort, tree.allocator); ok {
				block.row = row
				append(&column.below, block)
				bottom += gap+f32(len(block.entries))*tree.row_height
			}
		}
	}
	if len(tree.columns) > 0 {
		complete = tree_load_trail(tree, view_top, gap) && complete
	}
	return complete
}

// trail_place sets each trail block's y and returns the top of the last one: the
// first block ends level with its folder's own row, the rest stack upward with a
// gap.
trail_place :: proc(tree: ^Tree, column: ^Column, gap: f32) -> f32 {
	y := f32(0)
	for &block, index in column.trail {
		height := f32(len(block.entries))*tree.row_height
		if index == 0 {
			y = column.y+f32(block.row+1)*tree.row_height-height
		} else {
			y -= gap+height
		}
		block.y = y
	}
	return y
}

// tree_load_trail lists the folders above a selected file in the last column.
// Folders sort before files, so every folder sits above it, and their contents
// show to the column's right, nearest folder first.
tree_load_trail :: proc(tree: ^Tree, view_top, gap: f32) -> bool {
	column := &tree.columns[len(tree.columns)-1]
	if column.selected < 0 || column.entries[column.selected].is_dir {return true}
	if !column.trail_ready {
		column.trail_ready = true
		column.trail_next = len(column.entries)-1
	}
	column.y = view_column_top(tree, len(tree.columns)-1)+tree.pan_y
	reads := 0
	for column.trail_next >= 0 {
		if len(column.trail) > 0 && trail_place(tree, column, gap) <= view_top {break}
		if reads >= CONTEXT_READS_PER_PASS {return false}
		row := column.trail_next
		entry := column.entries[row]
		column.trail_next -= 1
		if !entry.is_dir {continue}
		reads += 1
		if block, ok := context_block_read(entry, tree.sort, tree.allocator); ok {
			block.row = row
			append(&column.trail, block)
		}
	}
	return true
}
