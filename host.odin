package file_manager

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import QC "vendor:darwin/QuartzCore"
import text_input "components:text_input"
import devlog "devlog:."
import coretext "ui_framework:coretext"
import draw "ui_framework:draw"
import macos "ui_framework:macos"
import metal "ui_framework:metal"
import ui "ui_framework:core"
import diag "diagnostics:."

WINDOW_WIDTH :: NS.Float(1100)
WINDOW_HEIGHT :: NS.Float(720)
WINDOW_MIN_WIDTH :: NS.Float(520)
WINDOW_MIN_HEIGHT :: NS.Float(320)
WINDOW_STYLE :: NS.WindowStyleMask{.Closable, .Miniaturizable, .Resizable}
MINIMIZE_STYLE :: NS.WindowStyleMask{.Titled, .Closable, .Miniaturizable, .Resizable}

CONTROL_MINIMIZE :: 0
CONTROL_ZOOM :: 1
CONTROL_CLOSE :: 2

// App holds what every window shares: the process, the Metal device, settings,
// the app-wide clipboard and the detected helper apps. Window holds everything
// one window owns, including its own Metal layer and text context.
App :: struct {
	application:    ^NS.Application,
	delegate:       ^NS.Object,
	delegate_class: NS.Class,
	view_class:     NS.Class,
	window_class:   NS.Class,
	device:         ^MTL.Device,
	queue:          ^MTL.CommandQueue,
	settings:       Settings,
	zoxide:         string,
	terminals:      Terminals,
	editors:        Editors,
	clip_paths:     [dynamic]string,
	clip_cut:       bool,
	fatal_reason:   string,
	safe_mode:      bool,
	cli_installed:  bool,
	cli_confirm:    bool,
	windows:        [dynamic]^Window,
	// Closed windows wait here until it is safe to free them, off their own callback.
	doomed:         [dynamic]^Window,
}

Window :: struct {
	delegate:       ^NS.Object,
	ns_window:      ^NS.Window,
	view:           ^NS.View,
	layer:          ^QC.MetalLayer,
	display_link:   macos.Display_Link,
	text:           coretext.Context,
	renderer:       metal.Renderer,
	list:           draw.List,
	tree:           Tree,
	view_width:     f32,
	view_height:    f32,
	hot_control:    int,
	char_advance:   f32,
	hot_settings_button: bool,
	hot_settings_hot:    Settings_Hot,
	hot_sort_button:     bool,
	hot_sort_row:        int,
	hot_safe_button:     int,
	sort_open:      bool,
	settings_open:  bool,
	settings_tab:   Settings_Tab,
	input_value:    string,
	input_mode:     Input_Mode,
	search_committed: bool,
	history:        [HISTORY_MAX]string,
	history_count:  int,
	history_index:  int,
	draft:          string,
	cd_completing:  bool,
	place_pending:  string,
	place_since:    time.Tick,
	gather_paths:    [dynamic]string,
	gather_hot_row:  int,
	gather_hot_clear: bool,
	edit_mode:      Edit_Mode,
	edit_value:     string,
	text_state:     text_input.State,
	edit_column:    int,
	edit_row:       int,
	notice:         [NOTICE_MAX]u8,
	notice_len:     int,
	notice_until_ms: i64,
	preview:        Preview,
	preview_rect:   draw.Rect,
	preview_shown:  bool,
	hot_action:     Action_Kind,
	hot_action_hot: bool,
	shift_down:     bool,
	frames_pending: int,
	wheel_rows:     f32,
	frame_tick:     time.Tick,
	frame_animated: bool,
	initialized:    bool,
	// An ephemeral window (opened by hfm or Cmd+N) never owns settings.place or
	// the remembered frame.
	ephemeral:      bool,
}

// Startup failure reasons; host_friendly_reason maps them to user-facing text.
FAIL_COCOA_CLASSES :: "Cocoa classes could not be registered"
FAIL_WINDOW_CLASS :: "window class could not be registered"
FAIL_METAL_DEVICE :: "Metal device is unavailable"
FAIL_WINDOW_CREATE :: "window could not be created"
FAIL_DISPLAY_LINK :: "the macOS 14 display link API is unavailable"
FAIL_START_DIRECTORY :: "no readable starting directory"

app: App

font_checked: bool

register_mono_font :: proc(text: ^coretext.Context) {
	assert(font_register(), "embedded Iosevka must register; no silent substitute")
	if !font_checked {
		font_checked = true
		assert(font_resolves(), "FONT_NAME must resolve to the embedded face; a wrong PostScript name falls back silently")
	}
	coretext.register_font(text, FONT_MONO, FONT_NAME)
}

measure_char_advance :: proc(text: ^coretext.Context, font_size: f32) -> f32 {
	run := coretext.shape(text, FONT_MONO, "MMMMMMMMMM", font_size, text_tracking, 0, false)
	if run == nil {return font_size*0.6}
	return run.metrics.width/10
}

home_directory :: proc() -> string {
	value := os.get_env("HOME", context.temp_allocator)
	if len(value) > 0 {return value}
	return "/"
}

host_add_method :: proc(class: NS.Class, name: cstring, imp: rawptr, types: cstring) -> bool {
	return bool(NS.class_addMethod(class, NS.sel_registerName(name), auto_cast imp, types))
}

host_window_key :: proc "c" (self: NS.id, cmd: NS.SEL) -> bool {return true}

// A window without a title bar cannot become key by default, so the first
// responder never receives keyboard events unless it opts in.
host_window_class :: proc() -> NS.Class {
	class := NS.objc_allocateClassPair(intrinsics.objc_find_class("NSWindow"), "FileManagerWindow", 0)
	if class == nil {return nil}
	if !host_add_method(class, "canBecomeKeyWindow", rawptr(host_window_key), "B@:") {return nil}
	if !host_add_method(class, "canBecomeMainWindow", rawptr(host_window_key), "B@:") {return nil}
	NS.objc_registerClassPair(class)
	return class
}

host_failure :: proc(reason: string, severity := devlog.Severity.Error) {
	devlog.failed(devlog.global(), {feature = "presentation", operation = "window_host"}, {
		reason = reason,
		severity = severity,
	})
	if severity == .Critical {
		delete(app.fatal_reason)
		app.fatal_reason = strings.clone(reason)
	}
}

// host_friendly_reason turns a startup failure into a line a non-technical user
// can act on; the raw reason is shown underneath it.
host_friendly_reason :: proc(reason: string) -> string {
	switch reason {
	case FAIL_DISPLAY_LINK:
		return "This app needs macOS 14 (Sonoma) or later."
	case FAIL_METAL_DEVICE:
		return "This Mac's graphics device could not be used."
	case FAIL_START_DIRECTORY:
		return "No folder could be opened to start from."
	case FAIL_COCOA_CLASSES, FAIL_WINDOW_CLASS, FAIL_WINDOW_CREATE:
		return "A required macOS component could not be set up."
	}
	return "The app hit an unexpected problem while starting."
}

