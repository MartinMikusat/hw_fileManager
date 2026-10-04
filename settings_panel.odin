package file_manager

import "core:strings"
import NS "core:sys/darwin/Foundation"
import ui "ui_framework:core"
import diag "diagnostics:."

// Font and line settings are app-wide, so every open window's text context and
// tree are updated together.
settings_panel_apply_font :: proc() {
	for window in app.windows {
		font_apply(&window.text, &font_catalog, app.settings.font_family, app.settings.font_width, app.settings.font_weight)
	}
	host_save_settings()
	for window in app.windows {host_request_frames(window, 2)}
}

// settings_panel_font_family switches the interface font, keeping the weight when
// the new family has it.
settings_panel_font_family :: proc(family: string) {
	delete(app.settings.font_family)
	app.settings.font_family = strings.clone(family)
	settings_panel_apply_font()
}

settings_panel_font_weight :: proc(style: string) {
	delete(app.settings.font_weight)
	app.settings.font_weight = strings.clone(style)
	settings_panel_apply_font()
}

settings_panel_font_width :: proc(width: string) {
	delete(app.settings.font_width)
	app.settings.font_width = strings.clone(width)
	settings_panel_apply_font()
}

settings_panel_line_height :: proc(delta: int) {
	current := settings_line_percent(app.settings)
	app.settings.line_height = settings_line_height_clamped(current+delta)
	for window in app.windows {tree_set_line_ratio(&window.tree, settings_line_ratio(app.settings))}
	settings_panel_apply_font()
}

settings_panel_letter_spacing :: proc(delta: int) {
	app.settings.letter_spacing = settings_letter_spacing_clamped(app.settings.letter_spacing+delta)
	text_tracking = f32(app.settings.letter_spacing)/10
	settings_panel_apply_font()
}

// settings_panel_open refreshes the command-line-tool state each time the modal opens.
settings_panel_open :: proc(window: ^Window) {
	window.settings_open = true
	app.cli_installed = cli_installed()
	app.cli_confirm = false
	host_request_frames(window, 2)
}

settings_panel_close :: proc(window: ^Window) {
	window.settings_open = false
	app.cli_confirm = false
	host_request_frames(window, 1)
}

// settings_panel_safe_dismiss leaves safe mode and clears the crash counter, keeping
// the settings; use it when the crashes were not caused by one.
settings_panel_safe_dismiss :: proc(window: ^Window) {
	diag.safe_clear(diagnostics_config().app_name)
	app.safe_mode = false
	update_start()
	settings_panel_apply_font()
}

// settings_panel_safe_reset restores default settings and clears the crash counter, so a
// bad setting that crashes the app is left behind.
settings_panel_safe_reset :: proc(window: ^Window) {
	delete(app.settings.place)
	delete(app.settings.terminal)
	delete(app.settings.editor)
	delete(app.settings.syntax_theme)
	delete(app.settings.font_family)
	delete(app.settings.font_weight)
	delete(app.settings.font_width)
	app.settings = settings_defaults()
	diag.safe_clear(diagnostics_config().app_name)
	app.safe_mode = false
	update_start()
	settings_panel_apply_font()
	notice_set(window, "settings reset to defaults")
}

// settings_panel_diagnostics_copy puts the redacted report on the clipboard for pasting
// into an email or a GitHub issue.
settings_panel_diagnostics_copy :: proc(window: ^Window) {
	text := diag.report_build(diagnostics_config(), context.allocator)
	defer delete(text, context.allocator)
	if diag.copy_to_clipboard(text) {
		notice_set(window, "diagnostics copied to the clipboard")
	} else {
		notice_set(window, "could not copy diagnostics")
	}
	host_request_frames(window, 2)
}

