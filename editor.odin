package file_manager

import "core:os"
import "core:strings"

// EDITOR_CHOICES are the editors the settings picker offers besides the system
// default, in order; only installed ones are listed. Any other app can be typed in.
EDITOR_CHOICES := [?]string{"Zed", "Visual Studio Code", "Cursor", "Sublime Text", "BBEdit", "Nova", "CotEditor", "MacVim", "TextEdit"}

// Editors lists the stops of the picker: names[0] is "" for the system default.
Editors :: struct {
	names: [len(EDITOR_CHOICES)+1]string,
	count: int,
}

editors_detect :: proc() -> Editors {
	found := Editors{count = 1}
	for name in EDITOR_CHOICES {
		if !terminal_app_installed(name) {continue}
		found.names[found.count] = name
		found.count += 1
	}
	return found
}

EDITOR_DEFAULT_LABEL :: "System default"

editor_label :: proc(configured: string) -> string {
	return len(configured) > 0 ? configured : EDITOR_DEFAULT_LABEL
}

// editor_step is the stop after (direction 1) or before (-1) the configured one;
// an app typed in by hand steps to the system default.
editor_step :: proc(configured: string, found: Editors, direction: int) -> string {
	index := 0
	for position in 0 ..< found.count {
		if found.names[position] == configured {index = position}
	}
	if configured != "" && found.names[index] != configured {return ""}
	return found.names[((index+direction)%found.count+found.count)%found.count]
}

// editor_valid accepts an installed app's name, or the path of an .app bundle.
editor_valid :: proc(name: string) -> bool {
	if len(name) == 0 || strings.contains_rune(name, '\n') {return false}
	if strings.has_prefix(name, "/") {return strings.has_suffix(name, ".app") && os.is_dir(name)}
	return terminal_app_installed(strings.trim_suffix(name, ".app"))
}
