package file_manager

import "core:os"
import "core:testing"
import "core:time"

TEXTEDIT_TEST_PATH :: "/tmp/hw_fileManager-textedit-test.txt"

textedit_test_open :: proc(t: ^testing.T, content: string) -> (edit: Text_Edit, ok: bool) {
	testing.expect(t, os.write_entire_file(TEXTEDIT_TEST_PATH, content) == nil)
	reason := textedit_open(&edit, TEXTEDIT_TEST_PATH)
	testing.expect_value(t, reason, "")
	return edit, reason == ""
}

textedit_test_file :: proc() -> string {
	data, _ := os.read_entire_file(TEXTEDIT_TEST_PATH, context.temp_allocator)
	return string(data)
}

@(test)
textedit_save_restores_bom_crlf_and_missing_newline :: proc(t: ^testing.T) {
	defer os.remove(TEXTEDIT_TEST_PATH)
	original := "\xEF\xBB\xBFone\r\ntwo"
	edit, ok := textedit_test_open(t, original)
	if !ok {return}
	defer textedit_free(&edit)
	testing.expect_value(t, string(edit.buffer[:]), "one\ntwo")
	testing.expect_value(t, textedit_save(&edit, false), Text_Edit_Save.Saved)
	testing.expect_value(t, textedit_test_file(), original)
	textedit_collapse(&edit, 3)
	textedit_insert(&edit, "!")
	testing.expect_value(t, textedit_save(&edit, false), Text_Edit_Save.Saved)
	testing.expect_value(t, textedit_test_file(), "\xEF\xBB\xBFone!\r\ntwo")
}

@(test)
textedit_refuses_files_it_could_not_write_back_faithfully :: proc(t: ^testing.T) {
	defer os.remove(TEXTEDIT_TEST_PATH)
	for content in ([]string{"a\r\nb\n", "a\rb", "a\x00b", "\xff\xfe"}) {
		testing.expect(t, os.write_entire_file(TEXTEDIT_TEST_PATH, content) == nil)
		edit: Text_Edit
		testing.expect(t, len(textedit_open(&edit, TEXTEDIT_TEST_PATH)) > 0)
		testing.expect(t, !edit.active)
		textedit_free(&edit)
	}
	big := make([]u8, TEXTEDIT_MAX_BYTES+1, context.temp_allocator)
	for index in 0 ..< len(big) {big[index] = 'a'}
	testing.expect(t, os.write_entire_file(TEXTEDIT_TEST_PATH, big) == nil)
	edit: Text_Edit
	testing.expect_value(t, textedit_open(&edit, TEXTEDIT_TEST_PATH), "file is larger than 8 MB")
	textedit_free(&edit)
}

@(test)
textedit_undo_groups_typing_and_redo_restores :: proc(t: ^testing.T) {
	defer os.remove(TEXTEDIT_TEST_PATH)
	edit, ok := textedit_test_open(t, "x\n")
	if !ok {return}
	defer textedit_free(&edit)
	for text in ([]string{"a", "b", " ", "c"}) {textedit_insert(&edit, text)}
	testing.expect_value(t, string(edit.buffer[:]), "ab cx\n")
	testing.expect(t, textedit_undo(&edit, false))
	testing.expect_value(t, string(edit.buffer[:]), "ab x\n")
	testing.expect(t, textedit_undo(&edit, false))
	testing.expect(t, textedit_undo(&edit, false))
	testing.expect_value(t, string(edit.buffer[:]), "x\n")
	testing.expect(t, !textedit_undo(&edit, false))
	testing.expect(t, textedit_undo(&edit, true))
	testing.expect_value(t, string(edit.buffer[:]), "abx\n")
	textedit_delete_backward(&edit, false)
	testing.expect_value(t, string(edit.buffer[:]), "ax\n")
	testing.expect(t, !textedit_undo(&edit, true))
}

@(test)
textedit_save_reports_a_file_changed_on_disk :: proc(t: ^testing.T) {
	defer os.remove(TEXTEDIT_TEST_PATH)
	edit, ok := textedit_test_open(t, "a\n")
	if !ok {return}
	defer textedit_free(&edit)
	textedit_insert(&edit, "b")
	edit.modified = time.time_add(edit.modified, -time.Second)
	testing.expect_value(t, textedit_save(&edit, false), Text_Edit_Save.Conflict)
	testing.expect_value(t, textedit_test_file(), "a\n")
	testing.expect_value(t, textedit_save(&edit, true), Text_Edit_Save.Saved)
	testing.expect_value(t, textedit_test_file(), "ba\n")
}
