package file_manager

import "base:intrinsics"
import "base:runtime"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"

foreign import core_services "system:CoreServices.framework"
foreign import dispatch_system "system:System"

WATCH_LATENCY :: 0.25
WATCH_RESTART_MIN :: 300*time.Millisecond
FS_EVENT_SINCE_NOW :: u64(0xFFFFFFFFFFFFFFFF)
FS_EVENT_FILE_EVENTS :: u32(0x10)
CF_UTF8 :: u32(0x08000100)

FS_Event_Context :: struct {
	version:  int,
	info:     rawptr,
	retain:   rawptr,
	release:  rawptr,
	describe: rawptr,
}

FS_Event_Callback :: proc "c" (stream: rawptr, info: rawptr, count: uint, paths: [^]cstring, flags: [^]u32, ids: [^]u64)

@(default_calling_convention = "c")
foreign core_services {
	FSEventStreamCreate :: proc(allocator: rawptr, callback: FS_Event_Callback, info: ^FS_Event_Context, paths: rawptr, since: u64, latency: f64, flags: u32) -> rawptr ---
	FSEventStreamSetDispatchQueue :: proc(stream: rawptr, queue: rawptr) ---
	FSEventStreamStart :: proc(stream: rawptr) -> bool ---
	FSEventStreamStop :: proc(stream: rawptr) ---
	FSEventStreamInvalidate :: proc(stream: rawptr) ---
	FSEventStreamRelease :: proc(stream: rawptr) ---
	@(link_name = "CFStringCreateWithCString") watch_cf_string :: proc(allocator: rawptr, text: cstring, encoding: u32) -> rawptr ---
	@(link_name = "CFArrayCreate") watch_cf_array :: proc(allocator: rawptr, values: [^]rawptr, count: int, callbacks: rawptr) -> rawptr ---
}

@(default_calling_convention = "c")
foreign dispatch_system {
	@(link_name = "_dispatch_main_q") dispatch_main_queue: u8
}

// Watcher keeps the folders on screen fresh: an FSEvents stream over them tells the
// main thread when another app changed one, and the tree is then re-read. The
// callback runs on the main queue, so the fields need no lock; dirty is atomic only
// to keep the contract obvious.
Watcher :: struct {
	stream:       rawptr,
	signature:    u64,
	restarted:    time.Tick,
	dirs:         map[string]struct{},
	dirty:        bool,
}

watcher: Watcher

// watch_signature hashes the folders worth watching: every column, the sibling
// listings around it and the trail shown beside a selected file.
watch_signature :: proc(tree: ^Tree) -> u64 {
	hash := u64(14695981039346656037)
	mix :: proc(hash: ^u64, text: string) {
		for byte in transmute([]u8)text {hash^ = (hash^ ~ u64(byte))*1099511628211}
		hash^ = (hash^ ~ 0xFF)*1099511628211
	}
	for &column in tree.columns {
		mix(&hash, column.dir)
		for blocks in ([3][]Block{column.above[:], column.below[:], view_trail_shown(&column) ? column.trail[:] : nil}) {
			for block in blocks {mix(&hash, view_block_key(block))}
		}
	}
	return hash
}

// watch_real is the canonical path FSEvents reports for a folder (/tmp arrives as /private/tmp).
watch_real :: proc(path: string) -> string {
	resolved := posix.realpath(strings.clone_to_cstring(path, context.temp_allocator), nil)
	if resolved == nil {return strings.clone(path)}
	defer posix.free(rawptr(resolved))
	return strings.clone(string(resolved))
}

watch_add :: proc(dirs: ^map[string]struct{}, path: string) {
	real := watch_real(path)
	if real in dirs {
		delete(real)
		return
	}
	dirs[real] = {}
}

watch_collect :: proc(tree: ^Tree, dirs: ^map[string]struct{}) {
	for &column in tree.columns {
		watch_add(dirs, column.dir)
		for blocks in ([3][]Block{column.above[:], column.below[:], view_trail_shown(&column) ? column.trail[:] : nil}) {
			for block in blocks {
				if key := view_block_key(block); len(key) > 0 {watch_add(dirs, key)}
			}
		}
	}
}

watch_stop :: proc() {
	if watcher.stream != nil {
		FSEventStreamStop(watcher.stream)
		FSEventStreamInvalidate(watcher.stream)
		FSEventStreamRelease(watcher.stream)
		watcher.stream = nil
	}
	for key in watcher.dirs {delete(key)}
	delete(watcher.dirs)
	watcher.dirs = nil
}

watch_callback :: proc "c" (stream: rawptr, info: rawptr, count: uint, paths: [^]cstring, flags: [^]u32, ids: [^]u64) {
	context = runtime.default_context()
	for index in 0 ..< int(count) {
		path := string(paths[index])
		_, direct := watcher.dirs[path]
		_, inside := watcher.dirs[filepath.dir(path)]
		if direct || inside {
			intrinsics.atomic_store(&watcher.dirty, true)
			host_request_frames(2)
			break
		}
	}
	free_all(context.temp_allocator)
}

// watch_restart replaces the stream with one over the folders now on screen.
watch_restart :: proc(tree: ^Tree) {
	watch_stop()
	watcher.dirs = make(map[string]struct{})
	watch_collect(tree, &watcher.dirs)
	if len(watcher.dirs) == 0 {return}
	values := make([dynamic]rawptr, 0, len(watcher.dirs), context.temp_allocator)
	for path in watcher.dirs {
		append(&values, watch_cf_string(nil, strings.clone_to_cstring(path, context.temp_allocator), CF_UTF8))
	}
	array := watch_cf_array(nil, raw_data(values), len(values), nil)
	stream_context := FS_Event_Context{}
	watcher.stream = FSEventStreamCreate(nil, watch_callback, &stream_context, array, FS_EVENT_SINCE_NOW, WATCH_LATENCY, FS_EVENT_FILE_EVENTS)
	for value in values {CFRelease(value)}
	CFRelease(array)
	if watcher.stream == nil {return}
	FSEventStreamSetDispatchQueue(watcher.stream, &dispatch_main_queue)
	if !FSEventStreamStart(watcher.stream) {
		FSEventStreamInvalidate(watcher.stream)
		FSEventStreamRelease(watcher.stream)
		watcher.stream = nil
	}
	watcher.restarted = time.tick_now()
}

// watch_follow keeps the stream matched to the tree; it restarts at most a few times
// a second while the selection is moving.
watch_follow :: proc(tree: ^Tree) {
	signature := watch_signature(tree)
	if signature == watcher.signature && watcher.stream != nil {return}
	if watcher.stream != nil && time.tick_since(watcher.restarted) < WATCH_RESTART_MIN {
		host_request_frames(1)
		return
	}
	watcher.signature = signature
	watch_restart(tree)
}

// watch_refresh_due re-reads the tree once the watcher saw a change, unless a name
// is being edited (the rows would move under the field).
watch_refresh_due :: proc(host: ^Host) {
	if !intrinsics.atomic_load(&watcher.dirty) || host.edit_mode != .None {return}
	intrinsics.atomic_store(&watcher.dirty, false)
	_ = tree_refresh(&host.tree)
}

// watch_mark asks for a refresh on the next frame, e.g. when the app is activated.
watch_mark :: proc() {
	intrinsics.atomic_store(&watcher.dirty, true)
	host_request_frames(2)
}