// settings_panel_diagnostics_export writes the report next to the user and reveals it.
settings_panel_diagnostics_export :: proc(window: ^Window) {
	path := diag.report_default_path(diagnostics_config(), context.allocator)
	defer delete(path, context.allocator)
	if diag.report_write_file(diagnostics_config(), path) {
		diag.reveal_path(path)
		notice_set(window, "diagnostics written to the Desktop")
	} else {
		notice_set(window, "could not write diagnostics")
	}
	host_request_frames(window, 2)
}

// settings_panel_cli_action installs the shim, or arms then performs its removal.
settings_panel_cli_action :: proc(window: ^Window) {
	if !app.cli_installed {
		if cli_install() {
			app.cli_installed = true
			notice_set(window, "command line tool installed as hfm")
		} else {
			notice_set(window, "could not install the command line tool")
		}
	} else if !app.cli_confirm {
		app.cli_confirm = true
	} else {
		if cli_remove() {
			app.cli_installed = false
			notice_set(window, "command line tool removed")
		} else {
			notice_set(window, "could not remove the command line tool")
		}
		app.cli_confirm = false
	}
	host_request_frames(window, 2)
}

// settings_panel_show_tab switches the modal's page, dropping any open field.
settings_panel_show_tab :: proc(window: ^Window, tab: Settings_Tab) {
	if window.input_mode == .OpenWith || window.input_mode == .FontFamily {
		input_reset(window)
		window.notice_len = 0
	}
	window.settings_tab = tab
	host_request_frames(window, 2)
}

// settings_panel_font_family_commit stores the typed family when it is an installed
// monospaced one; otherwise the field stays open and the modal shows why.
settings_panel_font_family_commit :: proc(window: ^Window) {
	name := strings.trim_space(window.input_value)
	if len(name) == 0 {
		settings_panel_font_family("")
	} else if family, ok := font_family_known(&font_catalog, name); ok {
		settings_panel_font_family(family)
	} else {
		notice_set(window, "no such monospaced font")
		return
	}
	input_reset(window)
	window.notice_len = 0
}

settings_panel_syntax :: proc(direction: int) {
	next := syntax_theme_step(app.settings.syntax_theme, direction)
	delete(app.settings.syntax_theme)
	app.settings.syntax_theme = strings.clone(next)
	host_save_settings()
	for window in app.windows {host_request_frames(window, 2)}
}

settings_panel_editor :: proc(direction: int) {
	next := editor_step(app.settings.editor, app.editors, direction)
	settings_panel_save_editor(next)
}

settings_panel_save_editor :: proc(name: string) {
	delete(app.settings.editor)
	app.settings.editor = strings.clone(name)
	host_save_settings()
	for window in app.windows {host_request_frames(window, 2)}
}

// settings_panel_open_with_commit stores the typed app when it exists; otherwise the field
// stays open and the modal shows why.
settings_panel_open_with_commit :: proc(window: ^Window) {
	name := strings.trim_space(window.input_value)
	if len(name) == 0 {
		settings_panel_save_editor("")
	} else if editor_valid(name) {
		settings_panel_save_editor(name)
	} else {
		notice_set(window, "no such app")
		return
	}
	input_reset(window)
	window.notice_len = 0
}

settings_panel_animations :: proc() {
	app.settings.animations_off = !app.settings.animations_off
	host_save_settings()
	for window in app.windows {host_request_frames(window, 2)}
}

settings_panel_terminal :: proc(direction: int) {
	next, ok := terminal_step(app.settings.terminal, app.terminals, direction)
	if !ok {return}
	delete(app.settings.terminal)
	app.settings.terminal = strings.clone(next)
	host_save_settings()
	for window in app.windows {host_request_frames(window, 2)}
}

settings_panel_font_size :: proc(delta: int) {
	next := settings_font_size_clamped(app.settings.font_size+delta)
	if next == app.settings.font_size {return}
	app.settings.font_size = next
	for window in app.windows {_ = tree_set_font_size(&window.tree, f32(next))}
	settings_panel_apply_font()
}

