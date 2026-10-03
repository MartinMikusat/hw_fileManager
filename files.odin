package file_manager

import "base:intrinsics"
import "core:os"
import "core:slice"
import NS "core:sys/darwin/Foundation"
import "core:sys/posix"
import "core:strings"
import "core:time"

foreign import libsystem "system:System"

@(default_calling_convention = "c")
foreign libsystem {
	copyfile :: proc(from, to: cstring, state: rawptr, flags: u32) -> i32 ---
}

// ALL (data, metadata, xattrs, ACLs), RECURSIVE, EXCL, NOFOLLOW_SRC, CLONE.
COPYFILE_FLAGS :: u32(0xF | 1<<15 | 1<<17 | 1<<18 | 1<<24)
EXDEV :: i32(18)

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
		is_dir := info.type == .Directory || (info.type == .Symlink && os.is_dir(info.fullpath))
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

// copy_item copies a file or folder tree with copyfile(3): APFS clones, keeps
// metadata and symlinks, and refuses to overwrite. It returns 0 or an errno.
copy_item :: proc(source, destination: string) -> i32 {
	from := strings.clone_to_cstring(source, context.temp_allocator)
	to := strings.clone_to_cstring(destination, context.temp_allocator)
	if copyfile(from, to, nil, COPYFILE_FLAGS) == 0 {return 0}
	return i32(posix.errno())
}

path_list_contains :: proc(paths: []string, path: string) -> bool {
	for entry in paths {
		if entry == path {return true}
	}
	return false
}

// trash_item moves a file or folder to the Trash through NSFileManager, so a
// bulk mistake is recoverable. It returns false when the move fails.
trash_item :: proc(path: string) -> bool {
	pool := NS.scoped_autoreleasepool()
	_ = pool
	manager := intrinsics.objc_send(^NS.Object, cast(^NS.Object)intrinsics.objc_find_class("NSFileManager"), "defaultManager")
	if manager == nil {return false}
	url := intrinsics.objc_send(^NS.Object, cast(^NS.Object)intrinsics.objc_find_class("NSURL"), "fileURLWithPath:", edit_nsstring(path))
	if url == nil {return false}
	return bool(intrinsics.objc_send(NS.BOOL, manager, "trashItemAtURL:resultingItemURL:error:", url, NS.id(nil), NS.id(nil)))
}

// delete_item removes a file or folder tree for good; there is no undo. Odin's
// remove_all only walks directories, so a plain file goes through remove.
delete_item :: proc(path: string) -> bool {
	if os.remove(path) == nil {return true}
	return os.remove_all(path) == nil
}

// path_taken reports whether anything occupies the path, a dangling symlink
// included.
path_taken :: proc(path: string) -> bool {
	info, error := os.lstat(path, context.temp_allocator)
	if error != nil {return false}
	os.file_info_delete(info, context.temp_allocator)
	return true
}

// path_same_file reports whether two paths name one file, as a case-only rename
// does on a case-insensitive volume.
path_same_file :: proc(a, b: string) -> bool {
	left, left_error := os.lstat(a, context.temp_allocator)
	if left_error != nil {return false}
	defer os.file_info_delete(left, context.temp_allocator)
	right, right_error := os.lstat(b, context.temp_allocator)
	if right_error != nil {return false}
	defer os.file_info_delete(right, context.temp_allocator)
	return left.inode != 0 && left.inode == right.inode && left.device == right.device
}
