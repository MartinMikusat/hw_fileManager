package file_manager

import "core:os"
import "core:testing"
import ui "ui_framework:core"

SETTINGS_TEST_PATH :: "/tmp/hw_fileManager-settings-test.json"

@(test)
settings_panel_hit_testing_separates_backdrop_from_controls :: proc(t: ^testing.T) {
	tree := Tree{row_height = 16}
	metrics := View_Metrics{width = 1100, height = 720, char_advance = 8, row_height = 16}
	for tab in Settings_Tab {
		layout := view_settings_layout(&tree, metrics, tab)
		center := ui.Vec2{layout.panel.x+layout.panel.w/2, layout.panel.y+layout.panel.h/2}
		_, inside := view_settings_hot(layout, center)
		testing.expect(t, inside, "panel centre is inside the modal")
		_, inside = view_settings_hot(layout, {layout.panel.x-1, layout.panel.y-1})
		testing.expect(t, !inside, "backdrop is outside the modal")
		testing.expect(t, layout.count > 2)
		for index in 0 ..< layout.count {
			control := layout.controls[index]
			hot, _ := view_settings_hot(layout, {control.rect.x+control.rect.w/2, control.rect.y+control.rect.h/2})
			testing.expect_value(t, hot, control.hot)
			testing.expect(t, control.rect.y+control.rect.h <= layout.panel.y+layout.panel.h, "control inside the panel")
		}
	}
	// A control only answers on its own tab.
	general := view_settings_layout(&tree, metrics, .General)
	font := view_settings_layout(&tree, metrics, .Font)
	has :: proc(layout: Settings_Layout, hot: Settings_Hot) -> bool {
		for index in 0 ..< layout.count {if layout.controls[index].hot == hot {return true}}
		return false
	}
	testing.expect(t, has(general, .Animations) && !has(font, .Animations))
	testing.expect(t, has(font, .WidthNext) && !has(general, .WidthNext))
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
	testing.expect(t, settings_save(SETTINGS_TEST_PATH, {font_size = 14, terminal = "WezTerm", animations_off = true, hints_off = true, editor = "Zed", syntax_theme = "Nord", font_family = "JetBrains Mono", font_weight = "Bold", font_width = "Wide", line_height = 180, letter_spacing = -4, sort = "modified-desc"}))
	loaded := settings_defaults()
	testing.expect(t, settings_load(SETTINGS_TEST_PATH, &loaded))
	defer delete(loaded.terminal)
	testing.expect_value(t, loaded.terminal, "WezTerm")
	testing.expect(t, loaded.animations_off)
	testing.expect(t, loaded.hints_off)
	defer delete(loaded.editor)
	testing.expect_value(t, loaded.editor, "Zed")
	defer delete(loaded.syntax_theme)
	testing.expect_value(t, loaded.syntax_theme, "Nord")
	defer delete(loaded.font_family)
	defer delete(loaded.font_weight)
	testing.expect_value(t, loaded.font_family, "JetBrains Mono")
	testing.expect_value(t, loaded.font_weight, "Bold")
	defer delete(loaded.font_width)
	testing.expect_value(t, loaded.font_width, "Wide")
	defer delete(loaded.sort)
	testing.expect_value(t, loaded.sort, "modified-desc")
	testing.expect_value(t, loaded.line_height, 180)
	testing.expect_value(t, loaded.letter_spacing, -4)
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
font_picker_steps_families_widths_and_weights :: proc(t: ^testing.T) {
	catalog := Font_Catalog{}
	defer delete(catalog.faces)
	defer delete(catalog.families)
	add :: proc(catalog: ^Font_Catalog, family, style, postscript: string, weight: f32, italic := false) {
		width, weight_style := font_split_style(style)
		append(&catalog.faces, Font_Face{family = family, style = style, width = width, weight_style = weight_style, postscript = postscript, weight = weight, italic = italic})
	}
	add(&catalog, "Mono A", "Bold", "MonoA-Bold", 0.4)
	add(&catalog, "Mono A", "Light", "MonoA-Light", -0.23)
	add(&catalog, "Mono A", "Regular", "MonoA", 0)
	add(&catalog, "Mono A", "Italic", "MonoA-It", 0, true)
	add(&catalog, "Mono A", "Wide Bold", "MonoA-WideBold", 0.4)
	add(&catalog, "Mono A", "Wide Regular", "MonoA-WideRegular", 0)
	add(&catalog, "Mono A", "SemiCondensed Regular", "MonoA-SCRegular", 0)
	add(&catalog, "Mono B", "Semi-Condensed", "MonoB-SC", 0)
	add(&catalog, "Mono B", "Bold Semi-Condensed", "MonoB-BSC", 0.4)
	font_catalog_index(&catalog)
	testing.expect_value(t, len(catalog.families), 2)

	testing.expect_value(t, font_family_step(&catalog, "", 1), "Mono A")
	testing.expect_value(t, font_family_step(&catalog, "Mono A", 1), "Mono B")
	testing.expect_value(t, font_family_step(&catalog, "Mono B", 1), "")
	testing.expect_value(t, font_family_step(&catalog, "", -1), "Mono B")

	widths := font_family_widths(&catalog, "Mono A")
	testing.expect_value(t, len(widths), 3)
	testing.expect_value(t, widths[0], "Semi Condensed")
	testing.expect_value(t, widths[1], "")
	testing.expect_value(t, widths[2], "Wide")
	testing.expect_value(t, font_width_step(&catalog, "Mono A", "", 1), "Wide")
	testing.expect_value(t, font_width_step(&catalog, "Mono A", "Wide", 1), "Semi Condensed")
	testing.expect_value(t, font_effective_width(&catalog, "Mono A", "Condensed"), "")
	// A family with no normal width falls to its narrowest.
	testing.expect_value(t, font_effective_width(&catalog, "Mono B", ""), "Semi Condensed")

	weights := font_family_weights(&catalog, "Mono A", "")
	testing.expect_value(t, len(weights), 3)
	testing.expect_value(t, weights[0].weight_style, "Light")
	testing.expect_value(t, weights[2].weight_style, "Bold")
	testing.expect_value(t, len(font_family_weights(&catalog, "Mono A", "Wide")), 2)
	testing.expect_value(t, font_weight_step(&catalog, "Mono A", "", "Regular", 1), "Bold")
	testing.expect_value(t, font_weight_step(&catalog, "Mono A", "", "Light", -1), "Bold")
	testing.expect_value(t, font_effective_style(&catalog, "Mono A", "", "Missing"), "Regular")
	testing.expect_value(t, font_effective_style(&catalog, "", "", "Bold"), "Regular")
	testing.expect_value(t, font_effective_style(&catalog, "Mono B", "", "Bold"), "Bold")
	known, ok := font_family_known(&catalog, "mono a")
	testing.expect(t, ok)
	testing.expect_value(t, known, "Mono A")
	_, ok = font_family_known(&catalog, "Helvetica")
	testing.expect(t, !ok)

	width, style := font_split_style("Bold Semi-Condensed")
	testing.expect_value(t, width, "Semi Condensed")
	testing.expect_value(t, style, "Bold")
	width, style = font_split_style("Extended")
	testing.expect_value(t, width, "Wide")
	testing.expect_value(t, style, "Regular")
}

@(test)
line_height_and_letter_spacing_clamp_and_default :: proc(t: ^testing.T) {
	testing.expect_value(t, settings_line_height_clamped(5), LINE_HEIGHT_MIN)
	testing.expect_value(t, settings_line_height_clamped(999), LINE_HEIGHT_MAX)
	testing.expect_value(t, settings_letter_spacing_clamped(-99), LETTER_SPACING_MIN)
	testing.expect_value(t, settings_letter_spacing_clamped(99), LETTER_SPACING_MAX)
	testing.expect_value(t, settings_line_ratio({}), ROW_HEIGHT_RATIO)
	testing.expect_value(t, settings_line_ratio({line_height = 200}), f32(2))
}
