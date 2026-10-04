package file_manager

import diag "diagnostics:."

// diagnostics_config identifies this app to hw_odin_diagnostics. app_name must
// match CFBundleName and the app's devlog key, so the standalone helper finds
// the journal.
diagnostics_config :: proc() -> diag.Config {
	return diag.Config {
		app_name = "hw_fileManager",
		display_name = "hw_fileManager",
		bundle_id = "com.halwayland.filemanager",
		version = APP_VERSION,
	}
}
