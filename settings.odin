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
}

settings_defaults :: proc() -> Settings {
	return {font_size = DEFAULT_FONT_SIZE}
}

settings_font_size_clamped :: proc(value: int) -> int {
	return clamp(value, FONT_SIZE_MIN, FONT_SIZE_MAX)
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
