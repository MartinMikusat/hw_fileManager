package file_manager

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import text_input "components:text_input"

action_fixture_path :: proc(parts: ..string) -> string {
	all := make([dynamic]string, 0, len(parts)+1, context.temp_allocator)
	append(&all, TREE_FIXTURE_ROOT)
	for part in parts {append(&all, part)}
	joined, _ := filepath.join(all[:], context.temp_allocator)
	return joined
}

@(test)
action_cut_then_paste_moves_the_file :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	host: Host
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	defer action_clear_clip(&host)
	testing.expect(t, tree_open(&host.tree, action_fixture_path("alpha")))
	testing.expect(t, tree_move(&host.tree, 1))

	action_clip(&host, true)
	testing.expect(t, strings.has_suffix(host.clip_path, "/alpha/one.txt"))

	testing.expect(t, tree_select_name(&host.tree, 0, "beta"))
	testing.expect(t, tree_expand(&host.tree))
	action_paste(&host)
	testing.expect(t, os.exists(action_fixture_path("beta", "one.txt")))
	testing.expect(t, !os.exists(action_fixture_path("alpha", "one.txt")))
}

@(test)
action_paste_targets_the_selected_folder_without_entering_it :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	host: Host
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	defer action_clear_clip(&host)
	testing.expect(t, tree_open(&host.tree, action_fixture_path("alpha")))
	testing.expect(t, tree_move(&host.tree, 1))

	action_clip(&host, true)
	testing.expect(t, tree_select_name(&host.tree, 0, "beta"))
	action_paste(&host)
	testing.expect(t, os.exists(action_fixture_path("beta", "one.txt")))
	testing.expect(t, !os.exists(action_fixture_path("alpha", "one.txt")))
}

@(test)
action_paste_refuses_a_folder_inside_itself :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	host: Host
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	defer action_clear_clip(&host)
	testing.expect(t, tree_open(&host.tree, TREE_FIXTURE_ROOT))
	testing.expect(t, tree_select_name(&host.tree, host.tree.active, "alpha"))

	action_clip(&host, false)
	action_paste(&host)
	testing.expect(t, !os.exists(action_fixture_path("alpha", "alpha")))
	testing.expect(t, !os.exists(action_fixture_path("alpha", "alpha copy")))
}

@(test)
action_copy_then_paste_duplicates_the_file :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	host: Host
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	defer action_clear_clip(&host)
	testing.expect(t, tree_open(&host.tree, action_fixture_path("alpha")))
	testing.expect(t, tree_move(&host.tree, 1))

	action_clip(&host, false)
	testing.expect(t, tree_select_name(&host.tree, 0, "beta"))
	testing.expect(t, tree_expand(&host.tree))
	action_paste(&host)
	testing.expect(t, os.exists(action_fixture_path("beta", "one.txt")))
	testing.expect(t, os.exists(action_fixture_path("alpha", "one.txt")))
}

@(test)
action_copy_paste_twice_renames_the_duplicate :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	host: Host
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	defer action_clear_clip(&host)
	testing.expect(t, tree_open(&host.tree, action_fixture_path("alpha")))
	testing.expect(t, tree_move(&host.tree, 1))

	action_clip(&host, false)
	testing.expect(t, tree_select_name(&host.tree, 0, "beta"))
	testing.expect(t, tree_expand(&host.tree))
	action_paste(&host)
	action_paste(&host)
	testing.expect(t, os.exists(action_fixture_path("beta", "one.txt")))
	testing.expect(t, os.exists(action_fixture_path("beta", "one copy.txt")))
	testing.expect(t, os.exists(action_fixture_path("alpha", "one.txt")))
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
	delete(host.edit_value, context.allocator)
	host.edit_value = strings.clone("renamed.txt", context.allocator)
	edit_commit(&host)
	testing.expect(t, os.exists(action_fixture_path("alpha", "renamed.txt")))

	edit_begin(&host, .NewFile)
	delete(host.edit_value, context.allocator)
	host.edit_value = strings.clone("created.txt", context.allocator)
	edit_commit(&host)
	testing.expect(t, os.exists(action_fixture_path("alpha", "created.txt")))
}

@(test)
edit_refuses_an_existing_name :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	host: Host
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	defer edit_cancel(&host)
	testing.expect(t, tree_open(&host.tree, action_fixture_path("alpha")))
	testing.expect(t, tree_move(&host.tree, 1))

	edit_begin(&host, .Rename)
	delete(host.edit_value, context.allocator)
	host.edit_value = strings.clone("nested", context.allocator)
	testing.expect(t, edit_conflict(&host))
	edit_commit(&host)
	testing.expect(t, os.exists(action_fixture_path("alpha", "one.txt")))
}

@(test)
rename_repro :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()
	handle, _ := os.create(action_fixture_path("hello there.txt"))
	os.close(handle)

	host: Host
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	defer edit_cancel(&host)
	testing.expect(t, tree_open(&host.tree, TREE_FIXTURE_ROOT))
	for index in 0 ..< len(host.tree.columns[host.tree.active].entries) {
		_ = tree_select(&host.tree, host.tree.active, index, enter = false)
	}
	testing.expect(t, tree_select_name(&host.tree, host.tree.active, "hello there.txt"))

	edit_begin(&host, .Rename)
	testing.expect_value(t, host.edit_value, "hello there.txt")
	delete(host.edit_value, context.allocator)
	host.edit_value = strings.clone("hello there, mate.txt", context.allocator)
	testing.expect(t, !edit_conflict(&host))
	edit_commit(&host)
	testing.expect(t, os.exists(action_fixture_path("hello there, mate.txt")))
	testing.expect(t, !os.exists(action_fixture_path("hello there.txt")))

	testing.expect(t, tree_select_name(&host.tree, host.tree.active, "hello there, mate.txt"))
	edit_begin(&host, .Rename)
	delete(host.edit_value, context.allocator)
	host.edit_value = strings.clone("hello there, mate 2.txt", context.allocator)
	testing.expect(t, !edit_conflict(&host))
	edit_commit(&host)
	testing.expect(t, os.exists(action_fixture_path("hello there, mate 2.txt")))
}

@(test)
rename_after_typing_applies :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()
	handle, _ := os.create(action_fixture_path("hello there.txt"))
	os.close(handle)

	host: Host
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	defer edit_cancel(&host)
	testing.expect(t, tree_open(&host.tree, TREE_FIXTURE_ROOT))
	testing.expect(t, tree_select_name(&host.tree, host.tree.active, "hello there.txt"))

	edit_begin(&host, .Rename)
	text_input.set_selection(&host.text_state, host.edit_value, 0, len(host.edit_value))
	testing.expect(t, text_input.insert_text(&host.text_state, &host.edit_value, "hello there, mate.txt"))
	testing.expect_value(t, host.edit_value, "hello there, mate.txt")
	edit_commit(&host)
	testing.expect(t, os.exists(action_fixture_path("hello there, mate.txt")))
}
