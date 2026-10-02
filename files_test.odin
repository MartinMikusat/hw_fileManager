package file_manager

import "core:testing"

@(test)
entry_kind_classifies_by_extension :: proc(t: ^testing.T) {
	testing.expect_value(t, entry_kind("Sources", true), Entry_Kind.Directory)
	testing.expect_value(t, entry_kind("App.odin", false), Entry_Kind.Source)
	testing.expect_value(t, entry_kind("Photo.PNG", false), Entry_Kind.Image)
	testing.expect_value(t, entry_kind("README.md", false), Entry_Kind.Document)
	testing.expect_value(t, entry_kind("bundle.zip", false), Entry_Kind.Archive)
	testing.expect_value(t, entry_kind("Makefile", false), Entry_Kind.Other)
	testing.expect_value(t, entry_kind("trailing.", false), Entry_Kind.Other)
}

@(test)
name_fold_orders_case_insensitively :: proc(t: ^testing.T) {
	testing.expect(t, name_less_fold("alpha", "Beta"))
	testing.expect(t, name_less_fold("Beta", "gamma"))
	testing.expect(t, !name_less_fold("Beta", "alpha"))
	testing.expect(t, !name_less_fold("same", "SAME"))
}
