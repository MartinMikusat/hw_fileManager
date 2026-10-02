package file_manager

import "core:fmt"
import "core:os"

main :: proc() {
	if len(os.args) > 1 && os.args[1] == "--offscreen" {
		if !run_offscreen(os.args[2:]) {
			fmt.eprintln("usage: file_manager --offscreen <path.ppm> [--width=N] [--height=N] [--scale=N] [--path=DIR]")
			os.exit(2)
		}
		return
	}
	if !host_run() {
		fmt.eprintln("[hw_fileManager] startup failed")
		os.exit(1)
	}
}
