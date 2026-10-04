package file_manager

import NS "core:sys/darwin/Foundation"
import ui "ui_framework:core"

// Overlay_Hover is what the pointer is over among the overlays. While a modal
// (settings or the sort menu) is open it is the only thing that answers.
Overlay_Hover :: struct {
	modal:        bool,
	settings_hot: Settings_Hot,
	sort_row:     int,
	safe_button:  int,
	gather_row:   int,
	gather_clear: bool,
}

// overlay_hover resolves hover for the topmost overlay: settings, then the sort
// menu, then the always-visible safe and gather panels.
overlay_hover :: proc(window: ^Window, metrics: View_Metrics, point: ui.Vec2) -> Overlay_Hover {
	hover := Overlay_Hover{sort_row = -1, safe_button = -1, gather_row = -1}
	switch {
	case window.settings_open:
		hover.modal = true
		hover.settings_hot, _ = view_settings_hot(view_settings_layout(&window.tree, metrics, window.settings_tab), point)
	case window.sort_open:
		hover.modal = true
		hover.sort_row, _ = view_sort_menu_at(view_sort_menu_layout(&window.tree, metrics), point)
	case:
		if len(window.gather_paths) > 0 {
			row, clear, _ := gather_panel_at(gather_panel_layout(metrics, len(window.gather_paths)), point)
			if clear {hover.gather_clear = true} else if row >= 0 {hover.gather_row = row}
		}
		if app.safe_mode {
			if index, inside := safe_panel_at(safe_panel_layout(metrics), point); inside {hover.safe_button = index}
		}
	}
	return hover
}

// overlay_click routes a click to the topmost overlay and reports whether it
// took the click. Precedence matches overlay_hover.
overlay_click :: proc(window: ^Window, metrics: View_Metrics, point: ui.Vec2) -> bool {
	if window.sort_open {
		if row, inside := view_sort_menu_at(view_sort_menu_layout(&window.tree, metrics), point); inside {
			if row >= 0 {host_sort_set(sort_options[row])}
			window.sort_open = false
			host_request_frames(window, 2)
			return true
		}
		window.sort_open = false
		host_request_frames(window, 1)
		if view_sort_control_at(point, &window.tree, metrics) {return true}
	}
	if window.settings_open {
		settings_panel_click(window, metrics, point)
		return true
	}
	if app.safe_mode {
		if index, inside := safe_panel_at(safe_panel_layout(metrics), point); inside {
			switch index {
			case 0: settings_panel_diagnostics_copy(window)
			case 1: settings_panel_diagnostics_export(window)
			case 2: settings_panel_safe_dismiss(window)
			case 3: settings_panel_safe_reset(window)
			}
			return true
		}
	}
	if len(window.gather_paths) > 0 {
		if row, clear, inside := gather_panel_at(gather_panel_layout(metrics, len(window.gather_paths)), point); inside {
			if clear {
				gather_clear(&window.gather_paths)
			} else if row >= 0 {
				gather_remove(&window.gather_paths, window.gather_paths[row])
			}
			window.gather_hot_row = -1
			window.gather_hot_clear = false
			host_request_frames(window, 2)
			return true
		}
	}
	return false
}

// overlay_key gives a modal every key and reports whether one is open.
overlay_key :: proc(window: ^Window, event: ^NS.Event, key: uint, command, option, control, shift: bool) -> bool {
	switch {
	case window.sort_open:
		switch {
		case command && key == 13:
			window.ns_window->close()
		case command && key == 12:
			app.application->terminate(nil)
		case key == 53:
			window.sort_open = false
			host_request_frames(window, 1)
		}
		return true
	case window.settings_open:
		settings_panel_key(window, event, key, command, option, control, shift)
		return true
	}
	return false
}
