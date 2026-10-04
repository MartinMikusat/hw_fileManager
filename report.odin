package file_manager

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import NS "core:sys/darwin/Foundation"
import devlog "devlog:."

REPORT_TAIL_LINES :: 80
REPORT_CRASH_CONTEXT :: 30
REPORT_CRASH_LINES :: 80

report_directory :: proc(allocator := context.allocator) -> string {
	return devlog.default_directory("hw_fileManager", "app", allocator)
}

report_journal_path :: proc(directory: string, allocator := context.allocator) -> string {
	return fmt.aprintf("%s/devlog.jsonl", directory, allocator = allocator)
}

report_marker_path :: proc(directory: string, allocator := context.allocator) -> string {
	return fmt.aprintf("%s/running.marker", directory, allocator = allocator)
}

report_home :: proc() -> string {
	return os.get_env("HOME", context.temp_allocator)
}

report_default_path :: proc(allocator := context.allocator) -> string {
	return fmt.aprintf("%s/Desktop/hw_fileManager-diagnostics.txt", report_home(), allocator = allocator)
}

// report_redact keeps the user's home directory out of anything they might send.
report_redact :: proc(text, home: string, allocator := context.allocator) -> string {
	if len(home) == 0 {return text}
	output, _ := strings.replace_all(text, home, "~", allocator)
	return output
}

// report_build assembles the redacted text a user can paste or attach: an
// environment header, the journal around the last failure, and the newest
// matching macOS crash report.
report_build :: proc(directory: string, allocator := context.allocator) -> string {
	home := report_home()
	builder := strings.builder_make(allocator)
	process := NS.ProcessInfo_processInfo()
	os_version := process != nil ? NS.String_odinString(NS.ProcessInfo_operatingSystemVersionString(process)) : "unknown"
	crashed := os.exists(report_marker_path(directory, context.temp_allocator))

	fmt.sbprintf(&builder, "hw_fileManager diagnostics\n")
	fmt.sbprintf(&builder, "version: %s\n", APP_VERSION)
	fmt.sbprintf(&builder, "bundle: %s\n", CLI_BUNDLE_ID)
	fmt.sbprintf(&builder, "macOS: %s\n", os_version)
	fmt.sbprintf(&builder, "arch: %v\n", ODIN_ARCH)
	fmt.sbprintf(&builder, "previous run crashed: %s\n", crashed ? "yes" : "no")
	fmt.sbprintf(&builder, "generated: %v\n", time.now())
	fmt.sbprintf(&builder, "\n--- journal ---\n%s", report_journal_tail(report_journal_path(directory, context.temp_allocator), allocator))
	fmt.sbprintf(&builder, "\n--- crash report ---\n%s", report_crash_report(home, allocator))

	return report_redact(strings.to_string(builder), home, allocator)
}

report_failure :: proc(line: string) -> bool {
	return strings.contains(line, `"outcome":"failed"`) || strings.contains(line, `"severity":"error"`) || strings.contains(line, `"severity":"critical"`) || strings.contains(line, `"severity":"warning"`)
}

// report_routine drops the per-directory read records that dominate the journal
// and say nothing about why something went wrong.
report_routine :: proc(line: string) -> bool {
	return strings.contains(line, `"feature":"files"`) && strings.contains(line, `"operation":"read_directory"`)
}

// report_journal_tail keeps the last failure with its surrounding records, or the
// plain tail when nothing failed.
report_journal_tail :: proc(path: string, allocator := context.allocator) -> string {
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {return "(no journal)\n"}
	lines := strings.split_lines(string(data), context.temp_allocator)
	if len(lines) == 0 {return "(empty journal)\n"}
	last_failure := -1
	for line, index in lines {
		if report_failure(line) {last_failure = index}
	}
	start, end := max(len(lines)-REPORT_TAIL_LINES, 0), len(lines)
	if last_failure >= 0 {
		start = min(start, max(last_failure-REPORT_CRASH_CONTEXT, 0))
		end = max(end, min(last_failure+REPORT_CRASH_CONTEXT, len(lines)))
	}
	builder := strings.builder_make(allocator)
	for index in start ..< end {
		if report_routine(lines[index]) {continue}
		fmt.sbprintf(&builder, "%s\n", lines[index])
	}
	return strings.to_string(builder)
}

// report_crash_report returns the newest macOS crash report for this app, if any.
report_crash_report :: proc(home: string, allocator := context.allocator) -> string {
	directory := fmt.tprintf("%s/Library/Logs/DiagnosticReports", home)
	handle, open_error := os.open(directory)
	if open_error != nil {return "(no crash reports)\n"}
	defer os.close(handle)
	infos, read_error := os.read_dir(handle, -1, context.temp_allocator)
	if read_error != nil {return "(no crash reports)\n"}
	defer os.file_info_slice_delete(infos, context.temp_allocator)

	best := ""
	best_time: time.Time
	for info in infos {
		if !strings.has_suffix(info.name, ".ips") {continue}
		data, file_error := os.read_entire_file(info.fullpath, context.temp_allocator)
		if file_error != nil {continue}
		if !strings.contains(string(data), "file_manager") {continue}
		if len(best) == 0 || time.diff(best_time, info.modification_time) < 0 {
			best = strings.clone(info.fullpath, context.temp_allocator)
			best_time = info.modification_time
		}
	}
	if len(best) == 0 {return "(no crash reports)\n"}

	data, _ := os.read_entire_file(best, context.temp_allocator)
	lines := strings.split_lines(string(data), context.temp_allocator)
	builder := strings.builder_make(allocator)
	fmt.sbprintf(&builder, "file: %s\n", best)
	for index in 0 ..< min(len(lines), REPORT_CRASH_LINES) {fmt.sbprintf(&builder, "%s\n", lines[index])}
	return strings.to_string(builder)
}

report_write_file :: proc(path: string, allocator := context.allocator) -> bool {
	text := report_build(report_directory(context.temp_allocator), allocator)
	defer delete(text, allocator)
	return os.write_entire_file(path, text) == nil
}

report_copy_to_clipboard :: proc(text: string) -> bool {
	pasteboard := edit_pasteboard()
	if pasteboard == nil {return false}
	_ = intrinsics.objc_send(i64, pasteboard, "clearContents")
	return bool(intrinsics.objc_send(NS.BOOL, pasteboard, "setString:forType:", edit_nsstring(text), edit_nsstring("public.utf8-plain-text")))
}

// run_diagnostics is the headless path: it touches no AppKit or Metal, so it
// still works when the window cannot start. It writes a file by default.
run_diagnostics :: proc(arguments: []string) -> bool {
	out := ""
	to_stdout := false
	for argument in arguments {
		switch {
		case strings.has_prefix(argument, "--out="): out = strings.trim_prefix(argument, "--out=")
		case argument == "--stdout": to_stdout = true
		}
	}
	text := report_build(report_directory(context.temp_allocator), context.allocator)
	defer delete(text, context.allocator)
	if to_stdout {
		fmt.print(text)
		return true
	}
	if len(out) == 0 {out = report_default_path(context.temp_allocator)}
	if os.write_entire_file(out, text) != nil {
		fmt.eprintln("[hw_fileManager] could not write the diagnostics file")
		return false
	}
	fmt.printf("wrote %s\n", out)
	return true
}
