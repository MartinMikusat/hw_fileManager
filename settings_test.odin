package file_manager

import "core:os"
import "core:testing"

SETTINGS_TEST_PATH :: "/tmp/hw_fileManager-settings-test.json"

@(test)
settings_font_size_clamps_to_the_supported_range :: proc(t: ^testing.T) {
	testing.expect_value(t, settings_font_size_clamped(0), FONT_SIZE_MIN)
	testing.expect_value(t, settings_font_size_clamped(FONT_SIZE_MIN-5), FONT_SIZE_MIN)
	testing.expect_value(t, settings_font_size_clamped(18), 18)
	testing.expect_value(t, settings_font_size_clamped(FONT_SIZE_MAX+9), FONT_SIZE_MAX)
}

@(test)
settings_round_trip_and_keep_active_values_on_a_bad_file :: proc(t: ^testing.T) {
	_ = os.remove(SETTINGS_TEST_PATH)
	defer os.remove(SETTINGS_TEST_PATH)

	settings := settings_defaults()
	testing.expect(t, !settings_load(SETTINGS_TEST_PATH, &settings))
	testing.expect_value(t, settings.font_size, DEFAULT_FONT_SIZE)

	testing.expect(t, settings_save(SETTINGS_TEST_PATH, {font_size = 20}))
	testing.expect(t, settings_load(SETTINGS_TEST_PATH, &settings))
	testing.expect_value(t, settings.font_size, 20)

	testing.expect(t, settings_save(SETTINGS_TEST_PATH, {font_size = 99}))
	testing.expect(t, settings_load(SETTINGS_TEST_PATH, &settings))
	testing.expect_value(t, settings.font_size, FONT_SIZE_MAX)

	testing.expect(t, os.write_entire_file(SETTINGS_TEST_PATH, "not json") == nil)
	testing.expect(t, !settings_load(SETTINGS_TEST_PATH, &settings))
	testing.expect_value(t, settings.font_size, FONT_SIZE_MAX)
}
