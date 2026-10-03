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

search_match_count :: proc(column: ^Column, query: string) -> int {
	count := 0
	for entry in column.entries {
		if search_matches(entry, query) {count += 1}
	}
	return count
}

// search_match_row returns the nth one-based matching row, or -1.
search_match_row :: proc(column: ^Column, query: string, nth: int) -> int {
	if nth <= 0 {return -1}
	count := 0
	for entry, index in column.entries {
		if search_matches(entry, query) {
			count += 1
			if count == nth {return index}
		}
	}
	return -1
}

search_begin :: proc(host: ^Host) {
	input_reset(host)
	host.input_mode = .Search
}

search_refresh :: proc(host: ^Host) {
	if host.tree.active < 0 || host.tree.active >= len(host.tree.columns) {return}
	query := input_text(host)
	if len(query) == 0 {return}
	column := &host.tree.columns[host.tree.active]
	total := search_match_count(column, query)
	if total == 0 {
		host.search_index = 0
		return
	}
	host.search_index = clamp(host.search_index, 0, total-1)
	if row := search_match_row(column, query, host.search_index+1); row >= 0 {
		_ = tree_select(&host.tree, host.tree.active, row, enter = false)
	}
}

search_retarget :: proc(host: ^Host) {
	host.search_index = 0
	search_refresh(host)
}

search_next :: proc(host: ^Host, delta: int) {
	if host.tree.active < 0 || host.tree.active >= len(host.tree.columns) {return}
	column := &host.tree.columns[host.tree.active]
	query := input_text(host)
	total := search_match_count(column, query)
	if total == 0 {return}
	host.search_index = (host.search_index+delta)%total
	if host.search_index < 0 {host.search_index += total}
	if row := search_match_row(column, query, host.search_index+1); row >= 0 {
		_ = tree_select(&host.tree, host.tree.active, row, enter = false)
	}
}

search_progress :: proc(tree: ^Tree, query: string) -> (current, total: int) {
	if len(query) == 0 || tree.active < 0 || tree.active >= len(tree.columns) {return 0, 0}
	column := &tree.columns[tree.active]
	for entry, index in column.entries {
		if search_matches(entry, query) {
			total += 1
			if index == column.selected {current = total}
		}
	}
	return current, total
}
