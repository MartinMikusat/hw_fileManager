package file_manager

import "core:fmt"
import "core:os"
import devlog "devlog:."

app_exit :: proc(status: int) {
	devlog.global_destroy()
	os.exit(status)
}

main :: proc() {
	// Handled before the journal opens: the crash marker must survive so the next
	// real launch still knows the app crashed.
	if len(os.args) > 1 && os.args[1] == "--diagnostics" {
		if !run_diagnostics(os.args[2:]) {os.exit(2)}
		os.exit(0)
	}
	config := devlog.DEFAULT_CONFIG
	config.profile = devlog.profile_from_env()
	if devlog.global_start(devlog.default_directory("hw_fileManager", "app", context.temp_allocator), config) {
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
			fmt.eprintln("usage: file_manager --offscreen <path.ppm> [--width=N] [--height=N] [--scale=N] [--path=DIR] [--select=NAME] [--font-size=N] [--settings]")
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
