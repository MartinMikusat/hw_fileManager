package file_manager

import "core:os"
import "core:testing"
import "core:time"

@(test)
entry_color_fades_by_recency_rank :: proc(t: ^testing.T) {
	// Rank 0 is the blue end; rank 1 is plain text; hidden entries stay dim.
	testing.expect_value(t, entry_color(0, false), COLOR_RECENT)
	testing.expect_value(t, entry_color(1, false), COLOR_TEXT)
	testing.expect_value(t, entry_color(0, true), COLOR_DIM)
	mid := entry_color(0.5, false)
	testing.expect(t, mid != COLOR_RECENT && mid != COLOR_TEXT)
}

@(test)
entry_recency_assign_ranks_newest_to_oldest :: proc(t: ^testing.T) {
	entries := []Entry{
		{name = "middle", modified = time.time_add(time.Time{}, 200)},
		{name = "oldest", modified = time.time_add(time.Time{}, 100)},
		{name = "newest", modified = time.time_add(time.Time{}, 300)},
	}
	entry_recency_assign(entries)
	testing.expect_value(t, entries[2].recency, f32(0))
	testing.expect_value(t, entries[0].recency, f32(0.5))
	testing.expect_value(t, entries[1].recency, f32(1))
}

@(test)
name_fold_orders_case_insensitively :: proc(t: ^testing.T) {
	testing.expect(t, name_less_fold("alpha", "Beta"))
	testing.expect(t, name_less_fold("Beta", "gamma"))
	testing.expect(t, !name_less_fold("Beta", "alpha"))
	testing.expect(t, !name_less_fold("same", "SAME"))
}

@(test)
name_contains_fold_matches_case_insensitively :: proc(t: ^testing.T) {
	testing.expect(t, name_contains_fold("pi-clipboard.png", "CLIP"))
	testing.expect(t, name_contains_fold("Alpha", "ph"))
	testing.expect(t, !name_contains_fold("alpha", "beta"))
	testing.expect(t, !name_contains_fold("ab", "abc"))
}

@(test)
read_entries_treats_a_symlink_to_a_folder_as_a_folder :: proc(t: ^testing.T) {
	tree_fixture_create(t)
	defer tree_fixture_destroy()
	testing.expect(t, os.symlink(TREE_FIXTURE_ROOT+"/beta", TREE_FIXTURE_ROOT+"/link") == nil)

	entries, ok := read_entries(TREE_FIXTURE_ROOT, SORT_DEFAULT)
	testing.expect(t, ok)
	defer entries_destroy(entries)
	for entry in entries {
		if entry.name == "link" {testing.expect(t, entry.is_dir)}
	}
}

@(test)
sort_parse_defaults_and_reads_direction :: proc(t: ^testing.T) {
	testing.expect_value(t, sort_parse(""), SORT_DEFAULT)
	testing.expect_value(t, sort_parse("nonsense"), SORT_DEFAULT)
	testing.expect_value(t, sort_parse("modified"), Sort{.Modified, false})
	testing.expect_value(t, sort_parse("modified-desc"), Sort{.Modified, true})
	testing.expect_value(t, sort_parse("size-desc"), Sort{.Size, true})
}

@(test)
sort_entries_orders_folders_first_then_by_key :: proc(t: ^testing.T) {
	entries := []Entry{
		{name = "beta", modified = time.time_add(time.Time{}, 200), size = 30},
		{name = "alpha", modified = time.time_add(time.Time{}, 300), size = 10},
		{name = "folder", is_dir = true, modified = time.time_add(time.Time{}, 100), size = 99},
	}
	expect_order :: proc(t: ^testing.T, entries: []Entry, expected: []string) {
		for name, index in expected {
			testing.expect_value(t, entries[index].name, name)
		}
	}

	sort_entries(entries, {.Name, false})
	expect_order(t, entries, {"folder", "alpha", "beta"})

	sort_entries(entries, {.Name, true})
	expect_order(t, entries, {"folder", "beta", "alpha"})

	sort_entries(entries, {.Modified, false})
	expect_order(t, entries, {"folder", "beta", "alpha"})

	sort_entries(entries, {.Modified, true})
	expect_order(t, entries, {"folder", "alpha", "beta"})

	sort_entries(entries, {.Size, false})
	expect_order(t, entries, {"folder", "alpha", "beta"})

	sort_entries(entries, {.Size, true})
	expect_order(t, entries, {"folder", "beta", "alpha"})
}
