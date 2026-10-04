package file_manager

import "core:os"
import "core:testing"

CLI_TEST_HOME :: "/tmp/hw_fileManager-cli-test"

@(test)
cli_install_writes_and_removes_our_shim :: proc(t: ^testing.T) {
	original := os.get_env("HOME", context.temp_allocator)
	_ = os.remove_all(CLI_TEST_HOME)
	defer os.remove_all(CLI_TEST_HOME)
	_ = os.set_env("HOME", CLI_TEST_HOME)
	defer os.set_env("HOME", original)

	testing.expect(t, !cli_installed())
	testing.expect(t, cli_install())
	testing.expect(t, cli_installed())
	testing.expect(t, os.is_file(cli_path(context.temp_allocator)))
	testing.expect(t, cli_remove())
	testing.expect(t, !cli_installed())
}

@(test)
cli_refuses_a_foreign_file :: proc(t: ^testing.T) {
	original := os.get_env("HOME", context.temp_allocator)
	_ = os.remove_all(CLI_TEST_HOME)
	defer os.remove_all(CLI_TEST_HOME)
	_ = os.set_env("HOME", CLI_TEST_HOME)
	defer os.set_env("HOME", original)

	path := cli_path(context.temp_allocator)
	testing.expect(t, os.make_directory_all("/tmp/hw_fileManager-cli-test/.local/bin") == nil)
	testing.expect(t, os.write_entire_file(path, "#!/bin/sh\necho not ours\n") == nil)
	testing.expect(t, !cli_installed())
	testing.expect(t, !cli_remove())
	testing.expect(t, os.is_file(path))
}
