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

WINDOW_WIDTH :: NS.Float(1100)
WINDOW_HEIGHT :: NS.Float(720)
WINDOW_MIN_WIDTH :: NS.Float(520)
WINDOW_MIN_HEIGHT :: NS.Float(320)
WINDOW_STYLE :: NS.WindowStyleMask{.Closable, .Miniaturizable, .Resizable}
MINIMIZE_STYLE :: NS.WindowStyleMask{.Titled, .Closable, .Miniaturizable, .Resizable}

CONTROL_CLOSE :: 0
CONTROL_MINIMIZE :: 1
CONTROL_ZOOM :: 2

Host :: struct {
	app:            ^NS.Application,
	delegate:       ^NS.Object,
	window:         ^NS.Window,
	view:           ^NS.View,
	device:         ^MTL.Device,
	queue:          ^MTL.CommandQueue,
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
	settings:       Settings,
	settings_open:  bool,
	zoxide:         string,
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
	clip_path:      string,
	clip_cut:       bool,
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
	frames_pending: int,
	initialized:    bool,
}

host: Host

register_system_monospaced :: proc(text: ^coretext.Context) -> bool {
	font := intrinsics.objc_send(
		^NS.Object,
		cast(^NS.Object)intrinsics.objc_find_class("NSFont"),
		"monospacedSystemFontOfSize:weight:",
		f64(DEFAULT_FONT_SIZE),
		f64(0),
	)
	if font == nil {return false}
	name := intrinsics.objc_send(^NS.String, font, "fontName")
	if name == nil {return false}
	coretext.register_font(text, FONT_MONO, NS.String_odinString(name))
	return true
}

measure_char_advance :: proc(text: ^coretext.Context, font_size: f32) -> f32 {
	run := coretext.shape(text, FONT_MONO, "MMMMMMMMMM", font_size, 0, 0, false)
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
}

notice_set :: proc(host: ^Host, text: string) {
	length := min(len(text), NOTICE_MAX)
	copy(host.notice[:length], text[:length])
	host.notice_len = length
	host.notice_until_ms = time.to_unix_nanoseconds(time.now())/1_000_000+3000
}

