package file_manager

import "core:testing"
import "core:time"

@(test)
entry_color_fades_by_age :: proc(t: ^testing.T) {
	now := time.now()
	// A fresh file is the blue end; anything past the span clamps to orange.
	testing.expect_value(t, entry_color(now, now, false), COLOR_RECENT)
	testing.expect_value(t, entry_color(time.time_add(now, -60*24*time.Hour), now, false), COLOR_STALE)
	testing.expect_value(t, entry_color(now, now, true), COLOR_DIM)
	mid := entry_color(time.time_add(now, -ENTRY_AGE_SPAN/2), now, false)
	testing.expect(t, mid != COLOR_RECENT && mid != COLOR_STALE)
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