// host_fatal_alert shows the reason the app could not start and offers to copy
// the full diagnostics report before it exits.
host_fatal_alert :: proc() {
	_ = NS.Application.sharedApplication()
	reason := len(app.fatal_reason) > 0 ? app.fatal_reason : "the app could not start"
	alert := intrinsics.objc_send(^NS.Object, cast(^NS.Object)intrinsics.objc_find_class("NSAlert"), "new")
	if alert == nil {return}
	intrinsics.objc_send(nil, alert, "setMessageText:", edit_nsstring("hw_fileManager could not start"))
	intrinsics.objc_send(nil, alert, "setInformativeText:", edit_nsstring(fmt.tprintf("%s\n\n%s", host_friendly_reason(reason), reason)))
	_ = intrinsics.objc_send(^NS.Object, alert, "addButtonWithTitle:", edit_nsstring("Copy details"))
	_ = intrinsics.objc_send(^NS.Object, alert, "addButtonWithTitle:", edit_nsstring("Quit"))
	if intrinsics.objc_send(i64, alert, "runModal") == 1000 {
		text := diag.report_build(diagnostics_config(), context.allocator)
		defer delete(text, context.allocator)
		_ = diag.copy_to_clipboard(text)
	}
	intrinsics.objc_send(nil, alert, "release")
}

notice_set :: proc(window: ^Window, text: string) {
	length := min(len(text), NOTICE_MAX)
	copy(window.notice[:length], text[:length])
	window.notice_len = length
	window.notice_until_ms = time.to_unix_nanoseconds(time.now())/1_000_000+3000
}

// window_for_view/window_for_delegate/window_for_ns_window map an AppKit object
// back to the Window that owns it; a handful of windows makes the linear scan
// cheaper than an associated-object table.
window_for_view :: proc(view: NS.id) -> ^Window {
	for window in app.windows {
		if cast(NS.id)window.view == view {return window}
	}
	return nil
}

window_for_delegate :: proc(delegate: NS.id) -> ^Window {
	for window in app.windows {
		if cast(NS.id)window.delegate == delegate {return window}
	}
	return nil
}

// host_key_window is the focused window, or the first one when none is focused.
host_key_window :: proc() -> ^Window {
	key := intrinsics.objc_send(^NS.Window, cast(^NS.Object)intrinsics.objc_find_class("NSWindow"), "keyWindow")
	if key != nil {
		for window in app.windows {if window.ns_window == key {return window}}
	}
	if len(app.windows) > 0 {return app.windows[0]}
	return nil
}

// host_build_menu gives the app the usual macOS menu: about, a manual update
// check, settings, hide and quit. Without it the app menu is empty.
host_build_menu :: proc() {
	application := app.application
	if application == nil {return}
	ns_menu :: proc() -> ^NS.Object {return intrinsics.objc_send(^NS.Object, cast(^NS.Object)intrinsics.objc_find_class("NSMenu"), "new")}
	ns_item :: proc() -> ^NS.Object {return intrinsics.objc_send(^NS.Object, cast(^NS.Object)intrinsics.objc_find_class("NSMenuItem"), "new")}

	menubar := ns_menu()
	app_item := ns_item()
	app_menu := NS.Menu_initWithTitle(NS.Menu_alloc(), edit_nsstring("hw_fileManager"))

	// add uses the same addItemWithTitle:action:keyEquivalent: the other apps use;
	// a nil target routes standard selectors (terminate:, hide:) through the app.
	add :: proc(menu: ^NS.Menu, title: string, selector: cstring, key: string, target: ^NS.Object) {
		item := intrinsics.objc_send(^NS.Object, menu, "addItemWithTitle:action:keyEquivalent:", edit_nsstring(title), NS.sel_registerName(selector), edit_nsstring(key))
		if target != nil {intrinsics.objc_send(nil, item, "setTarget:", target)}
	}
	add(app_menu, "About hw_fileManager", "orderFrontStandardAboutPanel:", "", nil)
	add(app_menu, "Check for Updates…", "fileManagerCheckForUpdates:", "", (^NS.Object)(app.delegate))
	add(app_menu, "Settings…", "fileManagerOpenSettings:", ",", (^NS.Object)(app.delegate))
	intrinsics.objc_send(nil, app_menu, "addItem:", NS.MenuItem_separatorItem())
	add(app_menu, "Hide hw_fileManager", "hide:", "h", nil)
	add(app_menu, "Quit hw_fileManager", "terminate:", "q", nil)
	intrinsics.objc_send(nil, app_item, "setSubmenu:", app_menu)
	intrinsics.objc_send(nil, menubar, "addItem:", app_item)
	intrinsics.objc_send(nil, application, "setMainMenu:", menubar)
}

// host_update_ready runs on the main thread when the update worker has staged a
// release, or finished a user-requested check that found nothing.
host_update_ready :: proc "c" (self: NS.id, cmd: NS.SEL, object: NS.id) {
	context = runtime.default_context()
	if !update_ready() {
		switch update_manual_result() {
		case .Up_To_Date:
			if window := host_key_window(); window != nil {notice_set(window, "you're up to date")}
		case .Error:
			if window := host_key_window(); window != nil {notice_set(window, "couldn't check for updates")}
		case .None:
		}
		update_manual_clear()
	}
	for window in app.windows {host_request_frames(window, 2)}
}

// host_manual_update_check is the Check for Updates… menu item.
host_manual_update_check :: proc() {
	window := host_key_window()
	if update_ready() {
		if window != nil {notice_set(window, "an update is ready; quit to install")}
		return
	}
	if !update_request_check() {
		if window != nil {notice_set(window, "update checks are unavailable in this build")}
		return
	}
	if window != nil {notice_set(window, "checking for updates…")}
	for w in app.windows {host_request_frames(w, 2)}
}

host_check_updates :: proc "c" (self: NS.id, cmd: NS.SEL, sender: NS.id) {
	context = runtime.default_context()
	host_manual_update_check()
}

host_open_settings_menu :: proc "c" (self: NS.id, cmd: NS.SEL, sender: NS.id) {
	context = runtime.default_context()
	window := host_key_window()
	if window == nil {return}
	settings_panel_open(window)
}

host_did_become_active :: proc "c" (self: NS.id, cmd: NS.SEL, notification: ^NS.Notification) {
	context = runtime.default_context()
	watch_mark()
}

// host_window_title is the path a window is looking at, shown in its chrome and
// in the Dock menu.
host_window_title :: proc(window: ^Window) -> string {
	if entry, ok := tree_selected_entry(&window.tree); ok {return entry.path}
	if window.tree.active >= 0 && window.tree.active < len(window.tree.columns) {return window.tree.columns[window.tree.active].dir}
	return tree_root_directory(&window.tree)
}

