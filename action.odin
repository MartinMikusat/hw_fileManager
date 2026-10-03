package file_manager

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import devlog "devlog:."
import ui "ui_framework:core"
import draw "ui_framework:draw"

Action_Kind :: enum {
	Copy,
	Cut,
	Paste,
	Rename,
	NewFile,
	Gather,
	Trash,
	Clear,
	Terminal,
	Refresh,
	Open,
}

// ACTION_BAR_ORDER is the bottom row left to right; Trash only appears once
// something is gathered. Clear lives in the gather panel, not the bar.
ACTION_BAR_ORDER := [9]Action_Kind{.Copy, .Cut, .Paste, .Rename, .NewFile, .Gather, .Trash, .Terminal, .Open}
GATHER_CLEAR_LABEL :: "[8 Clear]"

action_label :: proc(kind: Action_Kind, ungather := false, shift := false) -> string {
	switch kind {
	case .Copy:    return "[1 Copy]"
	case .Cut:     return "[2 Cut]"
	case .Paste:   return "[3 Paste]"
	case .Rename:  return "[4 Rename]"
	case .NewFile: return shift ? "[⇧5 New Folder]" : "[5 New File]"
	case .Gather:  return ungather ? "[6 Ungather]" : "[6 Gather]"
	case .Trash:   return shift ? "[⇧7 Delete]" : "[7 Trash]"
	case .Clear:   return GATHER_CLEAR_LABEL
	case .Terminal: return "[9 Terminal]"
	case .Refresh: return "[⌘R Refresh]"
	case .Open:    return "[0 Open]"
	}
	return ""
}

action_number_key_code :: proc(key: uint) -> (Action_Kind, bool) {
	switch key {
	case 18: return .Copy, true
	case 19: return .Cut, true
	case 20: return .Paste, true
	case 21: return .Rename, true
	case 23: return .NewFile, true
	case 22: return .Gather, true
	case 26: return .Trash, true
	case 28: return .Clear, true
	case 25: return .Terminal, true
	case 29: return .Open, true
	}
	return .Copy, false
}

// action_is_number_key reports whether the key is a numbered shortcut; Shift
// keeps the same key code, so this also covers the shifted chords.
action_is_number_key :: proc(key: uint) -> bool {
	_, ok := action_number_key_code(key)
	return ok
}

action_available :: proc(tree: ^Tree, gathered, has_clip: bool, kind: Action_Kind) -> bool {
	switch kind {
	case .Copy, .Cut:
		if gathered {return true}
		_, ok := tree_selected_entry(tree)
		return ok
	case .Rename, .Gather:
		_, ok := tree_selected_entry(tree)
		return ok
	case .Paste:
		return has_clip
	case .Refresh:
		return true
	case .Open:
		entry, ok := tree_selected_entry(tree)
		return ok && !entry.is_dir
	case .NewFile, .Terminal:
		return tree.active >= 0 && tree.active < len(tree.columns)
	case .Trash, .Clear:
		return gathered
	}
	return false
}

ACTION_MAX :: 10

Action_Bar :: struct {
	kinds: [ACTION_MAX]Action_Kind,
	rects: [ACTION_MAX]draw.Rect,
	count: int,
}

// action_bar_layout are top-origin rects in the bottom row of the bar.
action_bar_layout :: proc(metrics: View_Metrics, gathered, ungather, shift: bool) -> Action_Bar {
	bar: Action_Bar
	top := metrics.height-metrics.row_height
	x := COLUMN_PAD
	for kind in ACTION_BAR_ORDER {
		if kind == .Trash && !gathered {continue}
		width := label_cells(action_label(kind, ungather, shift))*metrics.char_advance
		bar.kinds[bar.count] = kind
		bar.rects[bar.count] = {x, top, width, metrics.row_height}
		bar.count += 1
		x += width+ACTION_GAP_CELLS*metrics.char_advance
	}
	// Shortcuts that already have a key sit at the right edge, without a number.
	refresh_width := label_cells(action_label(.Refresh))*metrics.char_advance
	bar.kinds[bar.count] = .Refresh
	bar.rects[bar.count] = {metrics.width-COLUMN_PAD-refresh_width, top, refresh_width, metrics.row_height}
	bar.count += 1
	return bar
}

action_bar_at :: proc(metrics: View_Metrics, point: ui.Vec2, gathered, ungather, shift: bool) -> (Action_Kind, bool) {
	top := metrics.height-metrics.row_height
	if point.y < top || point.y >= top+metrics.row_height {return .Copy, false}
	bar := action_bar_layout(metrics, gathered, ungather, shift)
	for index in 0 ..< bar.count {
		rect := bar.rects[index]
		if point.x >= rect.x && point.x < rect.x+rect.w {return bar.kinds[index], true}
	}
	return .Copy, false
}

action_current_gathered :: proc(host: ^Host) -> bool {
	entry, ok := tree_selected_entry(&host.tree)
	return ok && path_list_contains(host.gather_paths[:], entry.path)
}

