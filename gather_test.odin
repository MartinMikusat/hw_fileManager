package file_manager

import "core:os"
import "core:strings"
import "core:testing"

@(test)
gather_keeps_the_shallowest_of_nested_paths :: proc(t: ^testing.T) {
	paths: [dynamic]string
	defer gather_destroy(&paths)

	gather_add(&paths, "/tmp/g/alpha")
	gather_add(&paths, "/tmp/g/alpha/one.txt")
	testing.expect_value(t, len(paths), 1)
	testing.expect_value(t, paths[0], "/tmp/g/alpha")

	gather_add(&paths, "/tmp/g/beta")
	testing.expect_value(t, len(paths), 2)

	gather_remove(&paths, "/tmp/g/beta")
	testing.expect_value(t, len(paths), 1)
}

@(test)
gather_remap_follows_a_rename_and_its_children :: proc(t: ^testing.T) {
	paths: [dynamic]string
	defer gather_destroy(&paths)

	gather_add(&paths, "/tmp/g/alpha/one.txt")
	gather_remap(&paths, "/tmp/g/alpha", "/tmp/g/renamed")
	testing.expect_value(t, paths[0], "/tmp/g/renamed/one.txt")
}

@(test)
gather_prune_drops_missing_paths :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	paths: [dynamic]string
	defer gather_destroy(&paths)
	gather_add(&paths, action_fixture_path("top.txt"))
	gather_add(&paths, action_fixture_path("gone.txt"))
	testing.expect_value(t, gather_prune(&paths), 1)
	testing.expect_value(t, len(paths), 1)
}

@(test)
action_copy_of_the_gathered_set_fills_the_clipboard :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	host: Window
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	defer gather_destroy(&host.gather_paths)
	defer action_clear_clip(&host)

	gather_add(&host.gather_paths, action_fixture_path("top.txt"))
	gather_add(&host.gather_paths, action_fixture_path("alpha", "one.txt"))
	action_clip(&host, false)
	testing.expect_value(t, len(app.clip_paths), 2)
}

@(test)
edit_new_folder_mode_creates_a_directory :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	host: Window
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	defer edit_cancel(&host)
	testing.expect(t, tree_open(&host.tree, action_fixture_path("alpha")))

	edit_begin(&host, .NewFolder)
	delete(host.edit_value, context.allocator)
	host.edit_value = strings.clone("made", context.allocator)
	edit_commit(&host)
	testing.expect(t, os.is_dir(action_fixture_path("alpha", "made")))
}

@(test)
action_delete_removes_gathered_paths_permanently :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	host: Window
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	defer gather_destroy(&host.gather_paths)

	gather_add(&host.gather_paths, action_fixture_path("top.txt"))
	gather_add(&host.gather_paths, action_fixture_path("alpha", "one.txt"))
	action_delete(&host)
	testing.expect(t, !os.exists(action_fixture_path("top.txt")))
	testing.expect(t, !os.exists(action_fixture_path("alpha", "one.txt")))
	testing.expect_value(t, len(host.gather_paths), 0)
}