// applicationDockMenu: fills the Dock icon's right-click menu with one item per
// open window, like Cursor and VS Code, so a window can be raised without
// Mission Control.
host_dock_menu :: proc "c" (self: NS.id, cmd: NS.SEL, sender: ^NS.Application) -> ^NS.Menu {
	context = runtime.default_context()
	menu := NS.Menu_initWithTitle(NS.Menu_alloc(), edit_nsstring("Windows"))
	selector := NS.sel_registerName("fileManagerFocusWindow:")
	for window, index in app.windows {
		item := NS.MenuItem_initWithTitle(NS.MenuItem_alloc(), edit_nsstring(host_window_title(window)), selector, edit_nsstring(""))
		NS.MenuItem_setTarget(item, (^NS.Object)(self))
		NS.MenuItem_setTag(item, NS.Integer(index))
		NS.Menu_addItem(menu, item)
		NS.autorelease(cast(^NS.Object)item)
	}
	NS.autorelease(cast(^NS.Object)menu)
	return menu
}

host_focus_window_menu :: proc "c" (self: NS.id, cmd: NS.SEL, sender: ^NS.MenuItem) {
	context = runtime.default_context()
	index := int(NS.MenuItem_tag(sender))
	if index < 0 || index >= len(app.windows) {return}
	target := app.windows[index]
	target.ns_window->makeKeyAndOrderFront(nil)
	app.application->activateIgnoringOtherApps(true)
}

// The default window is created one run-loop turn after launch, so an open-file
// event from `hfm` (which arrives during launch) wins and we do not open both.
host_did_finish_launching :: proc "c" (self: NS.id, cmd: NS.SEL, notification: ^NS.Notification) {
	context = runtime.default_context()
	// Set after launch: AppKit replaces the main menu while finishing the launch.
	host_build_menu()
	intrinsics.objc_send(nil, app.delegate, "performSelector:withObject:afterDelay:", NS.sel_registerName("fileManagerCreateDefaultWindow:"), NS.id(nil), f64(0))
}

host_create_default_window :: proc "c" (self: NS.id, cmd: NS.SEL, object: NS.id) {
	context = runtime.default_context()
	if len(app.windows) > 0 {return}
	start := os.get_env("HW_FILE_MANAGER_PATH", context.temp_allocator)
	_ = window_create(start, ephemeral = false)
}

// application:openFiles: delivers the paths `hfm` passed to `open -b`; each one
// becomes an ephemeral window.
host_open_files :: proc "c" (self: NS.id, cmd: NS.SEL, sender: ^NS.Application, filenames: ^NS.Array) -> bool {
	context = runtime.default_context()
	for index in 0 ..< NS.Array_count(filenames) {
		name := NS.Array_objectAs(filenames, NS.UInteger(index), ^NS.String)
		_ = window_create(NS.String_odinString(name), ephemeral = true)
	}
	return true
}

host_open_file :: proc "c" (self: NS.id, cmd: NS.SEL, sender: ^NS.Application, filename: NS.id) -> bool {
	context = runtime.default_context()
	_ = window_create(NS.String_odinString((^NS.String)(filename)), ephemeral = true)
	return true
}

host_register_classes :: proc() -> (delegate_class, view_class: NS.Class, ok: bool) {
	if existing := intrinsics.objc_find_class("FileManagerDelegate"); existing != nil {
		view_existing := intrinsics.objc_find_class("FileManagerView")
		return existing, view_existing, view_existing != nil
	}
	delegate_class = NS.objc_allocateClassPair(intrinsics.objc_find_class("NSObject"), "FileManagerDelegate", 0)
	if delegate_class == nil {return nil, nil, false}
	if !host_add_method(delegate_class, "fileManagerFrame:", rawptr(host_on_frame), "v@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "applicationShouldTerminateAfterLastWindowClosed:", rawptr(host_should_terminate), "B@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "applicationWillTerminate:", rawptr(host_persist_state), "v@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "fileManagerUpdateReady:", rawptr(host_update_ready), "v@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "fileManagerCheckForUpdates:", rawptr(host_check_updates), "v@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "fileManagerOpenSettings:", rawptr(host_open_settings_menu), "v@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "applicationDockMenu:", rawptr(host_dock_menu), "@@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "fileManagerFocusWindow:", rawptr(host_focus_window_menu), "v@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "applicationDidBecomeActive:", rawptr(host_did_become_active), "v@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "applicationDidFinishLaunching:", rawptr(host_did_finish_launching), "v@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "application:openFiles:", rawptr(host_open_files), "v@:@@") {return nil, nil, false}
	if !host_add_method(delegate_class, "application:openFile:", rawptr(host_open_file), "B@:@@") {return nil, nil, false}
	if !host_add_method(delegate_class, "fileManagerCreateDefaultWindow:", rawptr(host_create_default_window), "v@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "windowWillClose:", rawptr(host_window_will_close), "v@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "windowDidResize:", rawptr(host_surface_changed), "v@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "windowDidChangeBackingProperties:", rawptr(host_surface_changed), "v@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "windowDidChangeScreen:", rawptr(host_surface_changed), "v@:@") {return nil, nil, false}
	NS.objc_registerClassPair(delegate_class)

	view_class = NS.objc_allocateClassPair(intrinsics.objc_find_class("NSView"), "FileManagerView", 0)
	if view_class == nil {return delegate_class, nil, false}
	if !host_add_method(view_class, "acceptsFirstResponder", rawptr(host_accepts_first), "B@:") {return delegate_class, view_class, false}
	if !host_add_method(view_class, "mouseDown:", rawptr(host_mouse_down), "v@:@") {return delegate_class, view_class, false}
	if !host_add_method(view_class, "mouseDragged:", rawptr(host_mouse_dragged), "v@:@") {return delegate_class, view_class, false}
	if !host_add_method(view_class, "mouseMoved:", rawptr(host_mouse_moved), "v@:@") {return delegate_class, view_class, false}
	if !host_add_method(view_class, "scrollWheel:", rawptr(host_scroll_wheel), "v@:@") {return delegate_class, view_class, false}
	if !host_add_method(view_class, "keyDown:", rawptr(host_key_down), "v@:@") {return delegate_class, view_class, false}
	if !host_add_method(view_class, "flagsChanged:", rawptr(host_flags_changed), "v@:@") {return delegate_class, view_class, false}
	NS.objc_registerClassPair(view_class)
	return delegate_class, view_class, true
}

host_new_delegate :: proc() -> ^NS.Object {
	instance := NS.class_createInstance(app.delegate_class, 0)
	return NS.init((^NS.Object)(instance))
}

