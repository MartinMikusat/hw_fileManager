package file_manager

import "base:intrinsics"
import "base:runtime"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import NS "core:sys/darwin/Foundation"
import devlog "devlog:."
import native_update "native_update:."

// A packaged release is built with these (see the release tool); dev builds leave
// them empty and never update.
UPDATE_VERSION :: #config(HW_UPDATE_VERSION, "")
UPDATE_FEED_URL :: #config(HW_UPDATE_FEED_URL, "")
UPDATE_TEAM_ID :: #config(HW_UPDATE_TEAM_ID, "")
UPDATE_BUNDLE_ID :: "com.halwayland.filemanager"
UPDATE_BUNDLE_NAME :: "hw_fileManager.app"
UPDATE_INTERVAL :: time.Hour
UPDATE_POLL :: 200 * time.Millisecond

// Updater checks for a newer release in the background and stages it; the staged
// bundle replaces the installed app when the app quits, so a running session
// never changes under the user.
Updater :: struct {
	thread:        ^thread.Thread,
	cancel:        bool,
	ready:         bool,
	prepared:      native_update.Prepared,
	installed_app: string,
}

updater: Updater

update_config :: proc() -> native_update.Config {
	return {feed_url = UPDATE_FEED_URL, bundle_id = UPDATE_BUNDLE_ID, team_id = UPDATE_TEAM_ID, bundle_name = UPDATE_BUNDLE_NAME}
}

// update_installed_app is the running bundle's path, or "" when this is not the
// installed release app (a dev build, or the binary run on its own).
update_installed_app :: proc() -> string {
	executable, error := os.get_executable_path(context.allocator)
	if error != nil {return ""}
	defer delete(executable)
	marker := "/" + UPDATE_BUNDLE_NAME + "/Contents/MacOS/"
	index := strings.index(executable, marker)
	if index < 0 {return ""}
	return strings.clone(executable[:index+len(marker)-len("/Contents/MacOS/")])
}

update_start :: proc() {
	if UPDATE_VERSION == "" || UPDATE_FEED_URL == "" || UPDATE_TEAM_ID == "" || updater.thread != nil {return}
	path := update_installed_app()
	if path == "" {return}
	updater.installed_app = path
	updater.thread = thread.create(update_worker)
	if updater.thread == nil {
		devlog.failed(devlog.global(), {feature = "updater", operation = "schedule"}, {reason = "update worker could not start", severity = .Warning})
		return
	}
	thread.start(updater.thread)
}

update_cancelled :: proc() -> bool {
	return intrinsics.atomic_load(&updater.cancel)
}

// update_wait sleeps in short steps so quitting never waits for the interval.
update_wait :: proc(duration: time.Duration) {
	for waited: time.Duration; waited < duration && !update_cancelled(); waited += UPDATE_POLL {
		time.sleep(UPDATE_POLL)
	}
}

update_worker :: proc(_: ^thread.Thread) {
	context = runtime.default_context()
	site := devlog.Site{feature = "updater", operation = "check"}
	for !update_cancelled() {
		prepared := update_attempt()
		switch prepared.status {
		case .Ready:
			updater.prepared = prepared
			devlog.succeeded(devlog.global(), site, {stage = "ready"})
			intrinsics.atomic_store(&updater.ready, true)
			// The window is idle between events, so wake it to show the notice.
			pool := NS.scoped_autoreleasepool()
			_ = pool
			intrinsics.objc_send(nil, host.delegate, "performSelectorOnMainThread:withObject:waitUntilDone:", NS.sel_registerName("fileManagerUpdateReady:"), NS.id(nil), NS.BOOL(false))
			return
		case .Error:
			devlog.failed(devlog.global(), site, {reason = prepared.error, severity = .Warning})
		case .Up_To_Date, .Idle, .Checking:
		}
		native_update.discard(&prepared)
		delete(prepared.root)
		update_wait(UPDATE_INTERVAL)
	}
}

// update_attempt runs one check with scratch memory, and keeps only what a staged
// update needs afterwards.
update_attempt :: proc() -> native_update.Prepared {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	heap := runtime.default_allocator()
	scratch := context.temp_allocator
	prepared: native_update.Prepared
	{
		context.allocator = scratch
		prepared = native_update.prepare(update_config(), UPDATE_VERSION, &updater.cancel)
	}
	kept := native_update.Prepared{status = prepared.status}
	kept.root = strings.clone(prepared.root, heap)
	if prepared.status == .Ready {
		kept.app_path = strings.clone(prepared.app_path, heap)
		kept.manifest.version = strings.clone(prepared.manifest.version, heap)
	} else {
		kept.error = prepared.error
	}
	return kept
}

// update_ready reports, on the main thread, whether a verified update is staged.
update_ready :: proc() -> bool {
	return intrinsics.atomic_load(&updater.ready)
}

// update_finish stops the worker and, when an update is staged, installs it. It
// runs as the app terminates.
update_finish :: proc() {
	if updater.thread == nil {return}
	intrinsics.atomic_store(&updater.cancel, true)
	thread.join(updater.thread)
	thread.destroy(updater.thread)
	updater.thread = nil
	if updater.prepared.status == .Ready {
		site := devlog.Site{feature = "updater", operation = "apply"}
		if message := native_update.apply(update_config(), &updater.prepared, updater.installed_app); message != "" {
			devlog.failed(devlog.global(), site, {reason = message, severity = .Warning})
		} else {
			devlog.succeeded(devlog.global(), site)
		}
	}
	native_update.discard(&updater.prepared)
	updater.prepared = {}
}