host_register_classes :: proc() -> (delegate: ^NS.Object, view_class: NS.Class, ok: bool) {
	delegate_class := NS.objc_allocateClassPair(intrinsics.objc_find_class("NSObject"), "FileManagerDelegate", 0)
	if delegate_class == nil {return nil, nil, false}
	if !host_add_method(delegate_class, "fileManagerFrame:", rawptr(host_on_frame), "v@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "applicationShouldTerminateAfterLastWindowClosed:", rawptr(host_should_terminate), "B@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "applicationWillTerminate:", rawptr(host_persist_state), "v@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "windowDidResize:", rawptr(host_surface_changed), "v@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "windowDidChangeBackingProperties:", rawptr(host_surface_changed), "v@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "windowDidChangeScreen:", rawptr(host_surface_changed), "v@:@") {return nil, nil, false}
	NS.objc_registerClassPair(delegate_class)
	delegate_id := NS.class_createInstance(delegate_class, 0)
	delegate = NS.init((^NS.Object)(delegate_id))

	view_class = NS.objc_allocateClassPair(intrinsics.objc_find_class("NSView"), "FileManagerView", 0)
	if view_class == nil {return delegate, nil, false}
	if !host_add_method(view_class, "acceptsFirstResponder", rawptr(host_accepts_first), "B@:") {return delegate, view_class, false}
	if !host_add_method(view_class, "mouseDown:", rawptr(host_mouse_down), "v@:@") {return delegate, view_class, false}
	if !host_add_method(view_class, "mouseDragged:", rawptr(host_mouse_dragged), "v@:@") {return delegate, view_class, false}
	if !host_add_method(view_class, "mouseMoved:", rawptr(host_mouse_moved), "v@:@") {return delegate, view_class, false}
	if !host_add_method(view_class, "keyDown:", rawptr(host_key_down), "v@:@") {return delegate, view_class, false}
	NS.objc_registerClassPair(view_class)
	return delegate, view_class, true
}

host_initialize :: proc() -> bool {
	coretext.context_init(&host.text)
	draw.list_init(&host.list, pixel_ratio = 2)
	if !register_system_monospaced(&host.text) {
		fmt.eprintln("[hw_fileManager] could not register the system monospaced font")
		host_failure("system monospaced font could not be registered", .Critical)
		return false
	}
	delegate, view_class, ok := host_register_classes()
	if !ok {
		fmt.eprintln("[hw_fileManager] could not register the Cocoa classes")
		host_failure("Cocoa classes could not be registered", .Critical)
		return false
	}
	host.delegate = delegate
	host.app = NS.Application.sharedApplication()
	host.app->setActivationPolicy(.Regular)
	host.app->setDelegate((^NS.ApplicationDelegate)(delegate))

	host.settings = settings_defaults()
	_ = settings_load(settings_path(context.temp_allocator), &host.settings)

	frame := NS.Rect{{120, 120}, {WINDOW_WIDTH, WINDOW_HEIGHT}}
	restored := false
	if saved := host.settings.window; NS.Float(saved.w) >= WINDOW_MIN_WIDTH && NS.Float(saved.h) >= WINDOW_MIN_HEIGHT && saved.w < 10000 && saved.h < 10000 {
		frame = {{NS.Float(saved.x), NS.Float(saved.y)}, {NS.Float(saved.w), NS.Float(saved.h)}}
		restored = true
	}
	window_class := host_window_class()
	if window_class == nil {
		host_failure("window class could not be registered", .Critical)
		return false
	}
	host.window = (^NS.Window)(NS.class_createInstance(window_class, 0))
	host.window = host.window->initWithContentRect(frame, WINDOW_STYLE, .Buffered, false)
	if host.window == nil {
		host_failure("window could not be created", .Critical)
		return false
	}
	host.window->setMinSize({WINDOW_MIN_WIDTH, WINDOW_MIN_HEIGHT})
	host.window->setAcceptsMouseMovedEvents(true)
	host.window->setDelegate((^NS.WindowDelegate)(delegate))
	if !restored {host.window->center()}

	host.view = (^NS.View)(NS.class_createInstance(view_class, 0))
	host.view = host.view->initWithFrame({{0, 0}, frame.size})
	host.window->setContentView(host.view)

	host.device = MTL.CreateSystemDefaultDevice()
	if host.device == nil {
		host_failure("Metal device is unavailable", .Critical)
		return false
	}
	host.queue = host.device->newCommandQueue()
	host.layer = QC.MetalLayer.layer()
	host.layer->setDevice(host.device)
	host.layer->setPixelFormat(.BGRA8Unorm)
	host.layer->setFramebufferOnly(true)
	host.view->setWantsLayer(true)
	host.view->setLayer((^NS.Layer)(host.layer))

	if !metal.renderer_init(
		&host.renderer,
		rawptr(host.device),
		pixel_format = uint(MTL.PixelFormat.BGRA8Unorm),
		metallib_data = UI_METALLIB,
	) {
		fmt.eprintln("[hw_fileManager] Metal renderer initialization failed")
		host_failure("Metal renderer initialization failed", .Critical)
		return false
	}
	if !macos.display_link_start(
		&host.display_link,
		rawptr(host.view),
		rawptr(host.delegate),
		"fileManagerFrame:",
	) {
		fmt.eprintln("[hw_fileManager] the macOS 14 display link API is required")
		host_failure("the macOS 14 display link API is unavailable", .Critical)
		return false
	}
	_ = host.window->makeFirstResponder((^NS.Responder)(host.view))

	tree_init(&host.tree)
	tree_set_font_size(&host.tree, f32(host.settings.font_size))
	host.zoxide = cd_zoxide()
	start := os.get_env("HW_FILE_MANAGER_PATH", context.temp_allocator)
	if len(start) > 0 {
		if !tree_open(&host.tree, start) && !host_open_home() {return false}
	} else if !host_restore_place() && !host_open_home() {
		return false
	}
	host.initialized = true
	host.window->makeKeyAndOrderFront(nil)
	host.app->activateIgnoringOtherApps(true)
	host_request_frames(3)
	return true
}

host_open_home :: proc() -> bool {
	if !tree_open(&host.tree, home_directory()) {
		if !tree_open(&host.tree, "/") {
			fmt.eprintln("[hw_fileManager] no readable starting directory")
			host_failure("no readable starting directory", .Critical)
			return false
		}
		devlog.recovered(devlog.global(), {feature = "files", operation = "open_starting_directory"})
	}
	return true
}

// host_restore_place reopens the last selected path; it reports false when
// there is none or it no longer exists, so the caller starts at the usual place.
host_restore_place :: proc() -> bool {
	place := host.settings.place
	if len(place) == 0 || !path_taken(place) {return false}
	if !tree_open(&host.tree, filepath.dir(place)) {return false}
	_ = tree_select_name(&host.tree, host.tree.active, filepath.base(place))
	return true
}

PLACE_SETTLE :: 500*time.Millisecond

host_current_place :: proc() -> string {
	if entry, ok := tree_selected_entry(&host.tree); ok {return entry.path}
	if host.tree.active >= 0 && host.tree.active < len(host.tree.columns) {return host.tree.columns[host.tree.active].dir}
	return ""
}

// host_remember_place stores the selected path (or the active folder) so the next start
// resumes there. The write waits until the selection has rested, so moving through names
// does no disk work; the pending place is also written at quit.
host_remember_place :: proc() {
	place := host_current_place()
	if len(place) == 0 || place == host.settings.place {
		delete(host.place_pending)
		host.place_pending = ""
		return
	}
	if place != host.place_pending {
		delete(host.place_pending)
		host.place_pending = strings.clone(place)
		host.place_since = time.tick_now()
	}
	if time.tick_since(host.place_since) < PLACE_SETTLE {
		host_request_frames(1)
		return
	}
	host_flush_place()
}

host_flush_place :: proc() {
	if len(host.place_pending) == 0 {return}
	delete(host.settings.place)
	host.settings.place = host.place_pending
	host.place_pending = ""
	host_capture_window_frame()
	_ = settings_save(settings_path(context.temp_allocator), host.settings)
}

host_shutdown :: proc() {
	if !host.initialized {return}
	if len(host.clip_path) > 0 {delete(host.clip_path, context.allocator)}
	edit_cancel(&host)
	input_destroy(&host)
	preview_clear(&host.preview)
	text_input.destroy(&host.text_state)
	macos.display_link_stop(&host.display_link)
	tree_destroy(&host.tree)
	metal.renderer_destroy(&host.renderer)
	draw.list_destroy(&host.list)
	coretext.context_destroy(&host.text)
	if host.view != nil {NS.release(host.view)}
	if host.window != nil {NS.release(host.window)}
	if host.delegate != nil {NS.release(host.delegate)}
	host = {}
}

host_request_frames :: proc(count: int) {
	if !host.initialized {return}
	host.frames_pending = max(host.frames_pending, count)
	if host.display_link.paused {macos.display_link_set_paused(&host.display_link, false)}
}

host_search_bounds :: proc(host: ^Host) -> (view_top, view_bottom: f32) {
	return CHROME_HEIGHT, host.view_height-2*host.tree.row_height
}

host_render :: proc() {
	if host.window == nil || host.view == nil || host.layer == nil {return}
	pool := NS.scoped_autoreleasepool()
	_ = pool
	bounds := host.view->bounds()
	width := f32(bounds.size.width)
	height := f32(bounds.size.height)
	if width < 1 || height < 1 {return}
	host.view_width = width
	host.view_height = height
	scale := f32(host.window->backingScaleFactor())
	if scale < 1 {scale = 1}
	host.layer->setContentsScale(NS.Float(scale))
	host.layer->setDrawableSize({NS.Float(width)*NS.Float(scale), NS.Float(height)*NS.Float(scale)})

	drawable := host.layer->nextDrawable()
	if drawable == nil {return}
	texture := drawable->texture()
	command_buffer := host.queue->commandBuffer()

	metal.begin_texture_frame(&host.renderer)
	coretext.begin_frame(&host.text, scale, metal.atlas_io(&host.renderer))
	draw.list_reset(&host.list)
	metrics := View_Metrics{
		width = width,
		height = height,
		char_advance = measure_char_advance(&host.text, host.tree.font_size),
		row_height = host.tree.row_height,
		bar_height = 2*host.tree.row_height,
	}
	host.char_advance = metrics.char_advance
	now := time.now()
	edit := View_Edit{
		active = host.edit_mode != .None,
		column = host.edit_column,
		row = host.edit_row,
		text = edit_text(&host),
	}
	notice := ""
	notice_error := false
	if host.edit_mode != .None {
		edit.caret = host.text_state.caret_byte_offset
		edit.selection_start, edit.selection_end = text_input.selection_bounds(&host.text_state, host.edit_value)
		switch {
		case edit_conflict(&host):
			edit.error = true
			notice = "a file with that name already exists"
			notice_error = true
		case len(host.edit_value) > 0 && edit_invalid(host.edit_value):
			edit.error = true
			notice = "invalid name"
			notice_error = true
		}
	}
	if len(notice) == 0 && host.notice_len > 0 && time.to_unix_nanoseconds(now)/1_000_000 < host.notice_until_ms {
		notice = string(host.notice[:host.notice_len])
		notice_error = true
	}
	input_sel_start, input_sel_end := 0, 0
	if input_editing(&host) {input_sel_start, input_sel_end = text_input.selection_bounds(&host.text_state, host.input_value)}
	if preview_update(&host.preview, &host.tree, host.device) {host_request_frames(1)}
	if !view_layout(&host.tree, metrics, edit) {host_request_frames(1)}
	host.preview_rect, host.preview_shown = view_preview_rect(&host.tree, metrics)
	preview_view := preview_view_make(&host.preview, &host.renderer, scale)
	host.preview_shown = host.preview_shown && host.preview.kind != .None
	view_draw(&host.tree, &host.list, &host.text, metrics, View_State{
		settings = host.settings,
		settings_open = host.settings_open,
		hot = {
			control = host.hot_control,
			settings_button = host.hot_settings_button,
			settings_hot = host.hot_settings_hot,
			action = host.hot_action,
			action_hot = host.hot_action_hot,
		},
		input_mode = host.input_mode,
		input = input_text(&host),
		input_editing = input_editing(&host),
		input_caret = host.text_state.caret_byte_offset,
		input_sel_start = input_sel_start,
		input_sel_end = input_sel_end,
		search_committed = host.search_committed,
		cd_completing = host.cd_completing,
		preview = preview_view,
		preview_rect = host.preview_rect,
		preview_shown = host.preview_shown,
		clip_path = host.clip_path,
		clip_cut = host.clip_cut,
		edit = edit,
		notice = notice,
		notice_error = notice_error,
		now = now,
	})
	coretext.flush(&host.text)
	if !metal.encode_to_drawable(
		&host.renderer,
		rawptr(command_buffer),
		rawptr(texture),
		&host.list,
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

host_pointer_from_event :: proc(event: ^NS.Event) -> ui.Vec2 {
	point := host.view->convertPointFromView(event->locationInWindow(), nil)
	return {f32(point.x), host.view_height-f32(point.y)}
}

host_update_hover :: proc(point: ui.Vec2) {
	if host.view_width < 1 || host.view_height < 1 {return}
	metrics := View_Metrics{
		width = host.view_width,
		height = host.view_height,
		char_advance = host.char_advance,
		row_height = host.tree.row_height,
		bar_height = 2*host.tree.row_height,
	}
	control := -1
	settings_button := false
	settings_hot := Settings_Hot.None
	action := host.hot_action
	action_hot := false
	if host.settings_open {
		settings_hot, _ = view_settings_hot(view_settings_layout(&host.tree, metrics), point)
	} else {
		control = view_control_at(point, metrics)
		if control < 0 {settings_button = view_settings_control_at(point, metrics)}
		if kind, inside := action_bar_at(metrics, point); inside && action_available(&host.tree, host.clip_path, kind) {
			action = kind
			action_hot = true
		}
	}
	if control == host.hot_control && settings_button == host.hot_settings_button && settings_hot == host.hot_settings_hot && action == host.hot_action && action_hot == host.hot_action_hot {return}
	host.hot_control = control
	host.hot_settings_button = settings_button
	host.hot_settings_hot = settings_hot
	host.hot_action = action
	host.hot_action_hot = action_hot
	host_request_frames(1)
}

host_capture_window_frame :: proc() {
	if host.window == nil {return}
	frame := host.window->frame()
	host.settings.window = {f32(frame.origin.x), f32(frame.origin.y), f32(frame.size.width), f32(frame.size.height)}
}

host_persist_state :: proc "c" (self: NS.id, cmd: NS.SEL, notification: ^NS.Notification) {
	context = runtime.default_context()
	host_flush_place()
	host_capture_window_frame()
	_ = settings_save(settings_path(context.temp_allocator), host.settings)
}

host_settings_adjust :: proc(delta: int) {
	next := settings_font_size_clamped(host.settings.font_size+delta)
	if next == host.settings.font_size {return}
	host.settings.font_size = next
	_ = tree_set_font_size(&host.tree, f32(next))
	host_capture_window_frame()
	_ = settings_save(settings_path(context.temp_allocator), host.settings)
	host_request_frames(2)
}

host_miniaturize :: proc() {
	host.window->setStyleMask(MINIMIZE_STYLE)
	intrinsics.objc_send(nil, host.window, "miniaturize:", NS.id(nil))
	host.window->setStyleMask(WINDOW_STYLE)
}

host_apply_control :: proc(index: int) {
	switch index {
	case CONTROL_CLOSE:
		host.window->close()
	case CONTROL_MINIMIZE:
		host_miniaturize()
	case CONTROL_ZOOM:
		intrinsics.objc_send(nil, host.window, "zoom:", NS.id(nil))
	}
}

host_accepts_first :: proc "c" (self: NS.id, cmd: NS.SEL) -> bool {return true}

host_should_terminate :: proc "c" (self: NS.id, cmd: NS.SEL, app: ^NS.Application) -> bool {return true}

host_on_frame :: proc "c" (self: NS.id, cmd: NS.SEL, timer: NS.id) {
	context = runtime.default_context()
	if host.frames_pending <= 0 {
		macos.display_link_set_paused(&host.display_link, true)
		return
	}
	// The frame is consumed before drawing, so a frame requested while drawing (a preview or
	// listing still waiting) survives it.
	host.frames_pending -= 1
	host_render()
	host_remember_place()
	free_all(context.temp_allocator)
	if host.frames_pending <= 0 {macos.display_link_set_paused(&host.display_link, true)}
}

host_surface_changed :: proc "c" (self: NS.id, cmd: NS.SEL, notification: ^NS.Notification) {
	context = runtime.default_context()
	host_request_frames(2)
}

host_mouse_down :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	context = runtime.default_context()
	if host.view_width < 1 || host.view_height < 1 {return}
	point := host_pointer_from_event(event)
	metrics := View_Metrics{
		width = host.view_width,
		height = host.view_height,
		char_advance = host.char_advance,
		row_height = host.tree.row_height,
		bar_height = 2*host.tree.row_height,
	}
	if host.preview_shown && point.x >= host.preview_rect.x && point.x < host.preview_rect.x+host.preview_rect.w && point.y >= host.preview_rect.y && point.y < host.preview_rect.y+host.preview_rect.h {return}
	if host.edit_mode != .None {
		edit_commit(&host)
		host_request_frames(2)
		return
	}
	if host.settings_open {
		hot, inside := view_settings_hot(view_settings_layout(&host.tree, metrics), point)
		if !inside {
			host.settings_open = false
			host_request_frames(2)
		} else if hot == .Minus {
			host_settings_adjust(-1)
		} else if hot == .Plus {
			host_settings_adjust(1)
		}
		return
	}
	if control := view_control_at(point, metrics); control >= 0 {
		host_apply_control(control)
		return
	}
	if view_settings_control_at(point, metrics) {
		host.settings_open = true
		host_request_frames(2)
		return
	}
	if point.y < CHROME_HEIGHT {
		if event->clickCount() >= 2 {
			host_apply_control(CONTROL_ZOOM)
			return
		}
		intrinsics.objc_send(nil, host.window, "performWindowDragWithEvent:", event)
		return
	}
	if point.y >= host.view_height-host.tree.row_height {
		if kind, inside := action_bar_at(metrics, point); inside {action_perform(&host, kind)}
		return
	}
	if point.y >= host.view_height-2*host.tree.row_height {
		input_reset(&host)
		host_request_frames(1)
		return
	}
	column := tree_column_at(&host.tree, point.x)
	row := column >= 0 ? tree_row_at(&host.tree, column, point.y) : -1
	if column >= 0 && row >= 0 {
		tree_focus_column(&host.tree, column)
		_ = tree_select(&host.tree, column, row)
	}
	host_request_frames(2)
}

host_mouse_dragged :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	context = runtime.default_context()
	host_update_hover(host_pointer_from_event(event))
}

host_mouse_moved :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	context = runtime.default_context()
	host_update_hover(host_pointer_from_event(event))
}