app_initialize :: proc() -> bool {
	delegate_class, view_class, ok := host_register_classes()
	if !ok {
		fmt.eprintln("[hw_fileManager] could not register the Cocoa classes")
		host_failure(FAIL_COCOA_CLASSES, .Critical)
		return false
	}
	app.delegate_class = delegate_class
	app.view_class = view_class
	app.window_class = host_window_class()
	if app.window_class == nil {
		host_failure(FAIL_WINDOW_CLASS, .Critical)
		return false
	}
	app.delegate = host_new_delegate()
	app.application = NS.Application.sharedApplication()
	app.application->setActivationPolicy(.Regular)
	app.application->setDelegate((^NS.ApplicationDelegate)(app.delegate))

	app.settings = settings_defaults()
	_ = settings_load(settings_path(context.temp_allocator), &app.settings)
	app.safe_mode = diag.safe_update_count(diagnostics_config().app_name) >= diag.SAFE_MODE_CRASHES
	text_tracking = f32(app.settings.letter_spacing)/10

	app.device = MTL.CreateSystemDefaultDevice()
	if app.device == nil {
		host_failure(FAIL_METAL_DEVICE, .Critical)
		return false
	}
	app.queue = app.device->newCommandQueue()
	app.zoxide = cd_zoxide()
	app.terminals = terminals_detect()
	app.editors = editors_detect()
	app.cli_installed = cli_installed()
	if !app.safe_mode {update_start()}
	return true
}

// window_create builds one fully independent window. An ephemeral window never
// reads or writes the remembered place or frame.
window_create :: proc(start: string, ephemeral: bool) -> ^Window {
	site := devlog.Site{feature = "window", operation = "create"}
	kind := ephemeral ? "ephemeral" : "primary"
	devlog.started(devlog.global(), site, {stage = kind})
	window := new(Window)
	window.ephemeral = ephemeral
	coretext.context_init(&window.text)
	draw.list_init(&window.list, pixel_ratio = 2)
	register_mono_font(&window.text)
	font_apply(&window.text, &font_catalog, app.safe_mode ? "" : app.settings.font_family, app.safe_mode ? "" : app.settings.font_width, app.safe_mode ? "" : app.settings.font_weight)

	frame := NS.Rect{{120, 120}, {WINDOW_WIDTH, WINDOW_HEIGHT}}
	restored := false
	if !ephemeral {
		if saved := app.settings.window; NS.Float(saved.w) >= WINDOW_MIN_WIDTH && NS.Float(saved.h) >= WINDOW_MIN_HEIGHT && saved.w < 10000 && saved.h < 10000 {
			frame = {{NS.Float(saved.x), NS.Float(saved.y)}, {NS.Float(saved.w), NS.Float(saved.h)}}
			restored = true
		}
	}
	window.delegate = host_new_delegate()
	window.ns_window = (^NS.Window)(NS.class_createInstance(app.window_class, 0))
	window.ns_window = window.ns_window->initWithContentRect(frame, WINDOW_STYLE, .Buffered, false)
	window.ns_window->setReleasedWhenClosed(false)
	if window.ns_window == nil {
		host_failure(FAIL_WINDOW_CREATE, .Critical)
		devlog.failed(devlog.global(), site, {reason = FAIL_WINDOW_CREATE})
		window_destroy(window)
		return nil
	}
	window.ns_window->setMinSize({WINDOW_MIN_WIDTH, WINDOW_MIN_HEIGHT})
	window.ns_window->setAcceptsMouseMovedEvents(true)
	window.ns_window->setDelegate((^NS.WindowDelegate)(window.delegate))
	if !restored && !ephemeral {window.ns_window->center()}

	window.view = (^NS.View)(NS.class_createInstance(app.view_class, 0))
	window.view = window.view->initWithFrame({{0, 0}, frame.size})
	window.ns_window->setContentView(window.view)

	window.layer = QC.MetalLayer.layer()
	window.layer->setDevice(app.device)
	window.layer->setPixelFormat(.BGRA8Unorm)
	window.layer->setFramebufferOnly(true)
	window.view->setWantsLayer(true)
	window.view->setLayer((^NS.Layer)(window.layer))

	if !metal.renderer_init(
		&window.renderer,
		rawptr(app.device),
		pixel_format = uint(MTL.PixelFormat.BGRA8Unorm),
		metallib_data = UI_METALLIB,
	) {
		fmt.eprintln("[hw_fileManager] Metal renderer initialization failed")
		host_failure("Metal renderer initialization failed", .Critical)
		devlog.failed(devlog.global(), site, {reason = "Metal renderer initialization failed"})
		window_destroy(window)
		return nil
	}
	if !macos.display_link_start(
		&window.display_link,
		rawptr(window.view),
		rawptr(window.delegate),
		"fileManagerFrame:",
	) {
		fmt.eprintln("[hw_fileManager] the macOS 14 display link API is required")
		host_failure(FAIL_DISPLAY_LINK, .Critical)
		devlog.failed(devlog.global(), site, {reason = FAIL_DISPLAY_LINK})
		window_destroy(window)
		return nil
	}
	_ = window.ns_window->makeFirstResponder((^NS.Responder)(window.view))

	tree_init(&window.tree)
	window.tree.sort = sort_parse(app.settings.sort)
	window.gather_hot_row = -1
	tree_set_line_ratio(&window.tree, settings_line_ratio(app.settings))
	tree_set_font_size(&window.tree, f32(app.settings.font_size))

	opened := false
	if len(start) > 0 {
		opened = host_open_path(window, start)
	} else if !ephemeral {
		opened = host_restore_place(window)
	}
	if !opened {opened = host_open_home(window)}
	if !opened {
		devlog.failed(devlog.global(), site, {reason = "starting directory could not be opened"})
		window_destroy(window)
		return nil
	}
	window.initialized = true
	append(&app.windows, window)
	if ephemeral {host_place_new_window(window, len(app.windows)-1)}
	window.ns_window->makeKeyAndOrderFront(nil)
	app.application->activateIgnoringOtherApps(true)
	host_request_frames(window, 3)
	devlog.succeeded(devlog.global(), site, {stage = kind})
	return window
}

// host_open_path shows a directory as the cascade root, or a file's folder with
// the file selected.
host_open_path :: proc(window: ^Window, path: string) -> bool {
	info, error := os.lstat(path, context.temp_allocator)
	if error != nil {return false}
	is_dir := info.type == .Directory || (info.type == .Symlink && os.is_dir(path))
	os.file_info_delete(info, context.temp_allocator)
	if is_dir {return tree_open(&window.tree, path, grandparent = true)}
	if !tree_open(&window.tree, filepath.dir(path), grandparent = true) {return false}
	return tree_select_name(&window.tree, window.tree.active, filepath.base(path))
}

window_destroy :: proc(window: ^Window) {
	window_release(window, release_ns_window = true)
}

// window_release tears a window down. A window closed by the user is released
// later, without touching the NSWindow, because AppKit is mid-close and owns it.
window_release :: proc(window: ^Window, release_ns_window: bool) {
	for index in 0 ..< len(app.windows) {
		if app.windows[index] == window {
			ordered_remove(&app.windows, index)
			break
		}
	}
	if window.initialized {
		gather_destroy(&window.gather_paths)
		edit_cancel(window)
		input_destroy(window)
		preview_clear(&window.preview)
		text_input.destroy(&window.text_state)
		macos.display_link_stop(&window.display_link)
		tree_destroy(&window.tree)
		metal.renderer_destroy(&window.renderer)
		draw.list_destroy(&window.list)
		coretext.context_destroy(&window.text)
	}
	if window.view != nil {NS.release(window.view)}
	if release_ns_window && window.ns_window != nil {NS.release(window.ns_window)}
	if window.delegate != nil {NS.release(window.delegate)}
	free(window)
}

