package file_manager

import "base:intrinsics"
import "base:runtime"
import "core:strings"
import "core:unicode/utf8"
import NS "core:sys/darwin/Foundation"
import text_input "components:text_input"

// The view conforms to NSTextInputClient so the editor receives composed text:
// dead keys, input methods and emoji. Ranges are UTF-16 offsets into the whole
// buffer, as the protocol requires. The callbacks do nothing unless this view's
// window is editing.

Text_Range :: struct {
	location: uint,
	length:   uint,
}

TEXT_RANGE_NONE :: Text_Range{~uint(0), 0}

textedit_register_methods :: proc(view_class: NS.Class) -> bool {
	if protocol := NS.objc_getProtocol("NSTextInputClient"); protocol != nil {
		_ = NS.class_addProtocol(view_class, protocol)
	}
	return host_add_method(view_class, "insertText:", rawptr(textedit_ime_insert_simple), "v@:@") &&
		host_add_method(view_class, "insertText:replacementRange:", rawptr(textedit_ime_insert), "v@:@{_NSRange=QQ}") &&
		host_add_method(view_class, "doCommandBySelector:", rawptr(textedit_ime_command), "v@::") &&
		host_add_method(view_class, "setMarkedText:selectedRange:replacementRange:", rawptr(textedit_ime_set_marked), "v@:@{_NSRange=QQ}{_NSRange=QQ}") &&
		host_add_method(view_class, "unmarkText", rawptr(textedit_ime_unmark), "v@:") &&
		host_add_method(view_class, "hasMarkedText", rawptr(textedit_ime_has_marked), "B@:") &&
		host_add_method(view_class, "markedRange", rawptr(textedit_ime_marked_range), "{_NSRange=QQ}@:") &&
		host_add_method(view_class, "selectedRange", rawptr(textedit_ime_selected_range), "{_NSRange=QQ}@:") &&
		host_add_method(view_class, "validAttributesForMarkedText", rawptr(textedit_ime_valid_attributes), "@@:") &&
		host_add_method(view_class, "attributedSubstringForProposedRange:actualRange:", rawptr(textedit_ime_substring), "@@:{_NSRange=QQ}^{_NSRange=QQ}") &&
		host_add_method(view_class, "characterIndexForPoint:", rawptr(textedit_ime_index), "Q@:{CGPoint=dd}") &&
		host_add_method(view_class, "firstRectForCharacterRange:actualRange:", rawptr(textedit_ime_rect), "{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}")
}

textedit_editing_window :: proc(view: NS.id) -> ^Window {
	window := window_for_view(view)
	if window != nil && window.text_edit.active {return window}
	return nil
}

// textedit_ns_string reads an NSString or NSAttributedString argument.
textedit_ns_string :: proc(value: NS.id) -> (string, bool) {
	if value == nil {return "", false}
	object := cast(^NS.Object)value
	if !intrinsics.objc_send(NS.BOOL, object, "isKindOfClass:", intrinsics.objc_find_class("NSString")) {
		object = intrinsics.objc_send(^NS.Object, object, "string")
		if object == nil {return "", false}
	}
	return NS.String_odinString(cast(^NS.String)object), true
}

// textedit_typed drops the control characters and function-key codes that a
// keystroke can carry; a newline and a tab stay.
textedit_typed :: proc(value: string) -> string {
	builder := make([dynamic]u8, 0, len(value), context.temp_allocator)
	for typed in value {
		rune := typed == '\r' ? '\n' : typed
		if rune < 32 && rune != '\n' && rune != '\t' || rune == 127 || rune >= 0xF700 && rune <= 0xF8FF {continue}
		encoded, size := utf8.encode_rune(rune)
		append(&builder, ..encoded[:size])
	}
	return string(builder[:])
}

textedit_ime_changed :: proc(window: ^Window) {
	textedit_reveal(window)
	host_request_frames(window, 2)
}

textedit_ime_insert_simple :: proc "c" (self: NS.id, cmd: NS.SEL, value: NS.id) {
	textedit_ime_insert(self, cmd, value, {})
}

textedit_ime_insert :: proc "c" (self: NS.id, cmd: NS.SEL, value: NS.id, replacement: Text_Range) {
	context = runtime.default_context()
	window := textedit_editing_window(self)
	if window == nil {return}
	text, ok := textedit_ns_string(value)
	if !ok {return}
	text = textedit_typed(text)
	if len(text) == 0 && !window.text_edit.state.has_marked_text {return}
	textedit_commit_marked(&window.text_edit, text)
	textedit_ime_changed(window)
}

