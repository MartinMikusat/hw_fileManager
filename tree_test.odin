package file_manager

import "core:os"
import "core:strings"
import "core:testing"

TREE_FIXTURE_ROOT :: "/tmp/hw_fileManager-tree-test"

tree_fixture_create :: proc(t: ^testing.T) {
	_ = os.remove_all(TREE_FIXTURE_ROOT)
	directories := []string{
		TREE_FIXTURE_ROOT,
		strings.concatenate({TREE_FIXTURE_ROOT, "/alpha"}, context.temp_allocator),
		strings.concatenate({TREE_FIXTURE_ROOT, "/alpha/nested"}, context.temp_allocator),
		strings.concatenate({TREE_FIXTURE_ROOT, "/beta"}, context.temp_allocator),
	}
	for directory in directories {
		if error := os.make_directory_all(directory); error != nil {
			testing.fail_now(t, "fixture directory could not be created")
		}
	}
	files := []string{
		strings.concatenate({TREE_FIXTURE_ROOT, "/top.txt"}, context.temp_allocator),
		strings.concatenate({TREE_FIXTURE_ROOT, "/alpha/one.txt"}, context.temp_allocator),
		strings.concatenate({TREE_FIXTURE_ROOT, "/alpha/nested/deep.txt"}, context.temp_allocator),
		strings.concatenate({TREE_FIXTURE_ROOT, "/beta/two.txt"}, context.temp_allocator),
	}
	for file in files {
		handle, error := os.create(file)
		if error != nil {testing.fail_now(t, "fixture file could not be created")}
		os.close(handle)
	}
}

tree_fixture_destroy :: proc() {
	_ = os.remove_all(TREE_FIXTURE_ROOT)
}

@(test)
tree_open_selects_the_starting_directory_in_its_parent :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)

	start := strings.concatenate({TREE_FIXTURE_ROOT, "/alpha"}, context.temp_allocator)
	testing.expect(t, tree_open(&tree, start))
	// alpha's first entry is a folder, shown a second level deep.
	testing.expect_value(t, len(tree.columns), 3)
	testing.expect_value(t, tree.active, 1)
	testing.expect_value(t, tree.columns[0].entries[tree.columns[0].selected].name, "alpha")
	// read_dir reports canonical paths, so /tmp may arrive as /private/tmp.
	testing.expect(t, strings.has_suffix(tree.columns[1].dir, "/alpha"))
}

@(test)
tree_refresh_preserves_selections :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	start := strings.concatenate({TREE_FIXTURE_ROOT, "/alpha"}, context.temp_allocator)
	testing.expect(t, tree_open(&tree, start))
	testing.expect(t, tree_move(&tree, 1))
	testing.expect(t, tree_select(&tree, 0, 1))

	testing.expect(t, tree_refresh(&tree))
	testing.expect_value(t, len(tree.columns), 2)
	testing.expect_value(t, tree.active, 1)
	testing.expect_value(t, tree.columns[0].entries[tree.columns[0].selected].name, "beta")
	testing.expect_value(t, tree.columns[1].entries[tree.columns[1].selected].name, "two.txt")
}

@(test)
tree_open_reports_a_missing_starting_directory :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	missing := strings.concatenate({TREE_FIXTURE_ROOT, "/absent"}, context.temp_allocator)
	testing.expect(t, !tree_open(&tree, missing))
}

@(test)
tree_navigation_cascades_and_collapses :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	start := strings.concatenate({TREE_FIXTURE_ROOT, "/alpha"}, context.temp_allocator)
	testing.expect(t, tree_open(&tree, start))

	// alpha lists nested/ then one.txt; moving onto the file keeps two columns.
	testing.expect(t, tree_move(&tree, 1))
	testing.expect_value(t, len(tree.columns), 2)
	testing.expect_value(t, tree.active, 1)
	testing.expect_value(t, tree.columns[1].entries[tree.columns[1].selected].name, "one.txt")

	// Selecting a directory previews it immediately but keeps the focus here;
	// the right arrow enters the preview.
	testing.expect(t, tree_move(&tree, -1))
	testing.expect_value(t, tree.columns[1].entries[tree.columns[1].selected].name, "nested")
	testing.expect_value(t, len(tree.columns), 3)
	testing.expect_value(t, tree.active, 1)

	testing.expect(t, tree_expand(&tree))
	testing.expect_value(t, tree.active, 2)

	testing.expect(t, tree_collapse(&tree))
	testing.expect_value(t, len(tree.columns), 3)
	testing.expect_value(t, tree.active, 1)
	testing.expect(t, strings.has_suffix(tree.columns[2].dir, "/alpha/nested"))

	// Selecting a file drops every deeper column.
	testing.expect(t, tree_select(&tree, 1, 1))
	testing.expect_value(t, len(tree.columns), 2)
	testing.expect_value(t, tree.active, 1)
}