// host_window_will_close runs on a window's own delegate, so it only detaches
// the window; the free happens in host_reap_doomed once the callback has returned.
host_window_will_close :: proc "c" (self: NS.id, cmd: NS.SEL, notification: ^NS.Notification) {
	context = runtime.default_context()
	window := window_for_delegate(self)
	if window == nil {return}
	if !window.ephemeral {host_capture_window_frame(window)}
	for index in 0 ..< len(app.windows) {
		if app.windows[index] == window {
			ordered_remove(&app.windows, index)
			break
		}
	}
	macos.display_link_stop(&window.display_link)
	window.initialized = false
	append(&app.doomed, window)
}

host_reap_doomed :: proc() {
	for len(app.doomed) > 0 {
		window := pop(&app.doomed)
		// Safe here: the close callback that queued this window has returned.
		window_release(window, release_ns_window = true)
	}
}

host_open_home :: proc(window: ^Window) -> bool {
	if !tree_open(&window.tree, home_directory(), grandparent = true) {
		if !tree_open(&window.tree, "/", grandparent = true) {
			fmt.eprintln("[hw_fileManager] no readable starting directory")
			host_failure(FAIL_START_DIRECTORY, .Critical)
			return false
		}
		devlog.recovered(devlog.global(), {feature = "files", operation = "open_starting_directory"})
	}
	return true
}

// host_restore_place reopens the last selected path; it reports false when
// there is none or it no longer exists, so the caller starts at the usual place.
host_restore_place :: proc(window: ^Window) -> bool {
	place := app.settings.place
	if len(place) == 0 || !path_taken(place) {return false}
	if !tree_open(&window.tree, filepath.dir(place), grandparent = true) {return false}
	_ = tree_select_name(&window.tree, window.tree.active, filepath.base(place))
	return true
}

PLACE_SETTLE :: 500*time.Millisecond

host_current_place :: proc(window: ^Window) -> string {
	if entry, ok := tree_selected_entry(&window.tree); ok {return entry.path}
	if window.tree.active >= 0 && window.tree.active < len(window.tree.columns) {return window.tree.columns[window.tree.active].dir}
	return ""
}

// host_remember_place stores the selected path (or the active folder) so the next start
// resumes there. The write waits until the selection has rested, so moving through names
// does no disk work; the pending place is also written at quit. Only a non-ephemeral
// window remembers, so hfm and Cmd+N windows never clobber it.
host_remember_place :: proc(window: ^Window) {
	if window.ephemeral {return}
	place := host_current_place(window)
	if len(place) == 0 || place == app.settings.place {
		delete(window.place_pending)
		window.place_pending = ""
		return
	}
	if place != window.place_pending {
		delete(window.place_pending)
		window.place_pending = strings.clone(place)
		window.place_since = time.tick_now()
	}
	if time.tick_since(window.place_since) < PLACE_SETTLE {
		host_request_frames(window, 1)
		return
	}
	host_flush_place(window)
}

host_flush_place :: proc(window: ^Window) {
	if len(window.place_pending) == 0 {return}
	delete(app.settings.place)
	app.settings.place = window.place_pending
	window.place_pending = ""
	host_save_settings()
}

host_primary_window :: proc() -> ^Window {
	for window in app.windows {
		if !window.ephemeral {return window}
	}
	if len(app.windows) > 0 {return app.windows[0]}
	return nil
}

// host_save_settings persists the shared settings with the primary window's frame.
host_save_settings :: proc() {
	if window := host_primary_window(); window != nil {host_capture_window_frame(window)}
	_ = settings_save(settings_path(context.temp_allocator), app.settings)
}

app_shutdown :: proc() {
	host_reap_doomed()
	for len(app.windows) > 0 {window_destroy(app.windows[len(app.windows)-1])}
	action_clear_clip(nil)
	delete(app.windows)
	app.windows = nil
	delete(app.doomed)
	app.doomed = nil
	if app.device != nil {NS.release(app.device)}
	if app.queue != nil {NS.release(app.queue)}
	if app.delegate != nil {NS.release(app.delegate)}
	app = {}
}

host_request_frames :: proc(window: ^Window, count: int) {
	if window == nil || !window.initialized {return}
	window.frames_pending = max(window.frames_pending, count)
	if window.display_link.paused {macos.display_link_set_paused(&window.display_link, false)}
}

host_request_all_frames :: proc(count: int) {
	for window in app.windows {host_request_frames(window, count)}
}

host_search_bounds :: proc(window: ^Window) -> (view_top, view_bottom: f32) {
	return CHROME_HEIGHT, window.view_height-2*window.tree.row_height
}

