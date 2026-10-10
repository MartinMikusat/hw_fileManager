package file_manager

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import devlog "devlog:."

// zoxide is the operator's terminal cd. Query it so a typed abbreviation resolves
// to the same path the shell would take. A Finder launch may not inherit the
// Homebrew PATH, so prefer the installed binary and fall back to the PATH lookup.
cd_zoxide :: proc() -> string {
	if os.is_file("/opt/homebrew/bin/zoxide") {return "/opt/homebrew/bin/zoxide"}
	if os.is_file("/usr/local/bin/zoxide") {return "/usr/local/bin/zoxide"}
	return "zoxide"
}

// cd_lookup returns the highest-ranked zoxide match for the typed query.
cd_lookup :: proc(zoxide, query: string, allocator: mem.Allocator) -> (string, bool) {
	desc := os.Process_Desc{command = []string{zoxide, "query", query}}
	state, stdout, stderr, err := os.process_exec(desc, context.allocator)
	defer delete(stdout, context.allocator)
	defer delete(stderr, context.allocator)
	if err != nil {
		devlog.failed(devlog.global(), {feature = "files", operation = "quick_cd"}, {
			reason = "zoxide could not be run",
			severity = .Warning,
		})
		return "", false
	}
	if !state.success || state.exit_code != 0 {return "", false}
	path := strings.trim_space(string(stdout))
	if len(path) == 0 {return "", false}
	return strings.clone(path, allocator), true
}

// cd_matches lists the zoxide directories matching the typed keywords, best
// first, skipping paths that no longer exist. Paths live in the temp allocator.
cd_matches :: proc(zoxide, query: string) -> []string {
	arguments := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&arguments, zoxide, "query", "--list", "--")
	for word in strings.fields(query, context.temp_allocator) {append(&arguments, word)}
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = arguments[:]}, context.allocator)
	defer delete(stdout, context.allocator)
	defer delete(stderr, context.allocator)
	if err != nil || !state.success {return nil}
	paths := make([dynamic]string, 0, 8, context.temp_allocator)
	for line in strings.split_lines(string(stdout), context.temp_allocator) {
		path := strings.trim_space(line)
		if len(path) > 0 && os.is_dir(path) {append(&paths, strings.clone(path, context.temp_allocator))}
	}
	return paths[:]
}

// cd_remember bumps the directory's zoxide rank so jumps made here count like
// the shell's.
cd_remember :: proc(zoxide, path: string) {
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = []string{zoxide, "add", "--", path}}, context.allocator)
	defer delete(stdout, context.allocator)
	defer delete(stderr, context.allocator)
	if err != nil || !state.success {
		devlog.failed(devlog.global(), {feature = "files", operation = "quick_cd"}, {
			reason = "zoxide could not record the directory",
			severity = .Warning,
		}, {stage = "remember"})
	}
}

// cd_enter reopens the cascade at path and remembers it.
cd_enter :: proc(host: ^Window, path: string) -> bool {
	if !tree_open(&host.tree, path) {return false}
	cd_remember(app.zoxide, path)
	return true
}

// cd_run resolves the typed query and reopens the cascade at the match.
cd_run :: proc(host: ^Window) {
	input_history_push(host)
	query := input_text(host)
	if len(query) > 0 {
		if path, ok := cd_lookup(app.zoxide, query, context.allocator); ok {
			defer delete(path, context.allocator)
			_ = cd_enter(host, path)
		}
	}
	input_reset(host)
	host_request_frames(host, 2)
}

name_has_prefix_fold :: proc(name, prefix: string) -> bool {
	if len(prefix) > len(name) {return false}
	for index in 0 ..< len(prefix) {
		if fold_ascii(name[index]) != fold_ascii(prefix[index]) {return false}
	}
	return true
}

// cd_common_prefix is the longest prefix shared by every name, ignoring ASCII case.
cd_common_prefix :: proc(names: []string) -> int {
	if len(names) == 0 {return 0}
	length := len(names[0])
	for name in names[1:] {
		shared := 0
		for shared < min(length, len(name)) && fold_ascii(names[0][shared]) == fold_ascii(name[shared]) {shared += 1}
		length = shared
	}
	return length
}

// cd_complete is Tab in the cd field. Zoxide memory wins: the first Tab fills in
// the best match's folder name and the next one jumps there. Without a memory
// match it completes against the active column's folders: the shared prefix is
// filled in and the selection moves to the candidates, which stay highlighted;
// a lone candidate completes, then a further Tab jumps into it.
cd_complete :: proc(host: ^Window) {
	text := input_text(host)
	if len(text) == 0 {return}
	if matches := cd_matches(app.zoxide, text); len(matches) > 0 {
		name := filepath.base(matches[0])
		if text != name {
			host.cd_completing = false
			input_set(host, name)
			return
		}
		if cd_enter(host, matches[0]) {
			input_history_push(host)
			input_reset(host)
		}
		return
	}
	if host.tree.active < 0 || host.tree.active >= len(host.tree.columns) {return}
	column := &host.tree.columns[host.tree.active]
	rows := make([dynamic]int, 0, 8, context.temp_allocator)
	names := make([dynamic]string, 0, 8, context.temp_allocator)
	for entry, row in column.entries {
		if entry.is_dir && name_has_prefix_fold(entry.name, text) {
			append(&rows, row)
			append(&names, entry.name)
		}
	}
	if len(rows) == 0 {return}
	host.cd_completing = true
	if len(rows) == 1 {
		entry := column.entries[rows[0]]
		if text == entry.name {
			if cd_enter(host, entry.path) {
				input_history_push(host)
				input_reset(host)
			}
			return
		}
		input_set(host, entry.name)
		_ = tree_select(&host.tree, host.tree.active, rows[0], enter = false)
		return
	}
	shared := cd_common_prefix(names[:])
	if shared > len(text) {
		input_set(host, names[0][:shared])
		_ = tree_select(&host.tree, host.tree.active, rows[0], enter = false)
		return
	}
	next := rows[0]
	for row in rows {
		if row > column.selected {
			next = row
			break
		}
	}
	_ = tree_select(&host.tree, host.tree.active, next, enter = false)
}
