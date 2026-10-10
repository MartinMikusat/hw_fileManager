package file_manager

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import devlog "devlog:."

Settings :: struct {
	font_size: int,
	window:    Window_Frame,
	// Last selected path, owned; reopened on the next start while it exists.
	place:     string,
	// Terminal app opened by the Terminal action, owned; empty means the first installed.
	terminal:  string,
	animations_off: bool,
	// Hides the key letters on the action bar labels.
	hints_off: bool,
	// App the Open action uses for text files, owned; empty means the system default.
	editor:    string,
	// Name of the syntax theme for previews, owned; empty or unknown means Default.
	syntax_theme: string,
	// Monospaced font family and style name, owned; empty family is the embedded font.
	font_family: string,
	font_weight: string,
	// Width of the family ("" is normal), line height as a percent of the font size
	// (0 is the default) and letter spacing in tenths of a point.
	font_width: string,
	line_height: int,
	letter_spacing: int,
	// Sort token, e.g. "name" or "modified-desc"; empty is name A-Z.
	sort: string,
	// Folders kept in the favorites list, owned.
	favorites: []string,
}

Window_Frame :: struct {
	x, y, w, h: f32,
}

// Fields present in the file replace the defaults; absent fields keep them.
Settings_Document :: struct {
	font_size:     int `json:"font_size"`,
	window_x:      f32 `json:"window_x"`,
	window_y:      f32 `json:"window_y"`,
	window_width:  f32 `json:"window_width"`,
	window_height: f32 `json:"window_height"`,
	place:         string `json:"place"`,
	terminal:      string `json:"terminal"`,
	animations_off: bool `json:"animations_off"`,
	hints_off:     bool `json:"hints_off"`,
	editor:        string `json:"editor"`,
	syntax_theme:  string `json:"syntax_theme"`,
	font_family:   string `json:"font_family"`,
	font_weight:   string `json:"font_weight"`,
	font_width:    string `json:"font_width"`,
	line_height:   int `json:"line_height"`,
	letter_spacing: int `json:"letter_spacing"`,
	sort:          string `json:"sort"`,
	favorites:     []string `json:"favorites"`,
}

settings_defaults :: proc() -> Settings {
	return {font_size = DEFAULT_FONT_SIZE}
}

settings_font_size_clamped :: proc(value: int) -> int {
	return clamp(value, FONT_SIZE_MIN, FONT_SIZE_MAX)
}

LINE_HEIGHT_MIN :: 110
LINE_HEIGHT_MAX :: 260
LETTER_SPACING_MIN :: -10
LETTER_SPACING_MAX :: 40

settings_line_height_clamped :: proc(value: int) -> int {
	return clamp(value, LINE_HEIGHT_MIN, LINE_HEIGHT_MAX)
}

settings_letter_spacing_clamped :: proc(value: int) -> int {
	return clamp(value, LETTER_SPACING_MIN, LETTER_SPACING_MAX)
}

// settings_line_ratio is the row height as a multiple of the font size.
settings_line_ratio :: proc(settings: Settings) -> f32 {
	return settings.line_height > 0 ? f32(settings.line_height)/100 : ROW_HEIGHT_RATIO
}

// settings_line_percent is the line height as a percent of the font size.
settings_line_percent :: proc(settings: Settings) -> int {
	return int(settings_line_ratio(settings)*100+0.5)
}

settings_path :: proc(allocator := context.allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	return fmt.aprintf(
		"%s/Library/Application Support/hw_fileManager/settings.json",
		home,
		allocator = allocator,
	)
}

settings_load :: proc(path: string, settings: ^Settings) -> bool {
	assert(settings != nil)
	site := devlog.Site{feature = "settings", operation = "load"}
	devlog.started(devlog.global(), site)
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		if read_error != .Not_Exist {
			devlog.failed(devlog.global(), site, {
				reason = "settings file could not be read",
				detail = filepath.base(path),
			})
		}
		return false
	}
	document: Settings_Document
	if unmarshal_error := json.unmarshal(data, &document); unmarshal_error != nil {
		devlog.failed(devlog.global(), site, {
			reason = "settings file is not valid JSON",
			detail = filepath.base(path),
		})
		return false
	}
	if document.font_size != 0 {settings.font_size = settings_font_size_clamped(document.font_size)}
	if document.window_width > 0 && document.window_height > 0 {
		settings.window = {document.window_x, document.window_y, document.window_width, document.window_height}
	}
	if len(document.place) > 0 {
		delete(settings.place)
		settings.place = document.place
	}
	settings.animations_off = document.animations_off
	settings.hints_off = document.hints_off
	if len(document.font_family) > 0 {
		delete(settings.font_family)
		settings.font_family = document.font_family
	}
	if len(document.font_width) > 0 {
		delete(settings.font_width)
		settings.font_width = document.font_width
	}
	if document.line_height != 0 {settings.line_height = settings_line_height_clamped(document.line_height)}
	settings.letter_spacing = settings_letter_spacing_clamped(document.letter_spacing)
	if len(document.font_weight) > 0 {
		delete(settings.font_weight)
		settings.font_weight = document.font_weight
	}
	if len(document.syntax_theme) > 0 {
		delete(settings.syntax_theme)
		settings.syntax_theme = document.syntax_theme
	}
	if len(document.editor) > 0 {
		delete(settings.editor)
		settings.editor = document.editor
	}
	if len(document.terminal) > 0 {
		delete(settings.terminal)
		settings.terminal = document.terminal
	}
	if len(document.sort) > 0 {
		delete(settings.sort)
		settings.sort = document.sort
	}
	if len(document.favorites) > 0 {
		delete(settings.favorites)
		settings.favorites = document.favorites
		favorites_sort(settings.favorites)
	}
	devlog.succeeded(devlog.global(), site)
	return true
}

settings_save :: proc(path: string, settings: Settings) -> bool {
	site := devlog.Site{feature = "settings", operation = "save"}
	devlog.started(devlog.global(), site)
	document := Settings_Document{
		font_size = settings_font_size_clamped(settings.font_size),
		window_x = settings.window.x,
		window_y = settings.window.y,
		window_width = settings.window.w,
		window_height = settings.window.h,
		place = settings.place,
		terminal = settings.terminal,
		animations_off = settings.animations_off,
		hints_off = settings.hints_off,
		editor = settings.editor,
		syntax_theme = settings.syntax_theme,
		font_family = settings.font_family,
		font_weight = settings.font_weight,
		font_width = settings.font_width,
		line_height = settings.line_height == 0 ? 0 : settings_line_height_clamped(settings.line_height),
		letter_spacing = settings_letter_spacing_clamped(settings.letter_spacing),
		sort = settings.sort,
		favorites = settings.favorites,
	}
	data, marshal_error := json.marshal(document, allocator = context.temp_allocator)
	if marshal_error != nil {
		devlog.failed(devlog.global(), site, {reason = "settings could not be encoded"})
		return false
	}
	directory := filepath.dir(path)
	if directory_error := os.make_directory_all(directory); directory_error != nil && directory_error != .Exist {
		devlog.failed(devlog.global(), site, {reason = "settings directory could not be created"})
		return false
	}
	if write_error := os.write_entire_file(path, data); write_error != nil {
		devlog.failed(devlog.global(), site, {
			reason = "settings file could not be written",
			detail = filepath.base(path),
		})
		return false
	}
	devlog.succeeded(devlog.global(), site)
	return true
}