action_perform :: proc(host: ^Host, kind: Action_Kind, shift := false) {
	gathered := len(host.gather_paths) > 0
	if !action_available(&host.tree, gathered, len(host.clip_paths) > 0, kind) {return}
	switch kind {
	case .Copy:    action_clip(host, false)
	case .Cut:     action_clip(host, true)
	case .Paste:   action_paste(host)
	case .Rename:  edit_begin(host, .Rename)
	case .NewFile: edit_begin(host, shift ? .NewFolder : .NewFile)
	case .Gather:  action_gather(host)
	case .Trash:   action_destroy(host, to_trash = !shift)
	case .Clear:   gather_clear(&host.gather_paths)
	case .Terminal: action_terminal(host)
	case .Refresh: _ = tree_refresh(&host.tree)
	case .Open:    action_open(host)
	}
	host_request_frames(2)
}

// action_open opens the selected file in its default app, or in the editor chosen
// in settings when it is a text file. Enter does this for everything except text
// files, which it previews; this is their way in.
action_open :: proc(host: ^Host) {
	entry, ok := tree_selected_entry(&host.tree)
	if !ok || entry.is_dir {return}
	command := []string{"/usr/bin/open", "--", entry.path}
	if host.preview.kind == .Text && len(host.settings.editor) > 0 {
		command = []string{"/usr/bin/open", "-a", host.settings.editor, "--", entry.path}
	}
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = command}, context.allocator)
	defer delete(stdout, context.allocator)
	defer delete(stderr, context.allocator)
	if err != nil || !state.success || state.exit_code != 0 {
		devlog.failed(devlog.global(), {feature = "files", operation = "open_default"}, {
			reason = "file could not be opened",
			severity = .Warning,
		}, {file_id = entry.name})
		notice_set(host, "file could not be opened")
	}
}

// action_terminal opens the configured terminal in the focused column's folder.
action_terminal :: proc(host: ^Host) {
	directory, ok := action_paste_directory(&host.tree)
	if !ok {return}
	state, stdout, stderr, err := os.process_exec(os.Process_Desc{command = []string{"/usr/bin/open", "-a", host_terminal(), directory}}, context.allocator)
	defer delete(stdout, context.allocator)
	defer delete(stderr, context.allocator)
	if err != nil || !state.success || state.exit_code != 0 {
		devlog.failed(devlog.global(), {feature = "files", operation = "open_terminal"}, {
			reason = "terminal could not be opened",
			severity = .Warning,
		}, {file_id = filepath.base(directory)})
		notice_set(host, "terminal could not be opened")
	}
}

// action_gather marks or unmarks the highlighted entry, leaving the selection
// where it is.
action_gather :: proc(host: ^Host) {
	entry, ok := tree_selected_entry(&host.tree)
	if !ok {return}
	if path_list_contains(host.gather_paths[:], entry.path) {
		gather_remove(&host.gather_paths, entry.path)
		return
	}
	gather_add(&host.gather_paths, entry.path)
}

// action_clip marks the gathered set when there is one, otherwise the
// highlighted entry. Cut is a pending move drawn red; Copy is silent.
action_clip :: proc(host: ^Host, cut: bool) {
	action_clear_clip(host)
	if len(host.gather_paths) > 0 {
		for path in host.gather_paths {append(&host.clip_paths, strings.clone(path, context.allocator))}
	} else {
		entry, ok := tree_selected_entry(&host.tree)
		if !ok {return}
		append(&host.clip_paths, strings.clone(entry.path, context.allocator))
	}
	host.clip_cut = cut
	devlog.succeeded(
		devlog.global(),
		{feature = "files", operation = "clip"},
		{file_id = filepath.base(host.clip_paths[len(host.clip_paths)-1]), stage = cut ? "cut" : "copy"},
	)
}

action_clip_drop :: proc(host: ^Host, index: int) {
	delete(host.clip_paths[index], context.allocator)
	ordered_remove(&host.clip_paths, index)
}

