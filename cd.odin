package file_manager

import "core:mem"
import "core:os"
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

// cd_run resolves the typed query and reopens the cascade at the match.
cd_run :: proc(host: ^Host) {
	query := input_text(host)
	if len(query) > 0 {
		if path, ok := cd_lookup(host.zoxide, query, context.allocator); ok {
			defer delete(path, context.allocator)
			_ = tree_open(&host.tree, path)
		}
	}
	input_reset(host)
	host_request_frames(2)
}
