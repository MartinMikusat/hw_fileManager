package file_manager

import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

Entry :: struct {
	name:     string,
	path:     string,
	modified: time.Time,
	is_dir:   bool,
	hidden:   bool,
}

read_entries :: proc(directory: string, allocator := context.allocator) -> ([]Entry, bool) {
	// ponytail: full synchronous read; a huge directory blocks the UI thread during
	// selection — make this async over display-link frames if that hurts.
	handle, open_error := os.open(directory)
	if open_error != nil {return nil, false}
	defer os.close(handle)
	infos, read_error := os.read_dir(handle, -1, allocator)
	if read_error != nil {return nil, false}
	defer os.file_info_slice_delete(infos, allocator)
	list := make([dynamic]Entry, 0, len(infos), allocator)
	for info in infos {
		name := info.name
		if len(name) == 0 || name == "." || name == ".." {continue}
		is_dir := info.type == .Directory
		append(&list, Entry{
			name = strings.clone(name, allocator),
			path = strings.clone(info.fullpath, allocator),
			modified = info.modification_time,
			is_dir = is_dir,
			hidden = name[0] == '.',
		})
	}
	entries := list[:]
	slice.sort_by(entries, entry_less)
	return entries, true
}

entries_destroy :: proc(entries: []Entry, allocator := context.allocator) {
	for entry in entries {
		delete(entry.name, allocator)
		delete(entry.path, allocator)
	}
	delete(entries, allocator)
}

entry_less :: proc(a, b: Entry) -> bool {
	if a.is_dir != b.is_dir {return a.is_dir}
	return name_less_fold(a.name, b.name)
}

name_less_fold :: proc(a, b: string) -> bool {
	shared := min(len(a), len(b))
	for index in 0 ..< shared {
		left := fold_ascii(a[index])
		right := fold_ascii(b[index])
		if left != right {return left < right}
	}
	return len(a) < len(b)
}

fold_ascii :: proc(value: u8) -> u8 {
	if 'A' <= value && value <= 'Z' {return value + ('a' - 'A')}
	return value
}