@(test)
tree_move_continues_into_the_neighbouring_folder :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	testing.expect(t, tree_open(&tree, TREE_FIXTURE_ROOT+"/alpha"))
	testing.expect(t, tree_move(&tree, 1))
	testing.expect(t, tree_move(&tree, 1))
	entry, ok := tree_selected_entry(&tree)
	testing.expect(t, ok && entry.name == "two.txt")
	testing.expect_value(t, tree.active, 1)

	testing.expect(t, tree_move(&tree, -1))
	entry, ok = tree_selected_entry(&tree)
	testing.expect(t, ok && entry.name == "one.txt")
	testing.expect(t, tree_move(&tree, 1))
	entry, ok = tree_selected_entry(&tree)
	testing.expect(t, ok && entry.name == "two.txt")
}

@(test)
trail_aligns_the_nearest_folder_end_with_its_row :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	testing.expect(t, tree_open(&tree, TREE_FIXTURE_ROOT))
	testing.expect(t, tree_select_name(&tree, tree.active, "top.txt"))
	metrics := View_Metrics{width = 1000, height = 700, char_advance = 8, row_height = tree.row_height, bar_height = 2*tree.row_height}
	for !view_layout(&tree, metrics) {}

	column := &tree.columns[tree.active]
	testing.expect_value(t, len(column.trail), 2)
	nearest := column.trail[0]
	testing.expect_value(t, column.entries[nearest.row].name, "beta")
	last_row_y := nearest.y+f32(len(nearest.entries)-1)*tree.row_height
	testing.expect_value(t, last_row_y, column.y+f32(nearest.row)*tree.row_height)
	testing.expect(t, column.trail[1].y < nearest.y)
}

@(test)
tree_refresh_drops_the_column_of_a_deleted_directory :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	host: Host
	tree_init(&host.tree)
	defer tree_destroy(&host.tree)
	defer gather_destroy(&host.gather_paths)
	testing.expect(t, tree_open(&host.tree, action_fixture_path("alpha")))
	testing.expect_value(t, len(host.tree.columns), 3)

	gather_add(&host.gather_paths, action_fixture_path("alpha"))
	action_delete(&host)
	testing.expect(t, !os.exists(action_fixture_path("alpha")))
	// The selection falls to the neighbouring folder, previewed beside it.
	testing.expect(t, strings.has_suffix(host.tree.columns[1].dir, "/beta"))
	testing.expect_value(t, host.tree.active, 0)
	testing.expect_value(t, host.tree.columns[0].entries[host.tree.columns[0].selected].name, "beta")
}

@(test)
tree_collapse_keeps_the_parent_selection_previewed :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	testing.expect(t, tree_open(&tree, TREE_FIXTURE_ROOT))
	testing.expect_value(t, tree.active, 1)
	testing.expect_value(t, len(tree.columns), 3)

	preview := tree.columns[1].dir
	testing.expect(t, tree_collapse(&tree))
	testing.expect_value(t, tree.active, 0)
	// The parent stays focused but its selected folder is still shown beside it.
	testing.expect_value(t, len(tree.columns), 3)
	testing.expect_value(t, tree.columns[1].dir, preview)
}

@(test)
tree_collapse_at_the_root_column_adds_its_parent :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	testing.expect(t, tree_open(&tree, strings.concatenate({TREE_FIXTURE_ROOT, "/alpha/nested"}, context.temp_allocator)))
	testing.expect(t, tree_focus_column(&tree, 0))
	root := tree.columns[0].dir

	testing.expect(t, tree_collapse(&tree))
	testing.expect_value(t, tree.active, 0)
	testing.expect_value(t, tree.columns[1].dir, root)
	testing.expect_value(t, tree.columns[0].entries[tree.columns[0].selected].name, "alpha")
}

@(test)
tree_select_previews_two_levels_and_open_adds_a_grandparent :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()

	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	testing.expect(t, tree_open(&tree, TREE_FIXTURE_ROOT, grandparent = true))
	// [/, /tmp, root, alpha]: a grandparent in front, the first folder previewed behind.
	testing.expect_value(t, tree.active, 2)
	testing.expect_value(t, len(tree.columns), 4)
	testing.expect(t, strings.has_suffix(tree.columns[3].dir, "/alpha"))
}
