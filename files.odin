package file_manager

import "core:os"
import "core:slice"
import "core:strings"

Entry_Kind :: enum {
	Directory,
	Source,
	Document,
	Image,
	Archive,
	Other,
}

Entry :: struct {
	name:   string,
	path:   string,
	kind:   Entry_Kind,
	is_dir: bool,
	hidden: bool,
}

SOURCE_EXTENSIONS :: []string{
	"odin", "c", "h", "cc", "cpp", "hpp", "m", "mm", "swift", "rs", "go",
	"ts", "tsx", "js", "jsx", "py", "rb", "lua", "zig", "java", "kt", "cs",
	"sql", "sh", "zsh", "bash", "metal",
}

DOCUMENT_EXTENSIONS :: []string{
	"md", "txt", "pdf", "rtf", "doc", "docx", "csv", "tsv", "xls", "xlsx",
	"ppt", "pptx", "ics", "tex", "html", "css", "json", "yaml", "yml", "toml",
	"plist", "log",
}

IMAGE_EXTENSIONS :: []string{
	"png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "svg",
	"ico", "psd",
}

ARCHIVE_EXTENSIONS :: []string{
	"zip", "tar", "gz", "bz2", "xz", "7z", "rar", "dmg", "iso",
}

entry_kind :: proc(name: string, is_dir: bool) -> Entry_Kind {
	if is_dir {return .Directory}
	dot := strings.last_index_byte(name, '.')
	if dot < 0 || dot == len(name)-1 {return .Other}
	extension := name[dot+1:]
	if len(extension) > 12 {return .Other}
	buffer: [12]u8
	lower := buffer[:len(extension)]
	for index in 0 ..< len(extension) {
		character := extension[index]
		switch {
		case 'a' <= character && character <= 'z':
			lower[index] = character
		case 'A' <= character && character <= 'Z':
			lower[index] = character + ('a' - 'A')
		case:
			lower[index] = character
		}
	}
	folded := string(lower)
	if slice.contains(SOURCE_EXTENSIONS, folded) {return .Source}
	if slice.contains(DOCUMENT_EXTENSIONS, folded) {return .Document}
	if slice.contains(IMAGE_EXTENSIONS, folded) {return .Image}
	if slice.contains(ARCHIVE_EXTENSIONS, folded) {return .Archive}
	return .Other
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
			kind = entry_kind(name, is_dir),
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