host_render :: proc(window: ^Window) {
	if window.ns_window == nil || window.view == nil || window.layer == nil {return}
	pool := NS.scoped_autoreleasepool()
	_ = pool
	bounds := window.view->bounds()
	width := f32(bounds.size.width)
	height := f32(bounds.size.height)
	if width < 1 || height < 1 {return}
	window.view_width = width
	window.view_height = height
	scale := f32(window.ns_window->backingScaleFactor())
	if scale < 1 {scale = 1}
	window.layer->setContentsScale(NS.Float(scale))
	window.layer->setDrawableSize({NS.Float(width)*NS.Float(scale), NS.Float(height)*NS.Float(scale)})

	drawable := window.layer->nextDrawable()
	if drawable == nil {return}
	texture := drawable->texture()
	command_buffer := app.queue->commandBuffer()

	metal.begin_texture_frame(&window.renderer)
	coretext.begin_frame(&window.text, scale, metal.atlas_io(&window.renderer))
	draw.list_reset(&window.list)
	metrics := View_Metrics{
		width = width,
		height = height,
		char_advance = measure_char_advance(&window.text, window.tree.font_size),
		row_height = window.tree.row_height,
		bar_height = 2*window.tree.row_height,
	}
	window.char_advance = metrics.char_advance
	now := time.now()
	edit := View_Edit{
		active = window.edit_mode != .None,
		column = window.edit_column,
		row = window.edit_row,
		text = edit_text(window),
	}
	notice := ""
	notice_error := false
	if window.edit_mode != .None {
		edit.caret = window.text_state.caret_byte_offset
		edit.selection_start, edit.selection_end = text_input.selection_bounds(&window.text_state, window.edit_value)
		switch {
		case edit_conflict(window):
			edit.error = true
			notice = "an item with that name already exists"
			notice_error = true
		case len(window.edit_value) > 0 && edit_invalid(window.edit_value):
			edit.error = true
			notice = "invalid name"
			notice_error = true
		}
	}
	if len(notice) == 0 && window.notice_len > 0 && time.to_unix_nanoseconds(now)/1_000_000 < window.notice_until_ms {
		notice = string(window.notice[:window.notice_len])
		notice_error = true
	}
	if len(notice) == 0 && update_ready() {notice = fmt.tprintf("update %s will install when you quit", updater.prepared.manifest.version)}
	input_sel_start, input_sel_end := 0, 0
	if input_editing(window) {input_sel_start, input_sel_end = text_input.selection_bounds(&window.text_state, window.input_value)}
	if !app.safe_mode {preview_update(&window.preview, &window.tree, app.device)}
	frame_dt := f32(time.duration_seconds(time.tick_since(window.frame_tick)))
	if !window.frame_animated {frame_dt = 1.0/60}
	window.frame_tick = time.tick_now()
	if app.settings.animations_off {frame_dt = 0}
	if !view_layout(&window.tree, metrics, edit, min(frame_dt, 1.0/30)) {host_request_frames(window, 1)}
	window.frame_animated = window.tree.pan_moving
	if window.tree.pan_moving {host_request_frames(window, 1)}
	watch_follow()
	window.preview_rect, window.preview_shown = view_preview_rect(&window.tree, metrics)
	window.preview_shown = window.preview_shown && window.preview.kind != .None && !app.safe_mode
	if !preview_text_shown(window) {window.preview.focused = false}
	preview_scroll_to(window, window.preview.scroll)
	preview_view := preview_view_make(&window.preview, &window.renderer, scale, syntax_theme(syntax_theme_index(app.settings.syntax_theme)))
	preview_view.focused = window.preview.focused
	view_draw(&window.tree, &window.list, &window.text, metrics, View_State{
		settings = host_settings_view(window),
		settings_open = window.settings_open,
		sort_open = window.sort_open,
		settings_tab = window.settings_tab,
		width_locked = host_width_locked(),
		hot = {
			control = window.hot_control,
			settings_button = window.hot_settings_button,
			settings_hot = window.hot_settings_hot,
			sort_button = window.hot_sort_button,
			sort_row = window.hot_sort_row,
			safe_button = window.hot_safe_button,
			action = window.hot_action,
			action_hot = window.hot_action_hot,
		},
		input_mode = window.input_mode,
		input = input_text(window),
		input_editing = input_editing(window),
		input_caret = window.text_state.caret_byte_offset,
		input_sel_start = input_sel_start,
		input_sel_end = input_sel_end,
		search_committed = window.search_committed,
		cd_completing = window.cd_completing,
		preview = preview_view,
		preview_rect = window.preview_rect,
		preview_shown = window.preview_shown,
		clip_paths = app.clip_paths[:],
		clip_cut = app.clip_cut,
		gathered = len(window.gather_paths) > 0,
		current_gathered = action_current_gathered(window),
		gather_paths = window.gather_paths[:],
		gather_hot_row = window.gather_hot_row,
		gather_hot_clear = window.gather_hot_clear,
		edit = edit,
		notice = notice,
		notice_error = notice_error,
		shift = window.shift_down,
		safe_mode = app.safe_mode,
		cli_installed = app.cli_installed,
		cli_confirm = app.cli_confirm,
	})
	coretext.flush(&window.text)
	if !metal.encode_to_drawable(
		&window.renderer,
		rawptr(command_buffer),
		rawptr(texture),
		&window.list,
		{width, height},
		scale,
		COLOR_BACKGROUND,
	) {
		devlog.failed(devlog.global(), {feature = "presentation", operation = "frame"}, {
			reason = "Metal rendering failed",
			severity = .Critical,
		})
		return
	}
	command_buffer->presentDrawable((^MTL.Drawable)(drawable))
	command_buffer->commit()
}

host_pointer_from_event :: proc(window: ^Window, event: ^NS.Event) -> ui.Vec2 {
	point := window.view->convertPointFromView(event->locationInWindow(), nil)
	return {f32(point.x), window.view_height-f32(point.y)}
}

host_update_hover :: proc(window: ^Window, point: ui.Vec2) {
	if window.view_width < 1 || window.view_height < 1 {return}
	metrics := View_Metrics{
		width = window.view_width,
		height = window.view_height,
		char_advance = window.char_advance,
		row_height = window.tree.row_height,
		bar_height = 2*window.tree.row_height,
	}
	hover := overlay_hover(window, metrics, point)
	control := -1
	settings_button := false
	sort_button := false
	action := window.hot_action
	action_hot := false
	if !hover.modal {
		control = view_control_at(point, metrics)
		if control < 0 {settings_button = view_settings_control_at(point, metrics)}
		if !settings_button {sort_button = view_sort_control_at(point, &window.tree, metrics)}
		gathered := len(window.gather_paths) > 0
		if kind, inside := action_bar_at(metrics, point, gathered, action_current_gathered(window), window.shift_down); inside && action_available(&window.tree, gathered, len(app.clip_paths) > 0, kind) {
			action = kind
			action_hot = true
		}
	}
	if control == window.hot_control && settings_button == window.hot_settings_button && hover.settings_hot == window.hot_settings_hot && sort_button == window.hot_sort_button && hover.sort_row == window.hot_sort_row && hover.safe_button == window.hot_safe_button && action == window.hot_action && action_hot == window.hot_action_hot && hover.gather_row == window.gather_hot_row && hover.gather_clear == window.gather_hot_clear {return}
	window.hot_control = control
	window.hot_settings_button = settings_button
	window.hot_settings_hot = hover.settings_hot
	window.hot_sort_button = sort_button
	window.hot_sort_row = hover.sort_row
	window.hot_safe_button = hover.safe_button
	window.hot_action = action
	window.hot_action_hot = action_hot
	window.gather_hot_row = hover.gather_row
	window.gather_hot_clear = hover.gather_clear
	host_request_frames(window, 1)
}

host_capture_window_frame :: proc(window: ^Window) {
	if window.ns_window == nil {return}
	frame := window.ns_window->frame()
	app.settings.window = {f32(frame.origin.x), f32(frame.origin.y), f32(frame.size.width), f32(frame.size.height)}
}

host_persist_state :: proc "c" (self: NS.id, cmd: NS.SEL, notification: ^NS.Notification) {
	context = runtime.default_context()
	for window in app.windows {
		if window.ephemeral {continue}
		host_flush_place(window)
		host_capture_window_frame(window)
	}
	_ = settings_save(settings_path(context.temp_allocator), app.settings)
	update_finish()
	// terminate: can exit without returning through main, so stop the journal here
	// rather than relying on main's defer; otherwise every quit looks like a crash
	// and two of them trip safe mode.
	devlog.global_destroy()
}

// host_width_locked is true when the font has no other width to step to.
host_width_locked :: proc() -> bool {
	return len(app.settings.font_family) == 0 || len(font_family_widths(&font_catalog, app.settings.font_family)) < 2
}

