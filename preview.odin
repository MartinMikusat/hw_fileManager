package file_manager

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
import NS "core:sys/darwin/Foundation"
import MTL "vendor:darwin/Metal"
import devlog "devlog:."

foreign import coregraphics "system:CoreGraphics.framework"
foreign import corefoundation "system:CoreFoundation.framework"
foreign import imageio "system:ImageIO.framework"

CG_Rect :: struct {
	x, y, w, h: f64,
}

@(default_calling_convention = "c")
foreign corefoundation {
	CFURLCreateFromFileSystemRepresentation :: proc(allocator: rawptr, buffer: [^]u8, length: int, is_directory: b8) -> rawptr ---
	CFRelease :: proc(object: rawptr) ---
	CFNumberCreate :: proc(allocator: rawptr, type: int, value: rawptr) -> rawptr ---
	CFDictionaryCreate :: proc(allocator: rawptr, keys: [^]rawptr, values: [^]rawptr, count: int, key_callbacks: rawptr, value_callbacks: rawptr) -> rawptr ---
	kCFTypeDictionaryKeyCallBacks: [8]u64
	kCFTypeDictionaryValueCallBacks: [8]u64
	kCFBooleanTrue: rawptr
}

@(default_calling_convention = "c")
foreign imageio {
	CGImageSourceCreateWithURL :: proc(url: rawptr, options: rawptr) -> rawptr ---
	CGImageSourceCreateThumbnailAtIndex :: proc(source: rawptr, index: uint, options: rawptr) -> rawptr ---
	kCGImageSourceCreateThumbnailFromImageAlways: rawptr
	kCGImageSourceCreateThumbnailWithTransform: rawptr
	kCGImageSourceThumbnailMaxPixelSize: rawptr
}

@(default_calling_convention = "c")
foreign coregraphics {
	CGColorSpaceCreateDeviceRGB :: proc() -> rawptr ---
	CGColorSpaceRelease :: proc(space: rawptr) ---
	CGBitmapContextCreate :: proc(data: rawptr, width, height, bits_per_component, bytes_per_row: uint, space: rawptr, bitmap_info: u32) -> rawptr ---
	CGContextRelease :: proc(context_ref: rawptr) ---
	CGContextSetRGBFillColor :: proc(context_ref: rawptr, red, green, blue, alpha: f64) ---
	CGContextFillRect :: proc(context_ref: rawptr, rect: CG_Rect) ---
	CGContextDrawImage :: proc(context_ref: rawptr, rect: CG_Rect, image: rawptr) ---
	CGImageGetWidth :: proc(image: rawptr) -> uint ---
	CGImageGetHeight :: proc(image: rawptr) -> uint ---
	CGImageRelease :: proc(image: rawptr) ---
}

CF_NUMBER_SINT32_TYPE :: 3
CG_ALPHA_PREMULTIPLIED_LAST :: u32(1)

PREVIEW_TEXT_BYTES :: 64*1024
PREVIEW_TEXT_LINES :: 400
PREVIEW_TAB_SPACES :: "    "
PREVIEW_IMAGE_FILE_MAX :: 256*1024*1024
// Longest side of the decoded thumbnail, in pixels.
PREVIEW_IMAGE_PIXELS :: 2048
PREVIEW_IMAGE_EXTENSIONS :: []string{".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tif", ".tiff", ".heic", ".heif", ".webp", ".icns", ".ico", ".jp2"}

Preview_Kind :: enum {
	None,
	Text,
	Image,
	// A cloud file that is not on disk; reading it would download it.
	Cloud,
}

// SF_DATALESS marks a File Provider (iCloud) file whose content is not downloaded.
SF_DATALESS :: u32(0x40000000)

// Preview holds the loaded content of the selected file. It is keyed by path and
// modification time so a changed file reloads.
Preview :: struct {
	path:     string,
	modified: time.Time,
	kind:     Preview_Kind,
	text:     string,
	lines:    [dynamic]string,
	// Syntax class of each byte of text; all Plain without a known language.
	kinds:    []Syntax_Kind,
	texture:  ^MTL.Texture,
	width:    int,
	height:   int,
}

preview_clear :: proc(preview: ^Preview) {
	delete(preview.path)
	delete(preview.text)
	delete(preview.lines)
	delete(preview.kinds)
	if preview.texture != nil {preview.texture->release()}
	preview^ = {}
}

// path_dataless reports a cloud file without content on disk; it reads only metadata.
path_dataless :: proc(path: string) -> bool {
	status: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &status) != .OK {return false}
	return status.st_flags & SF_DATALESS != 0
}

preview_is_image_name :: proc(name: string) -> bool {
	extension := strings.to_lower(filepath.ext(name), context.temp_allocator)
	for candidate in PREVIEW_IMAGE_EXTENSIONS {
		if extension == candidate {return true}
	}
	return false
}

// preview_read_text returns the start of a file as display text, with tabs
// expanded and carriage returns dropped, or false for binary, empty or
// unreadable files.
preview_read_text :: proc(path: string, allocator := context.allocator) -> (string, bool) {
	file, open_error := os.open(path)
	if open_error != nil {return "", false}
	defer os.close(file)
	buffer := make([]u8, PREVIEW_TEXT_BYTES, context.temp_allocator)
	count, read_error := os.read(file, buffer)
	if count <= 0 || (read_error != nil && read_error != .EOF) {return "", false}
	data := buffer[:count]
	for value in data {
		if value == 0 {return "", false}
	}
	// A read that stops inside a multi-byte character is still text.
	for trim := 0; trim <= 3 && trim < len(data); trim += 1 {
		if utf8.valid_string(string(data[:len(data)-trim])) {
			data = data[:len(data)-trim]
			break
		}
		if trim == 3 {return "", false}
	}
	builder := strings.builder_make(0, len(data), allocator)
	for value in data {
		switch value {
		case '\r':
		case '\t': strings.write_string(&builder, PREVIEW_TAB_SPACES)
		case:      strings.write_byte(&builder, value)
		}
	}
	return strings.to_string(builder), true
}

