package file_manager

import "core:os"
import "core:testing"
import "core:time"

@(test)
entry_color_fades_by_age :: proc(t: ^testing.T) {
	now := time.now()
	// A fresh file is the blue end; anything past the span is plain text.
	testing.expect_value(t, entry_color(now, now, false), COLOR_RECENT)
	testing.expect_value(t, entry_color(time.time_add(now, -60*24*time.Hour), now, false), COLOR_TEXT)
	testing.expect_value(t, entry_color(now, now, true), COLOR_DIM)
	mid := entry_color(time.time_add(now, -ENTRY_AGE_SPAN/2), now, false)
	testing.expect(t, mid != COLOR_RECENT && mid != COLOR_TEXT)
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

	entries, ok := read_entries(TREE_FIXTURE_ROOT)
	testing.expect(t, ok)
	defer entries_destroy(entries)
	for entry in entries {
		if entry.name == "link" {testing.expect(t, entry.is_dir)}
	}
}
