// BEGIN org:block init-package-imports
package main

import "core:fmt"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
// END org:block init-package-imports
// BEGIN org:block init-output-path-resolution
absolute_init_path :: proc(path: string) -> (result: string, problem: os.Error) {
	if filepath.is_abs(path) {
		cleaned := filepath.clean(path) or_return
		return cleaned, nil
	}
	cwd := os.get_absolute_path(".", context.allocator) or_return
	defer delete(cwd)
	absolute := filepath.join([]string{cwd, path}) or_return
	return absolute, nil
}
// END org:block init-output-path-resolution
// BEGIN org:block init-tool-discovery
resolve_path_tool :: proc(name, path_value: string) -> (
	tool_path: string,
	found: bool,
	problem: os.Error,
) {
	// Phase: Prepare owned PATH search entries.

	directories := os.split_path_list(path_value, context.allocator) or_return
	defer {
		for directory in directories {
			delete(directory)
		}
		delete(directories)
	}

	// Phase: Inspect candidates in PATH order.

	for path_directory in directories {
		// Form candidate, treating an empty entry as the current directory.
		directory := path_directory
		if len(path_directory) == 0 {
			directory = "."
		}
		candidate := filepath.join([]string{directory, name}) or_return
		// Require a regular file executable by the current process.
		info, stat_error := os.stat(candidate, context.allocator)
		if stat_error != nil {
			delete(candidate)
			expected_miss := stat_error == .Not_Exist || stat_error == .Invalid_Dir
			if platform_error, platform_specific := os.is_platform_error(stat_error); platform_specific {
				#partial switch posix.Errno(platform_error) {
				case .ENOENT, .ENOTDIR, .EACCES, .ELOOP:
					expected_miss = true
				}
			}
			if expected_miss {
				continue
			}
			return "", false, stat_error
		}
		candidate_cstring, cstring_error := strings.clone_to_cstring(
			candidate,
			context.temp_allocator,
		)
		if cstring_error != nil {
			os.file_info_delete(info, context.allocator)
			delete(candidate)
			return "", false, cstring_error
		}
		executable := info.type == .Regular &&
			posix.access(candidate_cstring, {.X_OK}) == .OK
		os.file_info_delete(info, context.allocator)
		if !executable {
			delete(candidate)
			continue
		}

		// Resolve the candidate's absolute identity.
		absolute, absolute_error := os.get_absolute_path(candidate, context.allocator)
		delete(candidate)
		if absolute_error != nil {
			return "", false, absolute_error
		}
		return absolute, true, nil
	}
	return "", false, nil
}
// END org:block init-tool-discovery
// BEGIN org:block init-config-projection
init_scalar_representable :: proc(value: string) -> bool {
	// Printable ASCII including space, except double quote and backslash.
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
path_conflicts :: proc(path: string) -> (conflicts: bool, problem: os.Error) {
	info, stat_error := os.lstat(path, context.allocator)
	if stat_error == nil {
		os.file_info_delete(info, context.allocator)
		return true, nil
	}
	if stat_error == .Not_Exist {
		return false, nil
	}
	return false, stat_error
}
// END org:block init-filesystem-preflight
// BEGIN org:block init-exclusive-config-creation
write_new_config :: proc(path, text: string) -> os.Error {
	file := os.open(
		path,
		{.Write, .Create, .Excl},
		os.Permissions_Read_All + {.Write_User},
	) or_return
	written, write_error := os.write(file, transmute([]byte)text)
	close_error := os.close(file)
	if write_error != nil {
		_ = os.remove(path)
		return write_error
	}
	if close_error != nil {
		_ = os.remove(path)
		return close_error
	}
	if written != len(text) {
		_ = os.remove(path)
		return os.Error(io.Error.Short_Write)
	}
	return nil
}
// END org:block init-exclusive-config-creation
// BEGIN org:block init-workspace-orchestration
initialize_workspace :: proc(
	requested_config_path, peer_path, peer_ssh: string,
	path_value: string,
) -> (
	config_path, mailbox_path: string,
	rsync_path, ssh_path: string,
	problem: string,
	ok: bool,
) {
	// Phase: Preflight paths, peer input, tools, and rendered config.

	// Resolve output paths.
	path_problem: os.Error
	config_path, path_problem = absolute_init_path(requested_config_path)
	if path_problem != nil {
		return "", "", "", "", "cannot resolve configuration path", false
	}
	directory := filepath.dir(config_path)
	mailbox_path, path_problem = filepath.join([]string{directory, "mailbox"})
	if path_problem != nil {
		return config_path, "", "", "", "cannot resolve mailbox path", false
	}

	// Reject target conflicts.
	config_exists, inspect_problem := path_conflicts(config_path)
	if inspect_problem != nil {
		return config_path, mailbox_path, "", "", "cannot inspect configuration path", false
	}
	if config_exists {
		return config_path, mailbox_path, "", "", "configuration path already exists", false
	}
	mailbox_exists: bool
	mailbox_exists, inspect_problem = path_conflicts(mailbox_path)
	if inspect_problem != nil {
		return config_path, mailbox_path, "", "", "cannot inspect mailbox path", false
	}
	if mailbox_exists {
		return config_path, mailbox_path, "", "", "mailbox path already exists", false
	}
	// Validate peer coordinates.
	if len(peer_path) == 0 {
		return config_path, mailbox_path, "", "", "peer values must not be empty", false
	}

	// Resolve pinned rsync and conditional SSH.
	found_rsync: bool
	tool_problem: os.Error
	rsync_path, found_rsync, tool_problem = resolve_path_tool("rsync", path_value)
	if tool_problem != nil {
		return config_path, mailbox_path, rsync_path, "", "cannot inspect executable rsync in PATH", false
	}
	if !found_rsync {
		return config_path, mailbox_path, "", "", "cannot find executable rsync in PATH", false
	}
	if len(peer_ssh) > 0 {
		found_ssh: bool
		ssh_path, found_ssh, tool_problem = resolve_path_tool("ssh", path_value)
		if tool_problem != nil {
			return config_path, mailbox_path, rsync_path, ssh_path, "cannot inspect executable ssh in PATH", false
		}
		if !found_ssh {
			return config_path, mailbox_path, rsync_path, "", "cannot find executable ssh in PATH", false
		}
	}

	// Project complete config text.
	text, rendered := render_init_config(peer_path, peer_ssh, rsync_path, ssh_path)
	if !rendered {
		return config_path, mailbox_path, rsync_path, ssh_path, "peer or tool path cannot be represented", false
	}
	defer delete(text)
	// Phase: Apply filesystem changes with bounded rollback.

	// Create mailbox.
	if directory_error := os.make_directory(mailbox_path); directory_error != nil {
		return config_path, mailbox_path, rsync_path, ssh_path, "cannot create mailbox directory", false
	}
	// Exclusively create config; roll back mailbox on failure.
	if config_problem := write_new_config(config_path, text); config_problem != nil {
		_ = os.remove(mailbox_path)
		return config_path, mailbox_path, rsync_path, ssh_path, "cannot create configuration", false
	}
	return config_path, mailbox_path, rsync_path, ssh_path, "", true
}
// END org:block init-workspace-orchestration
// BEGIN org:block init-command-adapter
run_init :: proc(cli: Cli) -> int {
	path_value := os.get_env("PATH", context.allocator)
	defer delete(path_value)
	config_path, mailbox_path, rsync_path, ssh_path, problem, ok := initialize_workspace(
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
		if len(rsync_path) > 0 {
			delete(rsync_path)
		}
		if len(ssh_path) > 0 {
			delete(ssh_path)
		}
	}
	if !ok {
		error("init", problem)
		return 1
	}
	info("created configuration", config_path)
	info("created mailbox", mailbox_path)
	info("pinned rsync", rsync_path)
	if len(ssh_path) > 0 {
		info("pinned ssh", ssh_path)
	}
	return 0
}
// END org:block init-command-adapter
