package file_manager

import "core:testing"

@(test)
cd_common_prefix_ignores_case :: proc(t: ^testing.T) {
	testing.expect_value(t, cd_common_prefix([]string{"hw_calendar", "HW_clips", "hw_cal_old"}), 4)
	testing.expect_value(t, cd_common_prefix([]string{"alpha"}), 5)
	testing.expect_value(t, cd_common_prefix([]string{"alpha", "beta"}), 0)
}

@(test)
cd_prefix_match_ignores_case :: proc(t: ^testing.T) {
	testing.expect(t, name_has_prefix_fold("Documents", "doc"))
	testing.expect(t, !name_has_prefix_fold("Documents", "docs"))
}
