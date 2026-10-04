package file_manager

import "core:strings"
import "core:testing"

append_query :: proc(host: ^Window, value: string) {
	input_set(host, value)
}

search_layout :: proc(host: ^Window) {
	host.view_width = 1000
	host.view_height = 700
	metrics := View_Metrics{width = 1000, height = 700, char_advance = 8, row_height = host.tree.row_height, bar_height = 2*host.tree.row_height}
	for !view_layout(&host.tree, metrics) {}
}

@(test)
search_commit_jumps_to_the_first_match :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	host: Window
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	start := strings.concatenate({TREE_FIXTURE_ROOT, "/alpha"}, context.temp_allocator)
	testing.expect(t, tree_open(&host.tree, start))
	testing.expect_value(t, host.tree.columns[host.tree.active].entries[0].name, "nested")

	defer input_destroy(&host)
	host.input_mode = .Search
	append_query(&host, "one")
	search_layout(&host)
	search_commit(&host)

	column := &host.tree.columns[host.tree.active]
	testing.expect_value(t, column.entries[column.selected].name, "one.txt")
}

@(test)
input_history_walks_submitted_queries :: proc(t: ^testing.T) {
	host: Window
	defer input_destroy(&host)
	append_query(&host, "alpha")
	input_history_push(&host)
	input_reset(&host)
	append_query(&host, "beta")
	input_history_push(&host)
	input_reset(&host)

	input_history_move(&host, 1)
	testing.expect_value(t, input_text(&host), "beta")
	input_history_move(&host, 1)
	testing.expect_value(t, input_text(&host), "alpha")
	input_history_move(&host, -1)
	testing.expect_value(t, input_text(&host), "beta")
}

@(test)
search_jumps_into_a_listed_sibling_folder :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	host: Window
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	defer input_destroy(&host)
	testing.expect(t, tree_open(&host.tree, TREE_FIXTURE_ROOT+"/alpha"))
	host.input_mode = .Search
	append_query(&host, "two")
	search_layout(&host)
	search_commit(&host)

	column := &host.tree.columns[host.tree.active]
	testing.expect(t, strings.has_suffix(column.dir, "/beta"))
	testing.expect_value(t, column.entries[column.selected].name, "two.txt")
}

@(test)
search_jump_into_the_leftmost_column_keeps_its_parent_visible :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	host: Window
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	defer input_destroy(&host)
	testing.expect(t, tree_open(&host.tree, TREE_FIXTURE_ROOT+"/alpha"))
	host.input_mode = .Search
	append_query(&host, "beta")
	search_layout(&host)
	search_commit(&host)

	testing.expect_value(t, host.tree.active, 1)
	testing.expect(t, strings.has_suffix(host.tree.columns[1].dir, "hw_fileManager-tree-test"))
	selected := host.tree.columns[1].entries[host.tree.columns[1].selected]
	testing.expect_value(t, selected.name, "beta")
}
