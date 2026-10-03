package file_manager

INPUT_MAX :: 64
HISTORY_MAX :: 32

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
	host.history_index = -1
	host.cd_completing = false
}

input_append :: proc(host: ^Host, ch: u8) {
	if host.input_len >= INPUT_MAX {return}
	host.input[host.input_len] = ch
	host.input_len += 1
	host.history_index = -1
	host.cd_completing = false
}

input_text :: proc(host: ^Host) -> string {
	return string(host.input[:host.input_len])
}

// input_history_push records a submitted query, newest first, dropping duplicates
// of the most recent entry.
input_history_push :: proc(host: ^Host) {
	if host.input_len == 0 {return}
	if host.history_count > 0 && string(host.history[0][:host.history_len[0]]) == input_text(host) {return}
	count := min(host.history_count+1, HISTORY_MAX)
	for index := count-1; index > 0; index -= 1 {
		host.history[index] = host.history[index-1]
		host.history_len[index] = host.history_len[index-1]
	}
	copy(host.history[0][:host.input_len], host.input[:host.input_len])
	host.history_len[0] = host.input_len
	host.history_count = count
	host.history_index = -1
}

// input_history_move walks the history like a shell prompt: +1 is older, -1 is
// newer, and stepping past the newest restores the line being edited.
input_history_move :: proc(host: ^Host, delta: int) {
	if host.history_count == 0 {return}
	if host.history_index < 0 {
		copy(host.draft[:host.input_len], host.input[:host.input_len])
		host.draft_len = host.input_len
	}
	host.cd_completing = false
	next := clamp(host.history_index+delta, -1, host.history_count-1)
	host.history_index = next
	if next < 0 {
		copy(host.input[:host.draft_len], host.draft[:host.draft_len])
		host.input_len = host.draft_len
		return
	}
	length := host.history_len[next]
	copy(host.input[:length], host.history[next][:length])
	host.input_len = length
}
