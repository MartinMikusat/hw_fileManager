package file_manager

INPUT_MAX :: 64

Input_Mode :: enum {
	None,
	Cd,
	Search,
}

input_reset :: proc(host: ^Host) {
	host.input_len = 0
	host.input_mode = .None
	host.search_index = 0
	host.search_committed = false
}

input_append :: proc(host: ^Host, ch: u8) {
	if host.input_len >= INPUT_MAX {return}
	host.input[host.input_len] = ch
	host.input_len += 1
}

input_text :: proc(host: ^Host) -> string {
	return string(host.input[:host.input_len])
}
