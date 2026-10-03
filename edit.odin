package file_manager

import "core:os"
import "core:path/filepath"
import devlog "devlog:."

Edit_Mode :: enum {
	None,
	Rename,
	NewFile,
}

View_Edit :: struct {
	active: bool,
	column: int,
	row:    int,
	text:   string,
}

edit_text :: proc(host: ^Host) -> string {
	return string(host.edit_text[:host.edit_len])
}

// edit_begin seeds the inline editor: the selected name for Rename, an empty name
// on the active column's first row for NewFile.
edit_begin :: proc(host: ^Host, mode: Edit_Mode) {
	if mode == .Rename {
		entry, ok := tree_selected_entry(&host.tree)
		if !ok {return}
		host.edit_column = host.tree.active
		host.edit_row = host.tree.columns[host.tree.active].selected
		host.edit_len = min(len(entry.name), INPUT_MAX)
		copy(host.edit_text[:host.edit_len], entry.name[:host.edit_len])
		host.edit_mode = .Rename
		return
	}
	if host.tree.active < 0 || host.tree.active >= len(host.tree.columns) {return}
	host.edit_column = host.tree.active
	host.edit_row = 0
	host.edit_len = 0
	host.edit_mode = .NewFile
}

edit_append :: proc(host: ^Host, ch: u8) {
	if host.edit_len >= INPUT_MAX {return}
	if ch == '/' {return}
	host.edit_text[host.edit_len] = ch
	host.edit_len += 1
}

edit_backspace :: proc(host: ^Host) {
	if host.edit_len > 0 {host.edit_len -= 1}
}

edit_cancel :: proc(host: ^Host) {
	host.edit_mode = .None
	host.edit_len = 0
}

edit_commit :: proc(host: ^Host) {
	name := edit_text(host)
	column := host.edit_column
	mode := host.edit_mode
	edit_cancel(host)
	if len(name) == 0 || column < 0 || column >= len(host.tree.columns) {return}
	directory := host.tree.columns[column].dir
	destination, _ := filepath.join([]string{directory, name}, context.temp_allocator)
	applied := false
	switch mode {
	case .Rename:
		if entry, ok := tree_selected_entry(&host.tree); ok && entry.path != destination {
			applied = os.rename(entry.path, destination) == nil
		} else {
			applied = true
		}
	case .NewFile:
		if !os.exists(destination) {
			if file, create_error := os.create(destination); create_error == nil {
				os.close(file)
				applied = true
			}
		}
	case .None:
	}
	if !applied {
		devlog.failed(devlog.global(), {feature = "files", operation = "edit_name"}, {
			reason = "name could not be applied",
			severity = .Warning,
		})
		return
	}
	_ = tree_refresh(&host.tree)
	_ = tree_select_name(&host.tree, column, name)
}
