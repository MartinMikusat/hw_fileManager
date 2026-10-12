package file_manager

import "base:intrinsics"
import "base:runtime"
import "core:os"
import "core:strings"
import "core:thread"
import devlog "devlog:."

Cloud_State :: enum u32 {
	Running,
	Done,
	Failed,
}

// Cloud_Download materializes one iCloud file by reading it through; the File Provider
// downloads the content on the first read. The worker only sets state; the main thread
// owns everything else.
Cloud_Download :: struct {
	path:   string,
	thread: ^thread.Thread,
	state:  Cloud_State,
}

cloud_downloads: [dynamic]^Cloud_Download

cloud_worker :: proc(worker: ^thread.Thread) {
	context = runtime.default_context()
	download := (^Cloud_Download)(worker.data)
	result := Cloud_State.Failed
	defer intrinsics.atomic_store(&download.state, result)
	file, open_error := os.open(download.path)
	if open_error != nil {return}
	defer os.close(file)
	buffer := make([]u8, 1024*1024)
	defer delete(buffer)
	for {
		count, read_error := os.read(file, buffer)
		if read_error == .EOF || read_error == nil && count <= 0 {break}
		if read_error != nil {return}
	}
	result = .Done
}

// cloud_settled reports that a downloading preview has something new to show: the file
// landed on disk, or its download failed.
cloud_settled :: proc(path: string) -> bool {
	return !path_dataless(path) || cloud_poll(path) != .Running
}

// cloud_poll starts the download of path when none is known, drops finished downloads
// and failed ones for other files, and reports the state of path's download.
cloud_poll :: proc(path: string) -> Cloud_State {
	state := Cloud_State.Running
	found := false
	for index := len(cloud_downloads)-1; index >= 0; index -= 1 {
		download := cloud_downloads[index]
		current := intrinsics.atomic_load(&download.state)
		if download.path == path {
			found = true
			state = current
		}
		if current == .Running || current == .Failed && download.path == path {continue}
		thread.destroy(download.thread)
		delete(download.path)
		free(download)
		unordered_remove(&cloud_downloads, index)
	}
	if found {return state}
	download := new(Cloud_Download)
	download.path = strings.clone(path)
	download.thread = thread.create(cloud_worker)
	if download.thread == nil {
		devlog.failed(devlog.global(), {feature = "files", operation = "cloud_download"}, {reason = "download worker could not start", severity = .Warning})
		delete(download.path)
		free(download)
		return .Failed
	}
	download.thread.data = download
	append(&cloud_downloads, download)
	thread.start(download.thread)
	return .Running
}
