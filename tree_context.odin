package file_manager

import "core:mem"
import devlog "devlog:."

// Block is the listing of a sibling folder shown above or below a child column's
// own entries.
Block :: struct {
	entries: []Entry,
	y:       f32,
}

CONTEXT_READS_PER_PASS :: 32

block_destroy :: proc(block: ^Block, allocator: mem.Allocator) {
	entries_destroy(block.entries, allocator)
	block^ = {}
}

column_context_destroy :: proc(column: ^Column, allocator: mem.Allocator) {
	for &block in column.above {block_destroy(&block, allocator)}
	for &block in column.below {block_destroy(&block, allocator)}
	delete(column.above)
	delete(column.below)
}

context_block_read :: proc(directory: Entry, allocator: mem.Allocator) -> (Block, bool) {
	entries, ok := read_entries(directory.path, allocator)
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
			entry := parent.entries[column.above_next]
			column.above_next -= 1
			if !entry.is_dir {continue}
			reads += 1
			if block, ok := context_block_read(entry, tree.allocator); ok {
				append(&column.above, block)
				top -= gap+f32(len(block.entries))*tree.row_height
			}
		}
		for bottom < view_bottom && column.below_next < len(parent.entries) {
			if reads >= CONTEXT_READS_PER_PASS {
				complete = false
				break
			}
			entry := parent.entries[column.below_next]
			column.below_next += 1
			if !entry.is_dir {continue}
			reads += 1
			if block, ok := context_block_read(entry, tree.allocator); ok {
				append(&column.below, block)
				bottom += gap+f32(len(block.entries))*tree.row_height
			}
		}
	}
	return complete
}