// preview_decode_image decodes the image as an opaque RGBA thumbnail (at most
// max_pixels on its longest side) composited over the background colour.
preview_decode_image :: proc(path: string, max_pixels: int, background: [3]f64, allocator := context.allocator) -> (pixels: []u8, width, height: int, ok: bool) {
	path_bytes := transmute([]u8)path
	url := CFURLCreateFromFileSystemRepresentation(nil, raw_data(path_bytes), len(path_bytes), false)
	if url == nil {return}
	defer CFRelease(url)
	source := CGImageSourceCreateWithURL(url, nil)
	if source == nil {return}
	defer CFRelease(source)

	size := i32(max_pixels)
	number := CFNumberCreate(nil, CF_NUMBER_SINT32_TYPE, &size)
	defer CFRelease(number)
	keys := [3]rawptr{kCGImageSourceCreateThumbnailFromImageAlways, kCGImageSourceCreateThumbnailWithTransform, kCGImageSourceThumbnailMaxPixelSize}
	values := [3]rawptr{kCFBooleanTrue, kCFBooleanTrue, number}
	options := CFDictionaryCreate(nil, raw_data(keys[:]), raw_data(values[:]), 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)
	if options == nil {return}
	defer CFRelease(options)
	image := CGImageSourceCreateThumbnailAtIndex(source, 0, options)
	if image == nil {return}
	defer CGImageRelease(image)

	width, height = int(CGImageGetWidth(image)), int(CGImageGetHeight(image))
	if width <= 0 || height <= 0 {return}
	pixels = make([]u8, width*height*4, allocator)
	space := CGColorSpaceCreateDeviceRGB()
	defer CGColorSpaceRelease(space)
	bitmap := CGBitmapContextCreate(raw_data(pixels), uint(width), uint(height), 8, uint(width*4), space, CG_ALPHA_PREMULTIPLIED_LAST)
	if bitmap == nil {
		delete(pixels, allocator)
		return nil, 0, 0, false
	}
	defer CGContextRelease(bitmap)
	rect := CG_Rect{0, 0, f64(width), f64(height)}
	CGContextSetRGBFillColor(bitmap, background[0], background[1], background[2], 1)
	CGContextFillRect(bitmap, rect)
	CGContextDrawImage(bitmap, rect, image)
	return pixels, width, height, true
}

preview_make_texture :: proc(device: ^MTL.Device, pixels: []u8, width, height: int) -> ^MTL.Texture {
	descriptor := MTL.TextureDescriptor.texture2DDescriptorWithPixelFormat(.RGBA8Unorm, NS.UInteger(width), NS.UInteger(height), false)
	if descriptor == nil {return nil}
	texture := device->newTextureWithDescriptor(descriptor)
	if texture == nil {return nil}
	region := MTL.Region{origin = {0, 0, 0}, size = {NS.Integer(width), NS.Integer(height), 1}}
	texture->replaceRegion(region, 0, raw_data(pixels), NS.UInteger(width*4))
	return texture
}

// preview_update follows the selection: a selected image or text file is loaded as soon as
// it is selected and kept until the selection or the file changes. Cloud files are never
// read, so moving through them costs only a metadata check.
preview_update :: proc(preview: ^Preview, tree: ^Tree, device: ^MTL.Device) {
	entry, selected := tree_selected_entry(tree)
	if !selected || entry.is_dir {
		if len(preview.path) > 0 {preview_clear(preview)}
		return
	}
	if preview.path == entry.path && preview.modified == entry.modified {return}
	preview_clear(preview)
	started := time.tick_now()
	defer devlog.sample_since(devlog.global(), {feature = "files", operation = "preview"}, started)
	preview.path = strings.clone(entry.path)
	preview.modified = entry.modified
	if path_dataless(entry.path) {
		preview.kind = .Cloud
		return
	}
	site := devlog.Site{feature = "files", operation = "preview"}
	if preview_is_image_name(entry.name) {
		info, stat_error := os.stat(entry.path, context.temp_allocator)
		if stat_error != nil || info.size > PREVIEW_IMAGE_FILE_MAX {return}
		background := [3]f64{f64(COLOR_BACKGROUND[0]), f64(COLOR_BACKGROUND[1]), f64(COLOR_BACKGROUND[2])}
		pixels, width, height, decoded := preview_decode_image(entry.path, PREVIEW_IMAGE_PIXELS, background, context.temp_allocator)
		if !decoded {
			devlog.failed(devlog.global(), site, {reason = "image could not be decoded", severity = .Warning}, {file_id = entry.name})
			return
		}
		texture := preview_make_texture(device, pixels, width, height)
		if texture == nil {
			devlog.failed(devlog.global(), site, {reason = "preview texture could not be created", severity = .Warning}, {file_id = entry.name})
			return
		}
		preview.texture = texture
		preview.width, preview.height = width, height
		preview.kind = .Image
		return
	}
	text, is_text := preview_read_text(entry.path)
	if !is_text {return}
	preview.text = text
	preview.kinds = highlight_kinds(highlight_language(entry.name), text)
	preview.lines = make([dynamic]string, 0, 64)
	rest := text
	for len(rest) > 0 && len(preview.lines) < PREVIEW_TEXT_LINES {
		line, found := strings.split_iterator(&rest, "\n")
		if !found {break}
		append(&preview.lines, line)
	}
	preview.kind = .Text
}
