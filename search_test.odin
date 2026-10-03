package file_manager

import "core:strings"
import "core:testing"

append_query :: proc(host: ^Host, value: string) {
	input_set(host, value)
}

@(test)
search_commit_jumps_to_the_first_match :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	host: Host
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	start := strings.concatenate({TREE_FIXTURE_ROOT, "/alpha"}, context.temp_allocator)
	testing.expect(t, tree_open(&host.tree, start))
	testing.expect_value(t, host.tree.columns[host.tree.active].entries[0].name, "nested")

	defer input_destroy(&host)
	host.input_mode = .Search
	append_query(&host, "one")
	search_commit(&host)

	column := &host.tree.columns[host.tree.active]
	testing.expect_value(t, column.entries[column.selected].name, "one.txt")
}

@(test)
input_history_walks_submitted_queries :: proc(t: ^testing.T) {
	host: Host
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
