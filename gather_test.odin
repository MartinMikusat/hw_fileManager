package file_manager

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

	host: Host
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	defer gather_destroy(&host.gather_paths)
	defer action_clear_clip(&host)

	gather_add(&host.gather_paths, action_fixture_path("top.txt"))
	gather_add(&host.gather_paths, action_fixture_path("alpha", "one.txt"))
	action_clip(&host, false)
	testing.expect_value(t, len(host.clip_paths), 2)
}
