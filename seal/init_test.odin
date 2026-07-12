// BEGIN org:block init-test-package-helpers
package main

import "core:os"
import "core:path/filepath"
import "core:testing"
import seal_config "config"

test_path :: proc(parts: ..string) -> string {
	path, _ := filepath.join(parts[:])
	return path
}

make_test_tool :: proc(path: string) -> bool {
	if write_error := os.write_entire_file_from_string(path, "test tool\n"); write_error != nil {
		return false
	}
	permissions := os.Permissions_Read_All + os.Permissions_Execute_All + {.Write_User}
	return os.change_mode(path, permissions) == nil
}

make_init_fixture :: proc() -> (root, tools: string, ok: bool) {
	temp_error: os.Error
	root, temp_error = os.make_directory_temp("", "seal-init-*", context.allocator)
	if temp_error != nil {
		return "", "", false
	}
	tools = test_path(root, "tools")
	rsync := test_path(tools, "rsync")
	defer delete(rsync)
	ssh := test_path(tools, "ssh")
	defer delete(ssh)
	if os.make_directory(tools) != nil || !make_test_tool(rsync) || !make_test_tool(ssh) {
		_ = os.remove_all(root)
		delete(root)
		delete(tools)
		return "", "", false
	}
	return root, tools, true
}
// END org:block init-test-package-helpers
// BEGIN org:block local-init-test
@(test)
test_local_init_round_trips_through_config :: proc(t: ^testing.T) {
	root, tools, fixture_ok := make_init_fixture()
	testing.expect(t, fixture_ok)
	if !fixture_ok {
		return
	}
	defer delete(root)
	defer delete(tools)
	defer { _ = os.remove_all(root) }

	workspace := test_path(root, "workspace")
	defer delete(workspace)
	testing.expect(t, os.make_directory(workspace) == nil)
	selected := test_path(workspace, "seal.toml")
	defer delete(selected)
	config_path, mailbox_path, rsync_path, ssh_path, problem, ok := initialize_workspace(
		selected,
		"../peer/mailbox",
		"",
		tools,
	)
	defer delete(config_path)
	defer delete(mailbox_path)
	defer delete(rsync_path)
	defer {
		if len(ssh_path) > 0 {
			delete(ssh_path)
		}
	}
	testing.expect(t, ok, problem)
	testing.expect(t, os.exists(config_path))
	mailbox_info, mailbox_error := os.stat(mailbox_path, context.allocator)
	testing.expect(t, mailbox_error == nil)
	if mailbox_error == nil {
		defer os.file_info_delete(mailbox_info, context.allocator)
		testing.expect_value(t, mailbox_info.type, os.File_Type.Directory)
	}

	config, config_problem, loaded := seal_config.load_config(config_path)
	defer seal_config.destroy_config(&config)
	defer seal_config.destroy_config_error(&config_problem)
	testing.expect(t, loaded, config_problem.message)
	testing.expect_value(t, config.local_mailbox, mailbox_path)
	expected_peer := test_path(root, "peer/mailbox")
	defer delete(expected_peer)
	testing.expect_value(t, config.peer_path, expected_peer)
	expected_rsync := test_path(tools, "rsync")
	defer delete(expected_rsync)
	testing.expect_value(t, rsync_path, expected_rsync)
	testing.expect_value(t, config.rsync, expected_rsync)
	testing.expect_value(t, config.peer_ssh, "")
}
// END org:block local-init-test
// BEGIN org:block ssh-init-test
@(test)
test_ssh_init_records_remote_coordinates_and_tools :: proc(t: ^testing.T) {
	root, tools, fixture_ok := make_init_fixture()
	testing.expect(t, fixture_ok)
	if !fixture_ok {
		return
	}
	defer delete(root)
	defer delete(tools)
	defer { _ = os.remove_all(root) }

	selected := test_path(root, "seal.toml")
	defer delete(selected)
	config_path, mailbox_path, rsync_path, ssh_path, problem, ok := initialize_workspace(
		selected,
		"/home/agent/mailbox",
		"experiment.agent",
		tools,
	)
	defer delete(config_path)
	defer delete(mailbox_path)
	defer delete(rsync_path)
	defer delete(ssh_path)
	testing.expect(t, ok, problem)

	config, config_problem, loaded := seal_config.load_config(config_path)
	defer seal_config.destroy_config(&config)
	defer seal_config.destroy_config_error(&config_problem)
	testing.expect(t, loaded, config_problem.message)
	testing.expect_value(t, config.peer_path, "/home/agent/mailbox")
	testing.expect_value(t, config.peer_ssh, "experiment.agent")
	expected_rsync := test_path(tools, "rsync")
	defer delete(expected_rsync)
	expected_ssh := test_path(tools, "ssh")
	defer delete(expected_ssh)
	testing.expect_value(t, rsync_path, expected_rsync)
	testing.expect_value(t, ssh_path, expected_ssh)
	testing.expect_value(t, config.rsync, expected_rsync)
	testing.expect_value(t, config.ssh, expected_ssh)
}
// END org:block ssh-init-test
// BEGIN org:block init-conflict-test
@(test)
test_init_conflicts_do_not_mutate_workspace :: proc(t: ^testing.T) {
	root, tools, fixture_ok := make_init_fixture()
	testing.expect(t, fixture_ok)
	if !fixture_ok {
		return
	}
	defer delete(root)
	defer delete(tools)
	defer { _ = os.remove_all(root) }

	config_conflict := test_path(root, "config-conflict")
	defer delete(config_conflict)
	testing.expect(t, os.make_directory(config_conflict) == nil)
	selected := test_path(config_conflict, "seal.toml")
	testing.expect(t, os.write_entire_file_from_string(selected, "keep config\n") == nil)
	config_path, mailbox_path, rsync_path, ssh_path, problem, ok := initialize_workspace(
		selected,
		"peer",
		"",
		tools,
	)
	delete(config_path)
	delete(mailbox_path)
	if len(rsync_path) > 0 {
		delete(rsync_path)
	}
	if len(ssh_path) > 0 {
		delete(ssh_path)
	}
	testing.expect(t, !ok)
	testing.expect_value(t, problem, "configuration path already exists")
	mailbox := test_path(config_conflict, "mailbox")
	testing.expect(t, !os.exists(mailbox))
	delete(mailbox)
	contents, read_error := os.read_entire_file(selected, context.allocator)
	testing.expect(t, read_error == nil)
	if read_error == nil {
		defer delete(contents)
		testing.expect_value(t, string(contents), "keep config\n")
	}
	delete(selected)

	mailbox_conflict := test_path(root, "mailbox-conflict")
	defer delete(mailbox_conflict)
	testing.expect(t, os.make_directory(mailbox_conflict) == nil)
	mailbox = test_path(mailbox_conflict, "mailbox")
	testing.expect(t, os.make_directory(mailbox) == nil)
	marker := test_path(mailbox, "keep")
	testing.expect(t, os.write_entire_file_from_string(marker, "keep\n") == nil)
	selected = test_path(mailbox_conflict, "seal.toml")
	config_path, mailbox_path, rsync_path, ssh_path, problem, ok = initialize_workspace(
		selected,
		"peer",
		"",
		tools,
	)
	delete(config_path)
	delete(mailbox_path)
	if len(rsync_path) > 0 {
		delete(rsync_path)
	}
	if len(ssh_path) > 0 {
		delete(ssh_path)
	}
	testing.expect(t, !ok)
	testing.expect_value(t, problem, "mailbox path already exists")
	testing.expect(t, !os.exists(selected))
	testing.expect(t, os.exists(marker))
	delete(selected)
	delete(marker)
	delete(mailbox)
}
// END org:block init-conflict-test
