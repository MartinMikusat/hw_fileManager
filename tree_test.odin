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
	testing.expect_value(t, len(tree.columns), 2)
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

	// Selecting a directory cascades into it immediately.
	testing.expect(t, tree_move(&tree, -1))
	testing.expect_value(t, tree.columns[1].entries[tree.columns[1].selected].name, "nested")
	testing.expect_value(t, len(tree.columns), 3)
	testing.expect_value(t, tree.active, 2)

	testing.expect(t, tree_collapse(&tree))
	testing.expect_value(t, len(tree.columns), 2)
	testing.expect_value(t, tree.active, 1)

	testing.expect(t, tree_expand(&tree))
	testing.expect_value(t, len(tree.columns), 3)
	testing.expect_value(t, tree.active, 2)

	// Selecting a file drops every deeper column.
	testing.expect(t, tree_select(&tree, 1, 1))
	testing.expect_value(t, len(tree.columns), 2)
	testing.expect_value(t, tree.active, 1)
}
