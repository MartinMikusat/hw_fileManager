package file_manager

import "core:testing"
import "core:time"

@(test)
entry_color_buckets_by_age :: proc(t: ^testing.T) {
	now := time.now()
	testing.expect_value(t, entry_color(now, now, false), COLOR_SOURCE)
	testing.expect_value(t, entry_color(time.time_add(now, -2*time.Hour), now, false), COLOR_DIRECTORY)
	testing.expect_value(t, entry_color(time.time_add(now, -3*24*time.Hour), now, false), COLOR_DOCUMENT)
	testing.expect_value(t, entry_color(time.time_add(now, -60*24*time.Hour), now, false), COLOR_IMAGE)
	testing.expect_value(t, entry_color(now, now, true), COLOR_DIM)
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
