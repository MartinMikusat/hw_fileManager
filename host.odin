package file_manager

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import QC "vendor:darwin/QuartzCore"
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
	typed:          [TYPED_MAX]u8,
	typed_len:      int,
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

host_register_classes :: proc() -> (delegate: ^NS.Object, view_class: NS.Class, ok: bool) {
	delegate_class := NS.objc_allocateClassPair(intrinsics.objc_find_class("NSObject"), "FileManagerDelegate", 0)
	if delegate_class == nil {return nil, nil, false}
	if !host_add_method(delegate_class, "fileManagerFrame:", rawptr(host_on_frame), "v@:@") {return nil, nil, false}
	if !host_add_method(delegate_class, "applicationShouldTerminateAfterLastWindowClosed:", rawptr(host_should_terminate), "B@:@") {return nil, nil, false}
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

	frame := NS.Rect{{120, 120}, {WINDOW_WIDTH, WINDOW_HEIGHT}}
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
	host.window->center()

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
	host.settings = settings_defaults()
	_ = settings_load(settings_path(context.temp_allocator), &host.settings)
	tree_set_font_size(&host.tree, f32(host.settings.font_size))
	host.zoxide = cd_zoxide()
	start := os.get_env("HW_FILE_MANAGER_PATH", context.temp_allocator)
	if len(start) == 0 {start = home_directory()}
	if !tree_open(&host.tree, start) {
		if !tree_open(&host.tree, "/") {
			fmt.eprintln("[hw_fileManager] no readable starting directory")
			host_failure("no readable starting directory", .Critical)
			return false
		}
		devlog.recovered(devlog.global(), {feature = "files", operation = "open_starting_directory"})
	}
	host.initialized = true
	host.window->makeKeyAndOrderFront(nil)
	host.app->activateIgnoringOtherApps(true)
	host_request_frames(3)
	return true
}

host_shutdown :: proc() {
	if !host.initialized {return}
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
	}
	host.char_advance = metrics.char_advance
	view_layout(&host.tree, metrics)
	view_draw(&host.tree, &host.list, &host.text, metrics, host.settings, host.settings_open, {
		control = host.hot_control,
		settings_button = host.hot_settings_button,
		settings_hot = host.hot_settings_hot,
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
	}
	control := -1
	settings_button := false
	settings_hot := Settings_Hot.None
	if host.settings_open {
		settings_hot, _ = view_settings_hot(view_settings_layout(&host.tree, metrics), point)
	} else {
		control = view_control_at(point, metrics)
		if control < 0 {settings_button = view_settings_control_at(point, metrics)}
	}
	if control == host.hot_control && settings_button == host.hot_settings_button && settings_hot == host.hot_settings_hot {return}
	host.hot_control = control
	host.hot_settings_button = settings_button
	host.hot_settings_hot = settings_hot
	host_request_frames(1)
}

host_settings_adjust :: proc(delta: int) {
	next := settings_font_size_clamped(host.settings.font_size+delta)
	if next == host.settings.font_size {return}
	host.settings.font_size = next
	_ = tree_set_font_size(&host.tree, f32(next))
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
	host_render()
	host.frames_pending -= 1
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
	if !command && !control {
		if characters := event->characters(); characters != nil {
			if text := NS.String_odinString(characters); len(text) == 1 && text[0] >= 0x20 && text[0] < 0x7f {
				cd_typed_append(&host, text[0])
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
		if host.typed_len > 0 {host.typed_len -= 1}
	case key == 53:
		host.typed_len = 0
	case key == 126:
		_ = tree_move(&host.tree, -1)
	case key == 125:
		_ = tree_move(&host.tree, 1)
	case key == 123:
		_ = tree_collapse(&host.tree)
	case key == 124:
		_ = tree_expand(&host.tree)
	case key == 36:
		if host.typed_len > 0 {cd_run(&host)} else {_ = tree_expand(&host.tree)}
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
