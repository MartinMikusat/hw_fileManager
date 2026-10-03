package file_manager

import "core:os"
import "core:testing"

PREVIEW_TEST_PATH :: "/tmp/hw_fileManager-preview-test.txt"

@(test)
preview_text_expands_tabs_and_rejects_binary :: proc(t: ^testing.T) {
	defer os.remove(PREVIEW_TEST_PATH)
	testing.expect(t, os.write_entire_file(PREVIEW_TEST_PATH, "a\tb\r\nc\n") == nil)
	text, ok := preview_read_text(PREVIEW_TEST_PATH, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, text, "a    b\nc\n")

	testing.expect(t, os.write_entire_file(PREVIEW_TEST_PATH, []u8{'a', 0, 'b'}) == nil)
	_, ok = preview_read_text(PREVIEW_TEST_PATH, context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
preview_decodes_an_image_within_the_pixel_cap :: proc(t: ^testing.T) {
	pixels, width, height, ok := preview_decode_image(#directory + "references/01-tree-connectors.jpg", 256, {0, 0, 0}, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, width > 0 && height > 0 && max(width, height) <= 256)
	testing.expect_value(t, len(pixels), width*height*4)
	testing.expect_value(t, pixels[3], u8(255))
}
