package file_manager

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

action_fixture_path :: proc(parts: ..string) -> string {
	all := make([dynamic]string, 0, len(parts)+1, context.temp_allocator)
	append(&all, TREE_FIXTURE_ROOT)
	for part in parts {append(&all, part)}
	joined, _ := filepath.join(all[:], context.temp_allocator)
	return joined
}

@(test)
action_copy_then_paste_moves_the_file :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	host: Host
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	defer if len(host.copy_path) > 0 {delete(host.copy_path, context.allocator)}
	start := action_fixture_path("alpha")
	testing.expect(t, tree_open(&host.tree, start))
	testing.expect(t, tree_move(&host.tree, 1))

	action_copy(&host)
	testing.expect(t, strings.has_suffix(host.copy_path, "/alpha/one.txt"))

	testing.expect(t, tree_select_name(&host.tree, 0, "beta"))
	testing.expect(t, tree_expand(&host.tree))
	action_paste(&host)
	testing.expect(t, os.exists(action_fixture_path("beta", "one.txt")))
	testing.expect(t, !os.exists(action_fixture_path("alpha", "one.txt")))
}

@(test)
edit_rename_and_new_file_apply_names :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	host: Host
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	testing.expect(t, tree_open(&host.tree, action_fixture_path("alpha")))
	testing.expect(t, tree_move(&host.tree, 1))

	edit_begin(&host, .Rename)
	host.edit_len = 0
	renamed := "renamed.txt"
	for index in 0 ..< len(renamed) {edit_append(&host, renamed[index])}
	edit_commit(&host)
	testing.expect(t, os.exists(action_fixture_path("alpha", "renamed.txt")))

	edit_begin(&host, .NewFile)
	created := "created.txt"
	for index in 0 ..< len(created) {edit_append(&host, created[index])}
	edit_commit(&host)
	testing.expect(t, os.exists(action_fixture_path("alpha", "created.txt")))
}
