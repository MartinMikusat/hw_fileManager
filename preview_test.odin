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

@(test)
highlight_classifies_odin_json_and_markup :: proc(t: ^testing.T) {
	source := "proc(x: int) -> string { return \"a\" } // done"
	kinds := highlight_kinds(.Odin, source, context.temp_allocator)
	testing.expect_value(t, kinds[0], Syntax_Kind.Keyword)
	testing.expect_value(t, kinds[8], Syntax_Kind.Type)
	testing.expect_value(t, kinds[len(source)-1], Syntax_Kind.Comment)

	json := `{"k": [1, true], "s": "v"}`
	kinds = highlight_kinds(.Json, json, context.temp_allocator)
	testing.expect_value(t, kinds[1], Syntax_Kind.Property)
	testing.expect_value(t, kinds[7], Syntax_Kind.Number)
	testing.expect_value(t, kinds[11], Syntax_Kind.Keyword)
	testing.expect_value(t, kinds[22], Syntax_Kind.String)

	markup := `<a href="x"><!-- c --></a>`
	kinds = highlight_kinds(.Markup, markup, context.temp_allocator)
	testing.expect_value(t, kinds[1], Syntax_Kind.Tag)
	testing.expect_value(t, kinds[3], Syntax_Kind.Property)
	testing.expect_value(t, kinds[9], Syntax_Kind.String)
	testing.expect_value(t, kinds[15], Syntax_Kind.Comment)
}
