package file_manager

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import devlog "devlog:."

CLI_COMMAND :: "hfm"
CLI_BUNDLE_ID :: "com.halwayland.filemanager"
CLI_SCRIPT :: `#!/bin/sh
# hw_fileManager command line tool, installed by the app; safe to delete.
if [ "$#" -eq 0 ]; then set -- .; fi
for path in "$@"; do
	if [ ! -e "$path" ]; then
		echo "hfm: no such file or directory: $path" >&2
		exit 1
	fi
done
exec open -b com.halwayland.filemanager "$@"
`

cli_path :: proc(allocator := context.allocator) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	return fmt.aprintf("%s/.local/bin/%s", home, CLI_COMMAND, allocator = allocator)
}

// cli_installed reports whether our shim is present; a file without the bundle
// marker is somebody else's and is left alone.
cli_installed :: proc() -> bool {
	data, error := os.read_entire_file(cli_path(context.temp_allocator), context.temp_allocator)
	if error != nil {return false}
	return strings.contains(string(data), CLI_BUNDLE_ID)
}

cli_install :: proc() -> bool {
	site := devlog.Site{feature = "cli", operation = "install"}
	devlog.started(devlog.global(), site)
	path := cli_path(context.temp_allocator)
	if error := os.make_directory_all(filepath.dir(path)); error != nil && error != .Exist {
		devlog.failed(devlog.global(), site, {reason = "command line directory could not be created"})
		return false
	}
	if error := os.write_entire_file(path, CLI_SCRIPT); error != nil {
		devlog.failed(devlog.global(), site, {reason = "command line tool could not be written"})
		return false
	}
	if error := os.chmod(path, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other}); error != nil {
		devlog.failed(devlog.global(), site, {reason = "command line tool could not be made executable"})
		return false
	}
	devlog.succeeded(devlog.global(), site)
	return true
}

cli_remove :: proc() -> bool {
	site := devlog.Site{feature = "cli", operation = "remove"}
	devlog.started(devlog.global(), site)
	if !cli_installed() {
		devlog.failed(devlog.global(), site, {reason = "command line tool is not ours"})
		return false
	}
	if error := os.remove(cli_path(context.temp_allocator)); error != nil {
		devlog.failed(devlog.global(), site, {reason = "command line tool could not be removed"})
		return false
	}
	devlog.succeeded(devlog.global(), site)
	return true
}
