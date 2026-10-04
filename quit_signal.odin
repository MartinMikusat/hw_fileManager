package file_manager

import "base:runtime"
import "core:sys/posix"

foreign import quit_dispatch "system:System"

@(default_calling_convention = "c")
foreign quit_dispatch {
	@(link_name = "_dispatch_source_type_signal") dispatch_source_type_signal: u8
	dispatch_source_create :: proc(type: rawptr, handle: uintptr, mask: uint, queue: rawptr) -> rawptr ---
	dispatch_source_set_event_handler_f :: proc(source: rawptr, handler: proc "c" (context_pointer: rawptr)) ---
	dispatch_resume :: proc(object: rawptr) ---
}

// quit_on_sigterm turns SIGTERM, which the dev watcher sends to relaunch the app, into
// a normal quit, so the journal is closed and the run is not counted as a crash.
quit_on_sigterm :: proc() {
	posix.signal(.SIGTERM, auto_cast posix.SIG_IGN)
	source := dispatch_source_create(&dispatch_source_type_signal, uintptr(posix.Signal.SIGTERM), 0, &dispatch_main_queue)
	if source == nil {return}
	dispatch_source_set_event_handler_f(source, proc "c" (_: rawptr) {
		context = runtime.default_context()
		app.application->terminate(nil)
	})
	dispatch_resume(source)
}
