// BEGIN org:block init-package-imports
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
// END org:block init-package-imports
// BEGIN org:block init-output-path-resolution
absolute_init_path :: proc(path: string) -> (string, bool) {
	if filepath.is_abs(path) {
		cleaned, clean_error := filepath.clean(path)
		return cleaned, clean_error == nil
	}
	cwd, cwd_error := os.get_absolute_path(".", context.allocator)
	if cwd_error != nil {
		return "", false
	}
	defer delete(cwd)
	absolute, join_error := filepath.join([]string{cwd, path})
	return absolute, join_error == nil
}
// END org:block init-output-path-resolution
// BEGIN org:block init-tool-discovery
resolve_path_tool :: proc(name, path_value: string) -> (string, bool) {
	directories, split_error := os.split_path_list(path_value, context.allocator)
	if split_error != nil {
		return "", false
	}
	defer {
		for directory in directories {
			delete(directory)
		}
		delete(directories)
	}

	for path_directory in directories {
		directory := path_directory
		if len(path_directory) == 0 {
			directory = "."
		}
		candidate, join_error := filepath.join([]string{directory, name})
		if join_error != nil {
			continue
		}
		info, stat_error := os.stat(candidate, context.allocator)
		if stat_error != nil {
			delete(candidate)
			continue
		}
		candidate_cstring, cstring_error := strings.clone_to_cstring(
			candidate,
			context.temp_allocator,
		)
		executable := info.type == .Regular &&
			cstring_error == nil &&
			posix.access(candidate_cstring, {.X_OK}) == .OK
		os.file_info_delete(info, context.allocator)
		if !executable {
			delete(candidate)
			continue
		}

		absolute, absolute_error := os.get_absolute_path(candidate, context.allocator)
		delete(candidate)
		if absolute_error == nil {
			return absolute, true
		}
	}
	return "", false
}
// END org:block init-tool-discovery
// BEGIN org:block init-config-projection
init_scalar_representable :: proc(value: string) -> bool {
	for byte_value in transmute([]byte)value {
		if byte_value < 0x20 || byte_value > 0x7e || byte_value == '"' || byte_value == '\\' {
			return false
		}
	}
	return true
}

INIT_LOCAL_CONFIG_TEMPLATE :: `local_mailbox = "mailbox"

[peer]
path = "%s"

[tools]
rsync = "%s"
`

INIT_SSH_CONFIG_TEMPLATE :: `local_mailbox = "mailbox"

[peer]
path = "%s"
ssh = "%s"

[tools]
rsync = "%s"
ssh = "%s"
`

render_init_config :: proc(
	peer_path, peer_ssh: string,
	rsync, ssh: string,
) -> (string, bool) {
	values := []string{peer_path, peer_ssh, rsync, ssh}
	for value in values {
		if !init_scalar_representable(value) {
			return "", false
		}
	}
	if len(peer_ssh) == 0 {
		return fmt.aprintf(
			INIT_LOCAL_CONFIG_TEMPLATE,
			peer_path,
			rsync,
		), true
	}
	return fmt.aprintf(
		INIT_SSH_CONFIG_TEMPLATE,
		peer_path,
		peer_ssh,
		rsync,
		ssh,
	), true
}
// END org:block init-config-projection
// BEGIN org:block init-filesystem-preflight
path_conflicts :: proc(path: string) -> (conflicts, inspect_failed: bool) {
	info, stat_error := os.lstat(path, context.allocator)
	if stat_error == nil {
		os.file_info_delete(info, context.allocator)
		return true, false
	}
	if stat_error == .Not_Exist {
		return false, false
	}
	return false, true
}
// END org:block init-filesystem-preflight
// BEGIN org:block init-exclusive-config-creation
write_new_config :: proc(path, text: string) -> bool {
	file, open_error := os.open(
		path,
		{.Write, .Create, .Excl},
		os.Permissions_Read_All + {.Write_User},
	)
	if open_error != nil {
		return false
	}
	written, write_error := os.write(file, transmute([]byte)text)
	close_error := os.close(file)
	if write_error != nil || close_error != nil || written != len(text) {
		_ = os.remove(path)
		return false
	}
	return true
}
// END org:block init-exclusive-config-creation
// BEGIN org:block init-workspace-orchestration
initialize_workspace :: proc(
	selected_path, peer_path, peer_ssh: string,
	path_value: string,
) -> (config_path, mailbox_path, problem: string, ok: bool) {
	// Resolve every path init may create.
	resolved: bool
	config_path, resolved = absolute_init_path(selected_path)
	if !resolved {
		return "", "", "cannot resolve configuration path", false
	}
	directory := filepath.dir(config_path)
	path_error: os.Error
	mailbox_path, path_error = filepath.join([]string{directory, "mailbox"})
	if path_error != nil {
		return config_path, "", "cannot resolve mailbox path", false
	}

	// Preflight both targets before filesystem mutation.
	config_exists, inspect_failed := path_conflicts(config_path)
	if inspect_failed {
		return config_path, mailbox_path, "cannot inspect configuration path", false
	}
	if config_exists {
		return config_path, mailbox_path, "configuration path already exists", false
	}
	mailbox_exists: bool
	mailbox_exists, inspect_failed = path_conflicts(mailbox_path)
	if inspect_failed {
		return config_path, mailbox_path, "cannot inspect mailbox path", false
	}
	if mailbox_exists {
		return config_path, mailbox_path, "mailbox path already exists", false
	}
	if len(peer_path) == 0 {
		return config_path, mailbox_path, "peer values must not be empty", false
	}

	// Resolve tools and render all config content before mutation.
	rsync, found_rsync := resolve_path_tool("rsync", path_value)
	if !found_rsync {
		return config_path, mailbox_path, "cannot find executable rsync in PATH", false
	}
	defer delete(rsync)
	ssh := ""
	if len(peer_ssh) > 0 {
		found_ssh: bool
		ssh, found_ssh = resolve_path_tool("ssh", path_value)
		if !found_ssh {
			return config_path, mailbox_path, "cannot find executable ssh in PATH", false
		}
	}
	defer {
		if len(ssh) > 0 {
			delete(ssh)
		}
	}

	text, rendered := render_init_config(peer_path, peer_ssh, rsync, ssh)
	if !rendered {
		return config_path, mailbox_path, "peer or tool path cannot be represented", false
	}
	defer delete(text)
	// Create the mailbox, then exclusively write config with bounded rollback.
	if directory_error := os.make_directory(mailbox_path); directory_error != nil {
		return config_path, mailbox_path, "cannot create mailbox directory", false
	}
	if !write_new_config(config_path, text) {
		_ = os.remove(mailbox_path)
		return config_path, mailbox_path, "cannot create configuration", false
	}
	return config_path, mailbox_path, "", true
}
// END org:block init-workspace-orchestration
// BEGIN org:block init-command-adapter
run_init :: proc(cli: Cli) -> int {
	path_value := os.get_env("PATH", context.allocator)
	defer delete(path_value)
	config_path, mailbox_path, problem, ok := initialize_workspace(
		cli.config,
		cli.peer_path,
		cli.peer_ssh,
		path_value,
	)
	defer {
		if len(config_path) > 0 {
			delete(config_path)
		}
		if len(mailbox_path) > 0 {
			delete(mailbox_path)
		}
	}
	if !ok {
		error("init", problem)
		return 1
	}
	info("configuration", config_path)
	info("mailbox", mailbox_path)
	return 0
}
// END org:block init-command-adapter