// host_settings_view is the settings with the terminal that would actually open.
host_settings_view :: proc(window: ^Window) -> Settings {
	view := app.settings
	view.terminal = host_terminal()
	if window.settings_open {font_catalog_scan(&font_catalog)}
	view.font_weight = font_effective_style(&font_catalog, app.settings.font_family, app.settings.font_width, app.settings.font_weight)
	view.font_width = font_effective_width(&font_catalog, app.settings.font_family, app.settings.font_width)
	view.line_height = settings_line_percent(app.settings)
	return view
}

host_terminal :: proc() -> string {
	return terminal_effective(app.settings.terminal, app.terminals)
}

// host_sort_set re-reads every column in the new order; tree_refresh keeps the
// selection by path, and the sibling listings re-read on the next layout pass.
host_sort_set :: proc(sort: Sort) {
	if sort == sort_parse(app.settings.sort) {return}
	delete(app.settings.sort)
	app.settings.sort = strings.clone(sort_encode(sort))
	for window in app.windows {
		window.tree.sort = sort
		_ = tree_refresh(&window.tree)
	}
	host_save_settings()
	for window in app.windows {host_request_frames(window, 2)}
}

host_miniaturize :: proc(window: ^Window) {
	window.ns_window->setStyleMask(MINIMIZE_STYLE)
	intrinsics.objc_send(nil, window.ns_window, "miniaturize:", NS.id(nil))
	window.ns_window->setStyleMask(WINDOW_STYLE)
}

host_apply_control :: proc(window: ^Window, index: int) {
	switch index {
	case CONTROL_CLOSE:
		window.ns_window->close()
	case CONTROL_MINIMIZE:
		host_miniaturize(window)
	case CONTROL_ZOOM:
		intrinsics.objc_send(nil, window.ns_window, "zoom:", NS.id(nil))
	}
}

host_accepts_first :: proc "c" (self: NS.id, cmd: NS.SEL) -> bool {return true}

host_should_terminate :: proc "c" (self: NS.id, cmd: NS.SEL, sender: ^NS.Application) -> bool {return true}

// flagsChanged tracks Shift so the action labels flip while it is held; no key
// event arrives until another key is pressed.
host_flags_changed :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	context = runtime.default_context()
	window := window_for_view(self)
	if window == nil {return}
	down := .Shift in event->modifierFlags()
	if down == window.shift_down {return}
	window.shift_down = down
	host_request_frames(window, 1)
}

host_on_frame :: proc "c" (self: NS.id, cmd: NS.SEL, timer: NS.id) {
	context = runtime.default_context()
	host_reap_doomed()
	window := window_for_delegate(self)
	if window == nil {return}
	if window.frames_pending <= 0 {
		macos.display_link_set_paused(&window.display_link, true)
		return
	}
	// The frame is consumed before drawing, so a frame requested while drawing (a preview or
	// listing still waiting) survives it.
	window.frames_pending -= 1
	watch_refresh_due(window)
	host_render(window)
	host_remember_place(window)
	free_all(context.temp_allocator)
	if window.frames_pending <= 0 {macos.display_link_set_paused(&window.display_link, true)}
}

host_surface_changed :: proc "c" (self: NS.id, cmd: NS.SEL, notification: ^NS.Notification) {
	context = runtime.default_context()
	if window := window_for_delegate(self); window != nil {host_request_frames(window, 2)}
}

host_mouse_down :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	context = runtime.default_context()
	window := window_for_view(self)
	if window == nil {return}
	if window.view_width < 1 || window.view_height < 1 {return}
	point := host_pointer_from_event(window, event)
	window.shift_down = .Shift in event->modifierFlags()
	metrics := View_Metrics{
		width = window.view_width,
		height = window.view_height,
		char_advance = window.char_advance,
		row_height = window.tree.row_height,
		bar_height = 2*window.tree.row_height,
	}
	if window.preview_shown && point.x >= window.preview_rect.x && point.x < window.preview_rect.x+window.preview_rect.w && point.y >= window.preview_rect.y && point.y < window.preview_rect.y+window.preview_rect.h {return}
	if window.edit_mode != .None {
		edit_commit(window)
		host_request_frames(window, 2)
		return
	}
	if overlay_click(window, metrics, point) {return}
	if control := view_control_at(point, metrics); control >= 0 {
		host_apply_control(window, control)
		return
	}
	if view_sort_control_at(point, &window.tree, metrics) {
		window.sort_open = true
		host_request_frames(window, 2)
		return
	}
	if view_settings_control_at(point, metrics) {
		settings_panel_open(window)
		return
	}
	if point.y < CHROME_HEIGHT {
		if event->clickCount() >= 2 {
			host_apply_control(window, CONTROL_ZOOM)
			return
		}
		intrinsics.objc_send(nil, window.ns_window, "performWindowDragWithEvent:", event)
		return
	}
	if point.y >= window.view_height-window.tree.row_height {
		if kind, inside := action_bar_at(metrics, point, len(window.gather_paths) > 0, action_current_gathered(window), window.shift_down); inside {action_perform(window, kind, window.shift_down)}
		return
	}
	if point.y >= window.view_height-2*window.tree.row_height {
		input_reset(window)
		host_request_frames(window, 1)
		return
	}
	column := tree_column_at(&window.tree, point.x)
	row := column >= 0 ? tree_row_at(&window.tree, column, point.y) : -1
	if column >= 0 && row >= 0 {
		tree_focus_column(&window.tree, column)
		_ = tree_select(&window.tree, column, row)
	}
	host_request_frames(window, 2)
}

host_mouse_dragged :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	context = runtime.default_context()
	if window := window_for_view(self); window != nil {host_update_hover(window, host_pointer_from_event(window, event))}
}

WHEEL_ROWS_MAX :: 24

host_scroll_wheel :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	context = runtime.default_context()
	window := window_for_view(self)
	if window == nil {return}
	if window.settings_open || window.edit_mode != .None {return}
	point := host_pointer_from_event(window, event)
	delta := f32(event->scrollingDeltaY())
	precise := bool(event->hasPreciseScrollingDeltas())
	if preview_scroll_wheel(window, point.x, point.y, delta, precise) {
		host_request_frames(window, 2)
		return
	}
	// Anywhere else the wheel moves the selection through the active column, and
	// the cascade follows it as it does for the arrow keys.
	window.wheel_rows -= precise ? delta/window.tree.row_height : delta*3
	rows := int(window.wheel_rows)
	if rows == 0 {return}
	window.wheel_rows -= f32(rows)
	// One row at a time, like the arrow keys, so it carries on into the neighbouring folder.
	step := rows < 0 ? -1 : 1
	for _ in 0 ..< min(abs(rows), WHEEL_ROWS_MAX) {
		if !tree_move(&window.tree, step) {break}
	}
	host_request_frames(window, 2)
}

host_mouse_moved :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	context = runtime.default_context()
	if window := window_for_view(self); window != nil {host_update_hover(window, host_pointer_from_event(window, event))}
}