action_paste :: proc(host: ^Host) {
	if len(host.clip_paths) == 0 {return}
	directory, has_target := action_paste_directory(&host.tree)
	if !has_target {return}
	site := devlog.Site{feature = "files", operation = "paste"}
	stage := host.clip_cut ? "move" : "copy"
	failures := 0
	index := 0
	for index < len(host.clip_paths) {
		source := host.clip_paths[index]
		file_id := filepath.base(source)
		if directory == source || strings.has_prefix(directory, strings.concatenate({source, "/"}, context.temp_allocator)) {
			devlog.failed(devlog.global(), site, {reason = "folder cannot be pasted into itself", severity = .Info}, {file_id = file_id, stage = stage})
			failures += 1
			index += 1
			continue
		}
		if host.clip_cut && filepath.dir(source) == directory {
			gather_remove(&host.gather_paths, source)
			action_clip_drop(host, index)
			continue
		}
		plain, _ := filepath.join([]string{directory, file_id}, context.temp_allocator)
		destination := plain
		if path_taken(plain) {
			if host.clip_cut {
				devlog.failed(devlog.global(), site, {reason = "destination name already exists", severity = .Info}, {file_id = file_id, stage = stage})
				failures += 1
				index += 1
				continue
			}
			// Finder keeps copied items on the clipboard and duplicates them with a
			// " copy" suffix, including into the same folder.
			destination = action_unique_destination(directory, file_id)
		}
		devlog.started(devlog.global(), site, {file_id = file_id, stage = stage})
		paste_code: i32
		if host.clip_cut {
			paste_code = action_move(source, destination)
		} else {
			paste_code = copy_item(source, destination)
		}
		if paste_code != 0 {
			devlog.failed(devlog.global(), site, {
				reason = host.clip_cut ? "file could not be moved" : "file could not be copied",
				detail = filepath.base(directory),
				code = paste_code,
				severity = .Warning,
			}, {file_id = file_id, stage = stage})
			failures += 1
			index += 1
			continue
		}
		devlog.succeeded(devlog.global(), site, {file_id = file_id, stage = stage, scope = filepath.base(directory)})
		if host.clip_cut {
			gather_remove(&host.gather_paths, source)
			action_clip_drop(host, index)
			continue
		}
		index += 1
	}
	if failures > 0 {
		notice_set(host, host.clip_cut ? "some items could not be moved" : "some items could not be copied")
	} else if host.clip_cut {
		action_clear_clip(host)
	}
	_ = tree_refresh(&host.tree)
}

// action_destroy removes the gathered set, moving it to the Trash or deleting it
// for good. Items that go leave the set; failures stay so a second press
// retries only those.
action_trash :: proc(host: ^Host) {action_destroy(host, to_trash = true)}

action_delete :: proc(host: ^Host) {action_destroy(host, to_trash = false)}

action_destroy :: proc(host: ^Host, to_trash: bool) {
	_ = gather_prune(&host.gather_paths)
	if len(host.gather_paths) == 0 {return}
	site := devlog.Site{feature = "files", operation = to_trash ? "trash" : "delete"}
	failures := 0
	index := 0
	for index < len(host.gather_paths) {
		path := host.gather_paths[index]
		gone := to_trash ? trash_item(path) : delete_item(path)
		if gone {
			devlog.succeeded(devlog.global(), site, {file_id = filepath.base(path), stage = to_trash ? "trash" : "delete"})
			gather_remove(&host.gather_paths, path)
			continue
		}
		devlog.failed(devlog.global(), site, {reason = to_trash ? "file could not be moved to the trash" : "file could not be deleted", severity = .Warning}, {file_id = filepath.base(path), stage = to_trash ? "trash" : "delete"})
		failures += 1
		index += 1
	}
	if failures > 0 {notice_set(host, to_trash ? "some items could not be trashed" : "some items could not be deleted")}
	action_clip_prune(host)
	_ = tree_refresh(&host.tree)
}

// action_paste_directory is the folder of the focused column, the one the pasted
// file appears in; enter a highlighted folder first to paste into it.
action_paste_directory :: proc(tree: ^Tree) -> (string, bool) {
	if tree.active < 0 || tree.active >= len(tree.columns) {return "", false}
	return tree.columns[tree.active].dir, true
}

// action_unique_destination mirrors Finder: "name copy.ext", then
// "name copy 2.ext".
action_unique_destination :: proc(directory, name: string) -> string {
	base, extension := name, ""
	if dot := strings.last_index_byte(name, '.'); dot > 0 {
		base, extension = name[:dot], name[dot:]
	}
	for index := 1; ; index += 1 {
		suffix := index == 1 ? " copy" : fmt.tprintf(" copy %d", index)
		name_with_suffix := strings.concatenate({base, suffix, extension}, context.temp_allocator)
		candidate, _ := filepath.join([]string{directory, name_with_suffix}, context.temp_allocator)
		if !path_taken(candidate) {return candidate}
	}
}

action_clear_clip :: proc(host: ^Host) {
	for path in host.clip_paths {delete(path, context.allocator)}
	delete(host.clip_paths)
	host.clip_paths = nil
}

action_clip_prune :: proc(host: ^Host) {
	for index := len(host.clip_paths)-1; index >= 0; index -= 1 {
		if !path_taken(host.clip_paths[index]) {action_clip_drop(host, index)}
	}
}

// action_move renames, falling back to copy-then-remove across volumes. It
// returns 0 or an errno.
action_move :: proc(source, destination: string) -> i32 {
	move_error := os.rename(source, destination)
	if move_error == nil {return 0}
	code := os_error_code(move_error)
	if code != EXDEV {return code}
	if copy_code := copy_item(source, destination); copy_code != 0 {
		_ = os.remove_all(destination)
		return copy_code
	}
	if os.remove_all(source) != nil {return EXDEV}
	return 0
}
