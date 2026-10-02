package file_manager

import "core:fmt"
import "core:os"
import "core:strings"
import devlog "delta_support:devlog"

app_log_directory :: proc() -> string {
	directory := strings.trim_space(os.get_env("DELTA_DEVLOG_DIR", context.temp_allocator))
	if directory != "" {return directory}
	return fmt.tprintf(
		"%s/Library/Application Support/hw_fileManager/devlog/app",
		os.get_env("HOME", context.temp_allocator),
	)
}

app_exit :: proc(status: int) {
	devlog.global_destroy()
	os.exit(status)
}

main :: proc() {
	config := devlog.DEFAULT_CONFIG
	config.profile = devlog.profile_from_env()
	if devlog.global_start(app_log_directory(), config) {
		context.assertion_failure_proc = devlog.fatal_hook()
	} else {
		fmt.eprintln("[hw_fileManager] could not initialize the operation journal")
	}
	defer devlog.global_destroy()
	devlog.started(devlog.global(), {feature = "app", operation = "startup"}, {
		stage = config.profile == .Dev ? "profile_dev" : "profile_prod",
	})

	if len(os.args) > 1 && os.args[1] == "--offscreen" {
		if !run_offscreen(os.args[2:]) {
			devlog.failed(devlog.global(), {feature = "app", operation = "render_offscreen"}, {
				reason = "offscreen render failed",
			})
			fmt.eprintln("usage: file_manager --offscreen <path.ppm> [--width=N] [--height=N] [--scale=N] [--path=DIR]")
			app_exit(2)
		}
		devlog.succeeded(devlog.global(), {feature = "app", operation = "render_offscreen"})
		return
	}
	if !host_run() {
		devlog.failed(devlog.global(), {feature = "app", operation = "presentation"}, {
			reason = "window host initialization failed",
			severity = .Critical,
		})
		fmt.eprintln("[hw_fileManager] startup failed")
		app_exit(1)
	}
}
