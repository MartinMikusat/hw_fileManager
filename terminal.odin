package file_manager

import "core:os"
import "core:strings"

// TERMINAL_CHOICES are the terminals the settings picker offers, in default order;
// only those installed are listed.
TERMINAL_CHOICES := [?]string{"Ghostty", "iTerm", "Terminal", "WezTerm", "Alacritty", "kitty"}
TERMINAL_FALLBACK :: "Terminal"

Terminals :: struct {
	names: [len(TERMINAL_CHOICES)]string,
	count: int,
}

terminal_app_installed :: proc(name: string) -> bool {
	home := os.get_env("HOME", context.temp_allocator)
	for root in ([4]string{"/Applications", "/System/Applications", "/System/Applications/Utilities", strings.concatenate({home, "/Applications"}, context.temp_allocator)}) {
		if os.is_dir(strings.concatenate({root, "/", name, ".app"}, context.temp_allocator)) {return true}
	}
	return false
}

terminals_detect :: proc() -> Terminals {
	found: Terminals
	for name in TERMINAL_CHOICES {
		if !terminal_app_installed(name) {continue}
		found.names[found.count] = name
		found.count += 1
	}
	return found
}

// terminal_effective is the configured terminal, else the first installed one.
terminal_effective :: proc(configured: string, found: Terminals) -> string {
	if len(configured) > 0 {return configured}
	if found.count > 0 {return found.names[0]}
	return TERMINAL_FALLBACK
}

// terminal_step is the installed terminal after (direction 1) or before (-1) the
// current one; a configured app outside the list steps to the first entry.
terminal_step :: proc(configured: string, found: Terminals, direction: int) -> (string, bool) {
	if found.count == 0 {return "", false}
	current := terminal_effective(configured, found)
	index := -1
	for position in 0 ..< found.count {
		if found.names[position] == current {index = position}
	}
	if index < 0 {return found.names[0], true}
	return found.names[((index+direction)%found.count+found.count)%found.count], true
}