// settings_panel_click applies a click while the modal is open; the backdrop closes it.
settings_panel_click :: proc(window: ^Window, metrics: View_Metrics, point: ui.Vec2) {
	hot, inside := view_settings_hot(view_settings_layout(&window.tree, metrics, window.settings_tab), point)
	editing_field := window.input_mode == .OpenWith || window.input_mode == .FontFamily
	field_kept := (window.input_mode == .OpenWith && hot == .EditorCustom) || (window.input_mode == .FontFamily && hot == .FontCustom)
	if editing_field && !field_kept {
		input_reset(window)
		window.notice_len = 0
	}
	if !inside {
		settings_panel_close(window)
		return
	}
	family := app.settings.font_family
	#partial switch hot {
	case .CliAction: settings_panel_cli_action(window)
	case .CliCancel:
		app.cli_confirm = false
		host_request_frames(window, 2)
	case .DiagCopy: settings_panel_diagnostics_copy(window)
	case .DiagExport: settings_panel_diagnostics_export(window)
	case .Minus: settings_panel_font_size(-1)
	case .Plus: settings_panel_font_size(1)
	case .Previous: settings_panel_terminal(-1)
	case .Next: settings_panel_terminal(1)
	case .Animations: settings_panel_animations()
	case .EditorPrevious: settings_panel_editor(-1)
	case .EditorNext: settings_panel_editor(1)
	case .FontPrevious: settings_panel_font_family(font_family_step(&font_catalog, family, -1))
	case .FontNext: settings_panel_font_family(font_family_step(&font_catalog, family, 1))
	case .WeightPrevious, .WeightNext:
		if len(family) > 0 {
			step := hot == .WeightNext ? 1 : -1
			settings_panel_font_weight(font_weight_step(&font_catalog, family, app.settings.font_width, app.settings.font_weight, step))
		}
	case .WidthPrevious, .WidthNext:
		if len(family) > 0 {
			settings_panel_font_width(font_width_step(&font_catalog, family, app.settings.font_width, hot == .WidthNext ? 1 : -1))
		}
	case .LineMinus, .LinePlus: settings_panel_line_height(hot == .LinePlus ? 5 : -5)
	case .SpacingMinus, .SpacingPlus: settings_panel_letter_spacing(hot == .SpacingPlus ? 2 : -2)
	case .TabGeneral, .TabFont: settings_panel_show_tab(window, hot == .TabFont ? .Font : .General)
	case .FontCustom:
		if window.input_mode != .FontFamily {
			input_begin(window, .FontFamily)
			input_set(window, app.settings.font_family)
			window.notice_len = 0
			host_request_frames(window, 2)
		}
	case .SyntaxPrevious: settings_panel_syntax(-1)
	case .SyntaxNext: settings_panel_syntax(1)
	case .EditorCustom:
		if window.input_mode != .OpenWith {
			input_begin(window, .OpenWith)
			input_set(window, app.settings.editor)
			window.notice_len = 0
			host_request_frames(window, 2)
		}
	}
}

// settings_panel_key handles every key while the modal is open.
settings_panel_key :: proc(window: ^Window, event: ^NS.Event, key: uint, command, option, control, shift: bool) {
	if window.input_mode == .OpenWith || window.input_mode == .FontFamily {
		switch {
		case command && (key == 13 || key == 12):
			if key == 13 {window.ns_window->close()} else {app.application->terminate(nil)}
		case key == 36, key == 76:
			if window.input_mode == .FontFamily {settings_panel_font_family_commit(window)} else {settings_panel_open_with_commit(window)}
		case key == 53:
			input_reset(window)
			window.notice_len = 0
		case:
			_ = input_handle_key(window, event, key, command, option, control, shift)
		}
		host_request_frames(window, 2)
		return
	}
	switch {
	case command && key == 13:
		window.ns_window->close()
	case command && key == 12:
		app.application->terminate(nil)
	case key == 48:
		settings_panel_show_tab(window, window.settings_tab == .General ? .Font : .General)
	case key == 53, command && key == 43:
		input_reset(window)
		settings_panel_close(window)
	}
}
