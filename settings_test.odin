package file_manager

import "core:os"
import "core:testing"
import ui "ui_framework:core"

SETTINGS_TEST_PATH :: "/tmp/hw_fileManager-settings-test.json"

@(test)
settings_panel_hit_testing_separates_backdrop_from_controls :: proc(t: ^testing.T) {
	tree := Tree{row_height = 16}
	metrics := View_Metrics{width = 1100, height = 720, char_advance = 8, row_height = 16}
	layout := view_settings_layout(&tree, metrics)
	center := ui.Vec2{layout.panel.x+layout.panel.w/2, layout.panel.y+layout.panel.h/2}
	_, inside := view_settings_hot(layout, center)
	testing.expect(t, inside, "panel centre is inside the modal")
	_, inside = view_settings_hot(layout, {layout.panel.x-1, layout.panel.y-1})
	testing.expect(t, !inside, "backdrop is outside the modal")
	hot, _ := view_settings_hot(layout, {layout.minus.x+layout.minus.w/2, layout.minus.y+layout.minus.h/2})
	testing.expect_value(t, hot, Settings_Hot.Minus)
	hot, _ = view_settings_hot(layout, {layout.plus.x+layout.plus.w/2, layout.plus.y+layout.plus.h/2})
	testing.expect_value(t, hot, Settings_Hot.Plus)
}

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

	testing.expect(t, settings_save(SETTINGS_TEST_PATH, {font_size = 20, window = {10, 20, 800, 600}}))
	testing.expect(t, settings_load(SETTINGS_TEST_PATH, &settings))
	testing.expect_value(t, settings.font_size, 20)
	testing.expect_value(t, settings.window, Window_Frame{10, 20, 800, 600})

	testing.expect(t, settings_save(SETTINGS_TEST_PATH, {font_size = 99}))
	testing.expect(t, settings_load(SETTINGS_TEST_PATH, &settings))
	testing.expect_value(t, settings.font_size, FONT_SIZE_MAX)

	testing.expect(t, os.write_entire_file(SETTINGS_TEST_PATH, "not json") == nil)
	testing.expect(t, !settings_load(SETTINGS_TEST_PATH, &settings))
	testing.expect_value(t, settings.font_size, FONT_SIZE_MAX)
}