textedit_ime_command :: proc "c" (self: NS.id, cmd: NS.SEL, selector: NS.SEL) {
	context = runtime.default_context()
	window := textedit_editing_window(self)
	if window == nil {return}
	edit := &window.text_edit
	switch selector {
	case NS.sel_registerName("insertNewline:"), NS.sel_registerName("insertLineBreak:"):
		textedit_newline(edit)
	case NS.sel_registerName("insertTab:"):
		textedit_insert(edit, "\t")
	case NS.sel_registerName("deleteBackward:"):
		textedit_delete_backward(edit, false)
	case NS.sel_registerName("deleteForward:"):
		textedit_delete_forward(edit)
	case NS.sel_registerName("cancelOperation:"):
		textedit_marked_remove(edit)
	case:
		return
	}
	textedit_ime_changed(window)
}

textedit_ime_set_marked :: proc "c" (self: NS.id, cmd: NS.SEL, value: NS.id, selected, replacement: Text_Range) {
	context = runtime.default_context()
	window := textedit_editing_window(self)
	if window == nil {return}
	text, ok := textedit_ns_string(value)
	if !ok {return}
	location := selected.location == ~uint(0) ? -1 : int(selected.location)
	if len(text) == 0 {
		textedit_marked_remove(&window.text_edit)
	} else {
		textedit_set_marked(&window.text_edit, text, location, int(selected.length))
	}
	textedit_ime_changed(window)
}

textedit_ime_unmark :: proc "c" (self: NS.id, cmd: NS.SEL) {
	context = runtime.default_context()
	window := textedit_editing_window(self)
	if window == nil || !window.text_edit.state.has_marked_text {return}
	textedit_commit_marked(&window.text_edit, strings.clone(window.text_edit.state.marked_text, context.temp_allocator))
	textedit_ime_changed(window)
}

textedit_ime_has_marked :: proc "c" (self: NS.id, cmd: NS.SEL) -> bool {
	context = runtime.default_context()
	window := textedit_editing_window(self)
	return window != nil && window.text_edit.state.has_marked_text
}

textedit_text_range :: proc(range: text_input.UTF16_Range) -> Text_Range {
	if !range.valid {return TEXT_RANGE_NONE}
	return {uint(range.location), uint(range.length)}
}

textedit_ime_marked_range :: proc "c" (self: NS.id, cmd: NS.SEL) -> Text_Range {
	context = runtime.default_context()
	window := textedit_editing_window(self)
	if window == nil {return TEXT_RANGE_NONE}
	return textedit_text_range(text_input.marked_utf16_range(&window.text_edit.state, textedit_text(&window.text_edit)))
}

textedit_ime_selected_range :: proc "c" (self: NS.id, cmd: NS.SEL) -> Text_Range {
	context = runtime.default_context()
	window := textedit_editing_window(self)
	if window == nil {return TEXT_RANGE_NONE}
	return textedit_text_range(text_input.selected_utf16_range(&window.text_edit.state, textedit_text(&window.text_edit)))
}

textedit_ime_valid_attributes :: proc "c" (self: NS.id, cmd: NS.SEL) -> NS.id {
	context = runtime.default_context()
	return intrinsics.objc_send(NS.id, cast(^NS.Object)intrinsics.objc_find_class("NSArray"), "array")
}

textedit_ime_substring :: proc "c" (self: NS.id, cmd: NS.SEL, range: Text_Range, actual: ^Text_Range) -> NS.id {
	return nil
}

textedit_ime_index :: proc "c" (self: NS.id, cmd: NS.SEL, point: NS.Point) -> uint {
	return ~uint(0)
}

// textedit_ime_rect is where the caret is on screen, so the candidate window
// opens beside it.
textedit_ime_rect :: proc "c" (self: NS.id, cmd: NS.SEL, range: Text_Range, actual: ^Text_Range) -> NS.Rect {
	context = runtime.default_context()
	window := textedit_editing_window(self)
	if window == nil {return {}}
	edit := &window.text_edit
	text := textedit_text(edit)
	caret := textedit_caret(edit)
	line := textedit_line_of(edit, caret)
	area := view_preview_area(window.preview_rect)
	x := area.x+f32(textedit_column(text, edit.starts[line], caret)-edit.hscroll)*window.char_advance
	y := area.y+(f32(line)-window.preview.scroll)*window.tree.row_height
	local := NS.Rect{{NS.Float(x), NS.Float(window.view_height-(y+window.tree.row_height))}, {1, NS.Float(window.tree.row_height)}}
	in_window := intrinsics.objc_send(NS.Rect, window.view, "convertRect:toView:", local, (^NS.View)(nil))
	return intrinsics.objc_send(NS.Rect, window.ns_window, "convertRectToScreen:", in_window)
}
