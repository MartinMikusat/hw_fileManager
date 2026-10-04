package file_manager

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import devlog "devlog:."

// After this many consecutive crashed launches the app starts in safe mode:
// the updater, the custom font and the preview are skipped, and a recovery
// panel offers diagnostics and a settings reset.
SAFE_MODE_CRASHES :: 2

safe_state_path :: proc(allocator := context.allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	return fmt.aprintf("%s/Library/Application Support/hw_fileManager/crash.count", home, allocator = allocator)
}

// safe_update_count increments the consecutive-crash counter when the last run
// crashed, resets it otherwise, and returns the new count.
safe_update_count :: proc() -> int {
	path := safe_state_path(context.temp_allocator)
	count := 0
	if data, read_error := os.read_entire_file(path, context.temp_allocator); read_error == nil {
		if value, ok := strconv.parse_int(strings.trim_space(string(data))); ok {count = value}
	}
	if devlog.global() != nil && devlog.global().previous_run_crashed {count += 1} else {count = 0}
	_ = os.write_entire_file(path, fmt.tprintf("%d", count))
	return count
}

safe_clear :: proc() {
	_ = os.remove(safe_state_path(context.temp_allocator))
}
