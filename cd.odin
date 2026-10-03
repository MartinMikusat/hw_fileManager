package file_manager

import "core:mem"
import "core:os"
import "core:strings"
import devlog "devlog:."

TYPED_MAX :: 64

// zoxide is the operator's terminal cd. Query it so a typed abbreviation resolves
// to the same path the shell would take. A Finder launch may not inherit the
// Homebrew PATH, so prefer the installed binary and fall back to the PATH lookup.
cd_zoxide :: proc() -> string {
	if os.is_file("/opt/homebrew/bin/zoxide") {return "/opt/homebrew/bin/zoxide"}
	if os.is_file("/usr/local/bin/zoxide") {return "/usr/local/bin/zoxide"}
	return "zoxide"
}

cd_typed_append :: proc(host: ^Host, ch: u8) {
	if host.typed_len >= TYPED_MAX {return}
	host.typed[host.typed_len] = ch
	host.typed_len += 1
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

// cd_run resolves the invisibly typed query and reopens the cascade at the match.
cd_run :: proc(host: ^Host) {
	if host.typed_len == 0 {return}
	query := string(host.typed[:host.typed_len])
	host.typed_len = 0
	path, ok := cd_lookup(host.zoxide, query, context.allocator)
	if !ok {return}
	defer delete(path, context.allocator)
	_ = tree_open(&host.tree, path)
	host_request_frames(2)
}
