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
	hot, _ = view_settings_hot(layout, {layout.previous.x+layout.previous.w/2, layout.previous.y+layout.previous.h/2})
	testing.expect_value(t, hot, Settings_Hot.Previous)
	hot, _ = view_settings_hot(layout, {layout.next.x+layout.next.w/2, layout.next.y+layout.next.h/2})
	testing.expect_value(t, hot, Settings_Hot.Next)
	hot, _ = view_settings_hot(layout, {layout.animations.x+layout.animations.w/2, layout.animations.y+layout.animations.h/2})
	testing.expect_value(t, hot, Settings_Hot.Animations)
	hot, _ = view_settings_hot(layout, {layout.editor_previous.x+layout.editor_previous.w/2, layout.editor_previous.y+layout.editor_previous.h/2})
	testing.expect_value(t, hot, Settings_Hot.EditorPrevious)
	hot, _ = view_settings_hot(layout, {layout.editor_next.x+layout.editor_next.w/2, layout.editor_next.y+layout.editor_next.h/2})
	testing.expect_value(t, hot, Settings_Hot.EditorNext)
	hot, _ = view_settings_hot(layout, {layout.editor_custom.x+layout.editor_custom.w/2, layout.editor_custom.y+layout.editor_custom.h/2})
	testing.expect_value(t, hot, Settings_Hot.EditorCustom)
	hot, _ = view_settings_hot(layout, {layout.syntax_previous.x+layout.syntax_previous.w/2, layout.syntax_previous.y+layout.syntax_previous.h/2})
	testing.expect_value(t, hot, Settings_Hot.SyntaxPrevious)
	hot, _ = view_settings_hot(layout, {layout.syntax_next.x+layout.syntax_next.w/2, layout.syntax_next.y+layout.syntax_next.h/2})
	testing.expect_value(t, hot, Settings_Hot.SyntaxNext)
	hot, _ = view_settings_hot(layout, {layout.font_previous.x+layout.font_previous.w/2, layout.font_previous.y+layout.font_previous.h/2})
	testing.expect_value(t, hot, Settings_Hot.FontPrevious)
	hot, _ = view_settings_hot(layout, {layout.font_next.x+layout.font_next.w/2, layout.font_next.y+layout.font_next.h/2})
	testing.expect_value(t, hot, Settings_Hot.FontNext)
	hot, _ = view_settings_hot(layout, {layout.font_custom.x+layout.font_custom.w/2, layout.font_custom.y+layout.font_custom.h/2})
	testing.expect_value(t, hot, Settings_Hot.FontCustom)
	hot, _ = view_settings_hot(layout, {layout.weight_previous.x+layout.weight_previous.w/2, layout.weight_previous.y+layout.weight_previous.h/2})
	testing.expect_value(t, hot, Settings_Hot.WeightPrevious)
	hot, _ = view_settings_hot(layout, {layout.weight_next.x+layout.weight_next.w/2, layout.weight_next.y+layout.weight_next.h/2})
	testing.expect_value(t, hot, Settings_Hot.WeightNext)
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

	testing.expect(t, settings_save(SETTINGS_TEST_PATH, {font_size = 20, window = {10, 20, 800, 600}, place = "/tmp/place"}))
	testing.expect(t, settings_load(SETTINGS_TEST_PATH, &settings))
	defer delete(settings.place)
	testing.expect_value(t, settings.place, "/tmp/place")
	testing.expect_value(t, settings.font_size, 20)
	testing.expect_value(t, settings.window, Window_Frame{10, 20, 800, 600})

	testing.expect(t, settings_save(SETTINGS_TEST_PATH, {font_size = 99}))
	testing.expect(t, settings_load(SETTINGS_TEST_PATH, &settings))
	testing.expect_value(t, settings.font_size, FONT_SIZE_MAX)

	testing.expect(t, os.write_entire_file(SETTINGS_TEST_PATH, "not json") == nil)
	testing.expect(t, !settings_load(SETTINGS_TEST_PATH, &settings))
	testing.expect_value(t, settings.font_size, FONT_SIZE_MAX)
}

@(test)
terminal_picker_steps_through_installed_apps_and_round_trips :: proc(t: ^testing.T) {
	found := Terminals{names = {0 = "Ghostty", 1 = "Terminal"}, count = 2}
	testing.expect_value(t, terminal_effective("", found), "Ghostty")
	testing.expect_value(t, terminal_effective("", Terminals{}), TERMINAL_FALLBACK)
	next, ok := terminal_step("", found, 1)
	testing.expect(t, ok)
	testing.expect_value(t, next, "Terminal")
	previous, _ := terminal_step("Ghostty", found, -1)
	testing.expect_value(t, previous, "Terminal")
	custom, _ := terminal_step("Custom", found, 1)
	testing.expect_value(t, custom, "Ghostty")
	_, ok = terminal_step("", Terminals{}, 1)
	testing.expect(t, !ok)

	_ = os.remove(SETTINGS_TEST_PATH)
	defer os.remove(SETTINGS_TEST_PATH)
	testing.expect(t, settings_save(SETTINGS_TEST_PATH, {font_size = 14, terminal = "WezTerm", animations_off = true, editor = "Zed", syntax_theme = "Nord", font_family = "JetBrains Mono", font_weight = "Bold"}))
	loaded := settings_defaults()
	testing.expect(t, settings_load(SETTINGS_TEST_PATH, &loaded))
	defer delete(loaded.terminal)
	testing.expect_value(t, loaded.terminal, "WezTerm")
	testing.expect(t, loaded.animations_off)
	defer delete(loaded.editor)
	testing.expect_value(t, loaded.editor, "Zed")
	defer delete(loaded.syntax_theme)
	testing.expect_value(t, loaded.syntax_theme, "Nord")
	defer delete(loaded.font_family)
	defer delete(loaded.font_weight)
	testing.expect_value(t, loaded.font_family, "JetBrains Mono")
	testing.expect_value(t, loaded.font_weight, "Bold")
}