host_select_index :: proc(index: int) -> bool {
	if host.tree.active < 0 || host.tree.active >= len(host.tree.columns) {return false}
	count := len(host.tree.columns[host.tree.active].entries)
	if count == 0 {return false}
	return tree_select(&host.tree, host.tree.active, clamp(index, 0, count-1), enter = false)
}

host_select_end :: proc() -> bool {
	if host.tree.active < 0 || host.tree.active >= len(host.tree.columns) {return false}
	return host_select_index(len(host.tree.columns[host.tree.active].entries)-1)
}

host_key_down :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	context = runtime.default_context()
	command := .Command in event->modifierFlags()
	control := .Control in event->modifierFlags()
	option := .Option in event->modifierFlags()
	shift := .Shift in event->modifierFlags()
	key := uint(event->keyCode())
	if host.settings_open {
		switch {
		case command && key == 13:
			host.window->close()
		case command && key == 12:
			host.app->terminate(nil)
		case key == 53, command && key == 43:
			host.settings_open = false
			host_request_frames(1)
		}
		return
	}
	if host.edit_mode != .None && command && (key == 13 || key == 12) {
		if key == 13 {host.window->close()} else {host.app->terminate(nil)}
		return
	}
	if host.edit_mode != .None {
		_ = edit_handle_key(&host, event, key, command, option, control, shift)
		host_request_frames(2)
		return
	}
	if input_editing(&host) && key != 36 && key != 76 && key != 53 && key != 48 && key != 125 && key != 126 {
		if input_handle_key(&host, event, key, command, option, control, shift) {
			host_request_frames(2)
			return
		}
	}
	if !command && !control {
		if characters := event->characters(); characters != nil {
			if text := NS.String_odinString(characters); len(text) == 1 && text[0] >= 0x20 && text[0] < 0x7f {
				switch {
				case text[0] == '/' && host.input_mode == .None:
					search_begin(&host)
				case text[0] >= '1' && text[0] <= '5' && host.input_mode == .None:
					// Numbered action shortcuts are handled in the switch below.
				case host.input_mode == .None:
					input_begin(&host, .Cd)
					_ = text_input.insert_text(&host.text_state, &host.input_value, text)
				}
			}
		}
	}
	switch {
	case command && key == 13:
		host.window->close()
		return
	case command && key == 12:
		host.app->terminate(nil)
		return
	case command && key == 43:
		host.settings_open = true
		host_request_frames(1)
		return
	case command && key == 15:
		_ = tree_refresh(&host.tree)
	case key == 51:
		if host.input_mode == .Search && host.search_committed {
			_ = text_input.delete_backward(&host.text_state, &host.input_value)
			search_refresh(&host)
		}
	case key == 53:
		input_reset(&host)
	case key == 126:
		if host.input_mode == .Cd {input_history_move(&host, 1)} else {_ = tree_move(&host.tree, -1)}
	case key == 125:
		if host.input_mode == .Cd {input_history_move(&host, -1)} else {_ = tree_move(&host.tree, 1)}
	case key == 123:
		_ = tree_collapse(&host.tree)
	case key == 124:
		_ = tree_expand(&host.tree)
	case key == 36, key == 76:
		switch host.input_mode {
		case .Cd:     cd_run(&host)
		case .Search:
			if host.search_committed {search_next(&host, 1)} else {host.search_committed = true; text_input.collapse_selection(&host.text_state, host.input_value, len(host.input_value)); search_commit(&host)}
		case .None:   _ = tree_expand(&host.tree)
		}
	case key == 48:
		if host.input_mode == .Cd {cd_complete(&host)}
	case key == 45:
		if host.input_mode == .Search && host.search_committed {search_next(&host, shift ? -1 : 1)}
	case key == 18, key == 19, key == 20, key == 21, key == 23:
		if host.input_mode == .None {
			if kind, ok := action_number_key_code(key); ok {action_perform(&host, kind)}
		}
	case key == 115:
		_ = host_select_index(0)
	case key == 119:
		_ = host_select_end()
	case key == 116:
		_ = tree_move(&host.tree, -10)
	case key == 121:
		_ = tree_move(&host.tree, 10)
	}
	host_request_frames(2)
}

host_run :: proc() -> bool {
	if !host_initialize() {return false}
	defer host_shutdown()
	devlog.started(devlog.global(), {feature = "app", operation = "presentation"})
	host.app->run()
	devlog.stopped(devlog.global(), {feature = "app", operation = "presentation"})
	return true
}
