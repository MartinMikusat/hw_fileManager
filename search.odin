package file_manager

// search is the "/" prompt over the active column: substring matches highlight
// and n/N step through them like vim's search.
search_matches :: proc(entry: Entry, query: string) -> bool {
	return name_contains_fold(entry.name, query)
}

name_contains_fold :: proc(name, query: string) -> bool {
	if len(query) == 0 || len(query) > len(name) {return false}
	for start in 0 ..= len(name)-len(query) {
		matched := true
		for offset in 0 ..< len(query) {
			if fold_ascii(name[start+offset]) != fold_ascii(query[offset]) {
				matched = false
				break
			}
		}
		if matched {return true}
	}
	return false
}

Search_Source :: enum {
	Main,
	Above,
	Below,
	Trail,
}

// Search_Item is one listed name on screen: a column's own entry, or a row of a
// sibling-folder listing around it (block is that listing's index).
Search_Item :: struct {
	source: Search_Source,
	column: int,
	block:  int,
	row:    int,
}

// search_items lists every row at least partly inside [view_top, view_bottom],
// left to right and top to bottom, as the cascade is drawn.
search_items :: proc(tree: ^Tree, view_top, view_bottom: f32) -> []Search_Item {
	items := make([dynamic]Search_Item, 0, 64, context.temp_allocator)
	visible := proc(y, row_height, view_top, view_bottom: f32) -> bool {
		return y+row_height > view_top && y < view_bottom
	}
	for &column, index in tree.columns {
		#reverse for block, block_index in column.above {
			for _, row in block.entries {
				if visible(block.y+f32(row)*tree.row_height, tree.row_height, view_top, view_bottom) {
					append(&items, Search_Item{.Above, index, block_index, row})
				}
			}
		}
		for _, row in column.entries {
			if visible(column.y+f32(row)*tree.row_height, tree.row_height, view_top, view_bottom) {
				append(&items, Search_Item{.Main, index, 0, row})
			}
		}
		for block, block_index in column.below {
			for _, row in block.entries {
				if visible(block.y+f32(row)*tree.row_height, tree.row_height, view_top, view_bottom) {
					append(&items, Search_Item{.Below, index, block_index, row})
				}
			}
		}
		#reverse for block, block_index in column.trail {
			for _, row in block.entries {
				if visible(block.y+f32(row)*tree.row_height, tree.row_height, view_top, view_bottom) {
					append(&items, Search_Item{.Trail, index, block_index, row})
				}
			}
		}
	}
	return items[:]
}

search_item_entry :: proc(tree: ^Tree, item: Search_Item) -> Entry {
	column := &tree.columns[item.column]
	switch item.source {
	case .Main:  return column.entries[item.row]
	case .Above: return column.above[item.block].entries[item.row]
	case .Below: return column.below[item.block].entries[item.row]
	case .Trail: return column.trail[item.block].entries[item.row]
	}
	return {}
}

// search_current is the index of the selected row among items, or -1.
search_current :: proc(tree: ^Tree, items: []Search_Item) -> int {
	if tree.active < 0 || tree.active >= len(tree.columns) {return -1}
	selected := tree.columns[tree.active].selected
	for item, index in items {
		if item.source == .Main && item.column == tree.active && item.row == selected {return index}
	}
	return -1
}

// search_progress counts the matches on screen and the selected row's place
// among them (zero when the selection itself does not match).
search_progress :: proc(tree: ^Tree, query: string, view_top, view_bottom: f32) -> (current, total: int) {
	if len(query) == 0 {return 0, 0}
	items := search_items(tree, view_top, view_bottom)
	selected := search_current(tree, items)
	for item, index in items {
		if !search_matches(search_item_entry(tree, item), query) {continue}
		total += 1
		if index == selected {current = total}
	}
	return current, total
}

search_begin :: proc(host: ^Window) {
	input_begin(host, .Search)
}

// search_jump selects an on-screen row, entering the sibling folder it is listed
// under when it is not in a column of its own, and keeps its parent column
// visible when the row lands in the leftmost one.
search_jump :: proc(host: ^Window, item: Search_Item) {
	search_select(&host.tree, item)
	if host.tree.active == 0 {_ = tree_prepend(&host.tree)}
}

search_select :: proc(tree: ^Tree, item: Search_Item) {
	parent_row := 0
	switch item.source {
	case .Main:
		_ = tree_select(tree, item.column, item.row, enter = false)
		return
	case .Above: parent_row = tree.columns[item.column].above[item.block].row
	case .Below: parent_row = tree.columns[item.column].below[item.block].row
	case .Trail: parent_row = tree.columns[item.column].trail[item.block].row
	}
	folder_column := item.source == .Trail ? item.column : item.column-1
	if !tree_select(tree, folder_column, parent_row) {return}
	_ = tree_select(tree, tree.active, item.row, enter = false)
}

// search_step moves to the next (direction 1) or previous (-1) match on screen,
// wrapping around; inclusive also accepts the selected row itself.
search_step :: proc(host: ^Window, direction: int, inclusive: bool) {
	query := input_text(host)
	if len(query) == 0 {return}
	view_top, view_bottom := host_search_bounds(host)
	items := search_items(&host.tree, view_top, view_bottom)
	count := len(items)
	if count == 0 {return}
	current := search_current(&host.tree, items)
	start := current
	if current < 0 {
		start = direction > 0 ? 0 : count-1
	} else if !inclusive {
		start = current+direction
	}
	for step in 0 ..< count {
		index := ((start+direction*step)%count+count)%count
		if !search_matches(search_item_entry(&host.tree, items[index]), query) {continue}
		if index != current {search_jump(host, items[index])}
		return
	}
}

// search_commit jumps to the first match from the selection once the query is
// confirmed; while it is being typed the matches only highlight, as in vim
// without incsearch.
search_commit :: proc(host: ^Window) {
	search_step(host, 1, true)
}

search_refresh :: proc(host: ^Window) {
	search_step(host, 1, true)
}

search_next :: proc(host: ^Window, delta: int) {
	search_step(host, delta, false)
}

// search_chosen_folder is the folder a committed search ended on, for zoxide
// memory: the selected entry when it is a directory the query matched.
search_chosen_folder :: proc(host: ^Window) -> (string, bool) {
	if !host.search_committed {return "", false}
	entry, ok := tree_selected_entry(&host.tree)
	if !ok || !entry.is_dir {return "", false}
	if !search_matches(entry, input_text(host)) {return "", false}
	return entry.path, true
}