host_select_index :: proc(window: ^Window, index: int) -> bool {
	if window.tree.active < 0 || window.tree.active >= len(window.tree.columns) {return false}
	count := len(window.tree.columns[window.tree.active].entries)
	if count == 0 {return false}
	return tree_select(&window.tree, window.tree.active, clamp(index, 0, count-1), enter = false)
}

host_select_end :: proc(window: ^Window) -> bool {
	if window.tree.active < 0 || window.tree.active >= len(window.tree.columns) {return false}
	return host_select_index(window, len(window.tree.columns[window.tree.active].entries)-1)
}

host_key_down :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	context = runtime.default_context()
	window := window_for_view(self)
	if window == nil {return}
	command := .Command in event->modifierFlags()
	control := .Control in event->modifierFlags()
	option := .Option in event->modifierFlags()
	shift := .Shift in event->modifierFlags()
	window.shift_down = shift
	key := uint(event->keyCode())
	// Cmd+N is app-level, so it works with a modal or the sort menu open too.
	if command && key == 45 {
		host_new_window(window)
		return
	}
	if overlay_key(window, event, key, command, option, control, shift) {return}
	if window.edit_mode != .None && command && (key == 13 || key == 12) {
		if key == 13 {window.ns_window->close()} else {app.application->terminate(nil)}
		return
	}
	if window.edit_mode != .None {
		_ = edit_handle_key(window, event, key, command, option, control, shift)
		host_request_frames(window, 2)
		return
	}
	if input_editing(window) && key != 36 && key != 76 && key != 53 && key != 48 && key != 125 && key != 126 {
		if input_handle_key(window, event, key, command, option, control, shift) {
			host_request_frames(window, 2)
			return
		}
	}
	if !command && !control {
		if characters := event->characters(); characters != nil {
			if text := NS.String_odinString(characters); len(text) == 1 && text[0] >= 0x20 && text[0] < 0x7f {
				switch {
				case text[0] == '/' && window.input_mode == .None:
					search_begin(window)
				case window.input_mode == .None && action_is_number_key(key):
					// Numbered action shortcuts are handled in the switch below.
				case window.input_mode == .None:
					input_begin(window, .Cd)
					_ = text_input.insert_text(&window.text_state, &window.input_value, text)
				}
			}
		}
	}
	if window.input_mode == .None && !command && preview_handle_key(window, key) {
		host_request_frames(window, 2)
		return
	}
	switch {
	case command && key == 13:
		window.ns_window->close()
		return
	case command && key == 12:
		app.application->terminate(nil)
		return
	case command && key == 43:
		window.sort_open = false
		settings_panel_open(window)
		return
	case command && key == 15:
		_ = tree_refresh(&window.tree)
	case key == 51:
		if window.input_mode == .Search && window.search_committed {
			_ = text_input.delete_backward(&window.text_state, &window.input_value)
			search_refresh(window)
		}
	case key == 53:
		if path, ok := search_chosen_folder(window); ok {cd_remember(app.zoxide, path)}
		input_reset(window)
	case key == 126:
		if window.input_mode == .Cd {input_history_move(window, 1)} else {_ = tree_move(&window.tree, -1)}
	case key == 125:
		if window.input_mode == .Cd {input_history_move(window, -1)} else {_ = tree_move(&window.tree, 1)}
	case key == 123:
		_ = tree_collapse(&window.tree)
	case key == 124:
		if !preview_focus_begin(window) {_ = tree_expand(&window.tree)}
	case key == 36, key == 76:
		switch window.input_mode {
		case .Cd:     cd_run(window)
		case .OpenWith: settings_panel_open_with_commit(window)
		case .FontFamily: settings_panel_font_family_commit(window)
		case .Search:
			if window.search_committed {search_next(window, 1)} else {window.search_committed = true; text_input.collapse_selection(&window.text_state, window.input_value, len(window.input_value)); search_commit(window)}
		case .None:   host_enter(window)
		}
	case key == 48:
		if window.input_mode == .Cd {cd_complete(window)}
	case key == 45:
		if window.input_mode == .Search && window.search_committed {search_next(window, shift ? -1 : 1)}
	case key == 18, key == 19, key == 20, key == 21, key == 23, key == 22, key == 26, key == 28, key == 25, key == 29:
		if window.input_mode == .None {
			if kind, ok := action_number_key_code(key); ok {action_perform(window, kind, shift)}
		}
	case key == 115:
		_ = host_select_index(window, 0)
	case key == 119:
		_ = host_select_end(window)
	case key == 116:
		_ = tree_move(&window.tree, -10)
	case key == 121:
		_ = tree_move(&window.tree, 10)
	}
	host_request_frames(window, 2)
}

// host_new_window opens an ephemeral window on the focused window's current
// folder, offset a little so it does not sit exactly on top.
host_new_window :: proc(source: ^Window) -> ^Window {
	start := ""
	if source != nil {
		if entry, ok := tree_selected_entry(&source.tree); ok && entry.is_dir {start = entry.path} else {start = source.tree.columns[source.tree.active].dir}
	}
	return window_create(start, ephemeral = true)
}

// host_place_new_window puts an ephemeral window on the right of the screen,
// vertically centered, cascaded so stacked windows stay distinct, and clamped so
// it never lands under the menu bar or off the edge.
host_place_new_window :: proc(window: ^Window, cascade: int) {
	screen := NS.Screen_mainScreen()
	if screen == nil || window.ns_window == nil {return}
	visible := screen->visibleFrame()
	frame := window.ns_window->frame()
	step := NS.Float(24*(cascade % 6))
	x := visible.origin.x+visible.size.width-frame.size.width-NS.Float(24)-step
	y := visible.origin.y+(visible.size.height-frame.size.height)/2-step
	max_x := visible.origin.x+visible.size.width-frame.size.width
	max_y := visible.origin.y+visible.size.height-frame.size.height
	if x < visible.origin.x {x = visible.origin.x}
	if x > max_x {x = max_x}
	if y < visible.origin.y {y = visible.origin.y}
	if y > max_y {y = max_y}
	window.ns_window->setFrameOrigin({x, y})
}

// host_enter opens the selection: folders open as columns, text files take the
// focus into their preview (when there is anything to scroll), and every other
// file opens in its default app.
host_enter :: proc(window: ^Window) {
	if entry, ok := tree_selected_entry(&window.tree); ok && !entry.is_dir {
		if window.preview.kind == .Text {
			_ = preview_focus_begin(window)
		} else {
			action_open(window)
		}
		return
	}
	_ = tree_expand(&window.tree)
}

host_run :: proc() -> bool {
	if !app_initialize() {
		host_fatal_alert()
		return false
	}
	defer app_shutdown()
	devlog.started(devlog.global(), {feature = "app", operation = "presentation"})
	// The first window is created by applicationDidFinishLaunching, so an hfm
	// launch can suppress it in favour of the folder it was asked to open.
	app.application->run()
	devlog.stopped(devlog.global(), {feature = "app", operation = "presentation"})
	return true
}
