package file_manager

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import coretext "ui_framework:coretext"
import draw "ui_framework:draw"
import metal "ui_framework:metal"

write_ppm :: proc(path: string, pixels: []u8, width, height: int) -> bool {
	file, create_error := os.create(path)
	if create_error != nil {return false}
	defer os.close(file)
	_, write_error := os.write_string(file, fmt.tprintf("P6\n%d %d\n255\n", width, height))
	if write_error != nil {return false}
	row := make([]u8, width*3, context.temp_allocator)
	defer delete(row, context.temp_allocator)
	for y in 0 ..< height {
		for x in 0 ..< width {
			pixel := (y*width+x)*4
			row[x*3+0] = pixels[pixel+2]
			row[x*3+1] = pixels[pixel+1]
			row[x*3+2] = pixels[pixel+0]
		}
		if _, row_error := os.write(file, row); row_error != nil {return false}
	}
	return true
}

run_offscreen :: proc(arguments: []string) -> bool {
	if len(arguments) < 1 {return false}
	path := arguments[0]
	width := 1100
	height := 720
	scale := f32(2)
	directory := ""
	for argument in arguments[1:] {
		switch {
		case strings.has_prefix(argument, "--width="):
			parsed, ok := strconv.parse_int(strings.trim_prefix(argument, "--width="))
			if !ok || parsed <= 0 {return false}
			width = parsed
		case strings.has_prefix(argument, "--height="):
			parsed, ok := strconv.parse_int(strings.trim_prefix(argument, "--height="))
			if !ok || parsed <= 0 {return false}
			height = parsed
		case strings.has_prefix(argument, "--scale="):
			parsed, ok := strconv.parse_f32(strings.trim_prefix(argument, "--scale="))
			if !ok || parsed <= 0 {return false}
			scale = parsed
		case strings.has_prefix(argument, "--path="):
			directory = strings.trim_prefix(argument, "--path=")
		case:
			return false
		}
	}
	if len(directory) == 0 {directory = home_directory()}

	pool := NS.scoped_autoreleasepool()
	_ = pool
	device := MTL.CreateSystemDefaultDevice()
	if device == nil {return false}
	queue := device->newCommandQueue()
	if queue == nil {return false}

	text: coretext.Context
	coretext.context_init(&text)
	defer coretext.context_destroy(&text)
	list: draw.List
	draw.list_init(&list, pixel_ratio = scale)
	defer draw.list_destroy(&list)
	renderer: metal.Renderer
	if !metal.renderer_init(
		&renderer,
		rawptr(device),
		pixel_format = uint(MTL.PixelFormat.BGRA8Unorm),
		metallib_data = UI_METALLIB,
	) {
		return false
	}
	defer metal.renderer_destroy(&renderer)
	if !register_system_monospaced(&text) {return false}

	tree: Tree
	tree_init(&tree)
	defer tree_destroy(&tree)
	if !tree_open(&tree, directory) {return false}

	pixel_width := int(f32(width)*scale)
	pixel_height := int(f32(height)*scale)
	descriptor := metal.msg_id_u_u_u_bool(
		metal.objc_getClass("MTLTextureDescriptor"),
		metal.sel_registerName("texture2DDescriptorWithPixelFormat:width:height:mipmapped:"),
		80,
		uint(pixel_width),
		uint(pixel_height),
		false,
	)
	target := metal.msg_id_id(device, metal.sel_registerName("newTextureWithDescriptor:"), descriptor)
	if target == nil {return false}
	defer metal.release(target)

	metrics := View_Metrics{width = f32(width), height = f32(height)}
	for _ in 0 ..< 3 {
		metal.begin_texture_frame(&renderer)
		coretext.begin_frame(&text, scale, metal.atlas_io(&renderer))
		metrics.char_advance = measure_char_advance(&text)
		draw.list_reset(&list)
		view_layout(&tree, metrics)
		view_draw(&tree, &list, &text, metrics, Hot_State{column = -1, row = -1, control = -1})
		coretext.flush(&text)
		command_buffer := queue->commandBuffer()
		if !metal.encode_to_drawable(
			&renderer,
			rawptr(command_buffer),
			rawptr(target),
			&list,
			{f32(width), f32(height)},
			scale,
			COLOR_BACKGROUND,
		) {
			return false
		}
		metal.msg_void(rawptr(command_buffer), metal.sel_registerName("commit"))
		metal.msg_void(rawptr(command_buffer), metal.sel_registerName("waitUntilCompleted"))
		free_all(context.temp_allocator)
	}

	pixels := make([]u8, pixel_width*pixel_height*4, context.allocator)
	defer delete(pixels)
	region := metal.MTL_Region{size = metal.MTL_Size{uint(pixel_width), uint(pixel_height), 1}}
	metal.msg_void_get_bytes(
		target,
		metal.sel_registerName("getBytes:bytesPerRow:fromRegion:mipmapLevel:"),
		raw_data(pixels),
		uint(pixel_width*4),
		region,
		0,
	)
	if !write_ppm(path, pixels, pixel_width, pixel_height) {return false}
	fmt.printf("wrote %s (%dx%d, scale %.1f)\n", path, width, height, scale)
	return true
}