@(test)
editor_picker_starts_at_the_system_default_and_validates_typed_apps :: proc(t: ^testing.T) {
	found := Editors{names = {1 = "Zed", 2 = "TextEdit"}, count = 3}
	testing.expect_value(t, editor_step("", found, 1), "Zed")
	testing.expect_value(t, editor_step("Zed", found, 1), "TextEdit")
	testing.expect_value(t, editor_step("TextEdit", found, 1), "")
	testing.expect_value(t, editor_step("", found, -1), "TextEdit")
	testing.expect_value(t, editor_step("Custom", found, 1), "")
	testing.expect_value(t, editor_label(""), EDITOR_DEFAULT_LABEL)
	testing.expect(t, editor_valid("TextEdit"))
	testing.expect(t, editor_valid("TextEdit.app"))
	testing.expect(t, editor_valid("/System/Applications/TextEdit.app"))
	testing.expect(t, !editor_valid("No Such Editor App"))
	testing.expect(t, !editor_valid("/etc/passwd"))
	testing.expect(t, !editor_valid(""))
}

@(test)
syntax_themes_are_distinct_named_and_step_around :: proc(t: ^testing.T) {
	testing.expect_value(t, SYNTAX_THEME_NAMES[0], "Default")
	testing.expect_value(t, syntax_theme_index("Monokai"), 2)
	testing.expect_value(t, syntax_theme_index("No such theme"), 0)
	testing.expect_value(t, syntax_theme_index(""), 0)
	testing.expect_value(t, syntax_theme_step("Default", -1), "Tokyo Night")
	testing.expect_value(t, syntax_theme_step("Tokyo Night", 1), "Default")
	testing.expect_value(t, syntax_theme_step("", 1), "Gruvbox")
	for index in 0 ..< len(SYNTAX_THEME_NAMES) {
		colors := syntax_theme(index)
		for kind in Syntax_Kind {testing.expect(t, colors[kind].a == 1, SYNTAX_THEME_NAMES[index])}
		if index > 0 {testing.expect(t, colors != syntax_theme(0), SYNTAX_THEME_NAMES[index])}
	}
}

@(test)
font_picker_steps_families_and_weights_and_picks_the_nearest_regular :: proc(t: ^testing.T) {
	catalog := Font_Catalog{}
	defer delete(catalog.faces)
	defer delete(catalog.families)
	faces := []Font_Face{
		{family = "Mono A", style = "Bold", postscript = "MonoA-Bold", weight = 0.4},
		{family = "Mono A", style = "Light", postscript = "MonoA-Light", weight = -0.23},
		{family = "Mono A", style = "Regular", postscript = "MonoA", weight = 0},
		{family = "Mono A", style = "Italic", postscript = "MonoA-It", weight = 0, italic = true},
		{family = "Mono A", style = "Wide Bold", postscript = "MonoA-WideBold", weight = 0.4},
		{family = "Mono B", style = "Semi-Condensed", postscript = "MonoB-SC", weight = 0},
		{family = "Mono B", style = "Bold Semi-Condensed", postscript = "MonoB-BSC", weight = 0.4},
		{family = "Mono B", style = "Bold Semi-Condensed 2", postscript = "MonoB-BSC2", weight = 0.4},
	}
	for face in faces {append(&catalog.faces, face)}
	font_catalog_index(&catalog)
	testing.expect_value(t, len(catalog.families), 2)

	testing.expect_value(t, font_family_step(&catalog, "", 1), "Mono A")
	testing.expect_value(t, font_family_step(&catalog, "Mono A", 1), "Mono B")
	testing.expect_value(t, font_family_step(&catalog, "Mono B", 1), "")
	testing.expect_value(t, font_family_step(&catalog, "", -1), "Mono B")

	weights := font_family_weights(&catalog, "Mono A")
	testing.expect_value(t, len(weights), 3)
	testing.expect_value(t, weights[0].style, "Light")
	testing.expect_value(t, weights[2].style, "Bold")
	testing.expect_value(t, font_weight_step(&catalog, "Mono A", "Regular", 1), "Bold")
	testing.expect_value(t, font_weight_step(&catalog, "Mono A", "Light", -1), "Bold")
	testing.expect_value(t, font_effective_style(&catalog, "Mono A", "Missing"), "Regular")
	testing.expect_value(t, font_effective_style(&catalog, "", "Bold"), "Regular")
	// A family with no plain weight names offers one face per weight.
	testing.expect_value(t, len(font_family_weights(&catalog, "Mono B")), 2)
	known, ok := font_family_known(&catalog, "mono a")
	testing.expect(t, ok)
	testing.expect_value(t, known, "Mono A")
	_, ok = font_family_known(&catalog, "Helvetica")
	testing.expect(t, !ok)
}
