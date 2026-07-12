// BEGIN org:block config-schema-and-resolution
package main

import config_toml "../config_toml"
import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"

Config :: struct {
	path:             string,
	directory:        string,
	local_mailbox:    string,
	peer_path:        string,
	peer_ssh:         string,
	rsync:            string,
	ssh:              string,
	rsync_debug_flag: string,
	ssh_debug_flag:   string,
}

Config_Error :: struct {
	path:    string,
	line:    int,
	message: string,
}

ROOT_KEYS := [?]string{"local_mailbox", "peer", "tools", "debug"}
PEER_KEYS := [?]string{"path", "ssh"}
TOOLS_KEYS := [?]string{"rsync", "ssh"}
DEBUG_KEYS := [?]string{"rsync_debug_flags", "ssh_debug_flags"}

config_error :: proc(path: string, line: int, message: string) -> Config_Error {
	return Config_Error{
		path = strings.clone(path),
		line = line,
		message = strings.clone(message),
	}
}

destroy_config_error :: proc(problem: ^Config_Error) {
	if len(problem.path) > 0 {
		delete(problem.path)
	}
	if len(problem.message) > 0 {
		delete(problem.message)
	}
	problem^ = {}
}

contains_key :: proc(allowed: []string, candidate: string) -> bool {
	for key in allowed {
		if key == candidate {
			return true
		}
	}
	return false
}

validate_table :: proc(
	document: ^config_toml.Document,
	path: []string,
	allowed: []string,
	required: bool,
	missing_message: string,
	wrong_type_message: string,
	unknown_message: string,
	allocator: runtime.Allocator,
) -> (config_toml.Lookup_Status, string) {
	keys, status := config_toml.table_keys(document, path, allocator)
	if status == .Missing && !required {
		return status, ""
	}
	if status == .Missing {
		return status, missing_message
	}
	if status == .Wrong_Type {
		return status, wrong_type_message
	}
	defer config_toml.destroy_string_array(keys, allocator)
	for key in keys {
		if !contains_key(allowed, key) {
			return status, unknown_message
		}
	}
	return status, ""
}

required_string :: proc(
	document: ^config_toml.Document,
	path: []string,
	missing_message, wrong_type_message: string,
	allocator: runtime.Allocator,
) -> (string, string) {
	value, status := config_toml.get_string(document, path, allocator)
	switch status {
	case .Found:
		return value, ""
	case .Missing:
		return "", missing_message
	case .Wrong_Type:
		return "", wrong_type_message
	}
	return "", wrong_type_message
}

optional_string :: proc(
	document: ^config_toml.Document,
	path: []string,
	wrong_type_message: string,
	allocator: runtime.Allocator,
) -> (string, config_toml.Lookup_Status, string) {
	value, status := config_toml.get_string(document, path, allocator)
	if status == .Wrong_Type {
		return "", status, wrong_type_message
	}
	return value, status, ""
}

valid_debug_flag :: proc(value: string) -> bool {
	return value == "-v" || value == "-vv" || value == "-vvv"
}

debug_flag :: proc(
	document: ^config_toml.Document,
	key, wrong_type_message: string,
	allocator: runtime.Allocator,
) -> (string, config_toml.Lookup_Status, string) {
	values, status := config_toml.get_string_array(
		document,
		[]string{"debug", key},
		allocator,
	)
	if status == .Missing {
		return "", status, ""
	}
	if status == .Wrong_Type {
		return "", status, wrong_type_message
	}
	defer config_toml.destroy_string_array(values, allocator)
	if len(values) > 1 {
		return "", status, "debug flag array must contain at most one value"
	}
	if len(values) == 0 {
		return "", status, ""
	}
	if !valid_debug_flag(values[0]) {
		return "", status, "debug flag must be -v, -vv, or -vvv"
	}
	return strings.clone(values[0]), status, ""
}

resolve_local_path :: proc(directory, path: string) -> string {
	if filepath.is_abs(path) {
		return strings.clone(path)
	}
	joined, _ := filepath.join([]string{directory, path})
	return joined
}

parse_config :: proc(text, path, directory: string) -> (Config, Config_Error, bool) {
	allocator := context.allocator
	config := Config{
		path = strings.clone(path),
		directory = strings.clone(directory),
	}
	document, parse_problem, parsed := config_toml.parse(text, path, allocator)
	defer config_toml.destroy(&document)
	defer config_toml.destroy_parse_error(&parse_problem)
	if !parsed {
		return config, config_error(
			path,
			config_toml.parse_error_line(&parse_problem),
			config_toml.parse_error_message(&parse_problem),
		), false
	}

	tables := []struct {
		path:               []string,
		allowed:            []string,
		required:           bool,
		missing_message:    string,
		wrong_type_message: string,
		unknown_message:    string,
	}{
		{nil, ROOT_KEYS[:], true, "", "configuration root must be a table", "unknown root key or table"},
		{[]string{"peer"}, PEER_KEYS[:], true, "missing [peer]", "peer must be a table", "unknown key in [peer]"},
		{[]string{"tools"}, TOOLS_KEYS[:], true, "missing [tools]", "tools must be a table", "unknown key in [tools]"},
		{[]string{"debug"}, DEBUG_KEYS[:], false, "", "debug must be a table", "unknown key in [debug]"},
	}
	debug_table_status := config_toml.Lookup_Status.Missing
	for table, i in tables {
		status, problem := validate_table(
			&document,
			table.path,
			table.allowed,
			table.required,
			table.missing_message,
			table.wrong_type_message,
			table.unknown_message,
			allocator,
		)
		if i == 3 {
			debug_table_status = status
		}
		if len(problem) > 0 {
			return config, config_error(path, 0, problem), false
		}
	}

	problem: string
	config.local_mailbox, problem = required_string(
		&document,
		[]string{"local_mailbox"},
		"missing local_mailbox",
		"local_mailbox must be a string",
		allocator,
	)
	if len(problem) > 0 {
		return config, config_error(path, 0, problem), false
	}
	config.peer_path, problem = required_string(
		&document,
		[]string{"peer", "path"},
		"missing peer.path",
		"peer.path must be a string",
		allocator,
	)
	if len(problem) > 0 {
		return config, config_error(path, 0, problem), false
	}
	config.rsync, problem = required_string(
		&document,
		[]string{"tools", "rsync"},
		"missing tools.rsync",
		"tools.rsync must be a string",
		allocator,
	)
	if len(problem) > 0 {
		return config, config_error(path, 0, problem), false
	}

	peer_ssh_status: config_toml.Lookup_Status
	config.peer_ssh, peer_ssh_status, problem = optional_string(
		&document,
		[]string{"peer", "ssh"},
		"peer.ssh must be a string",
		allocator,
	)
	if len(problem) > 0 {
		return config, config_error(path, 0, problem), false
	}
	ssh_status: config_toml.Lookup_Status
	config.ssh, ssh_status, problem = optional_string(
		&document,
		[]string{"tools", "ssh"},
		"tools.ssh must be a string",
		allocator,
	)
	if len(problem) > 0 {
		return config, config_error(path, 0, problem), false
	}

	rsync_debug_status := config_toml.Lookup_Status.Missing
	ssh_debug_status := config_toml.Lookup_Status.Missing
	if debug_table_status == .Found {
		config.rsync_debug_flag, rsync_debug_status, problem = debug_flag(
			&document,
			"rsync_debug_flags",
			"debug.rsync_debug_flags must be an array of strings",
			allocator,
		)
		if len(problem) > 0 {
			return config, config_error(path, 0, problem), false
		}
		config.ssh_debug_flag, ssh_debug_status, problem = debug_flag(
			&document,
			"ssh_debug_flags",
			"debug.ssh_debug_flags must be an array of strings",
			allocator,
		)
		if len(problem) > 0 {
			return config, config_error(path, 0, problem), false
		}
	}

	if len(config.local_mailbox) == 0 || len(config.peer_path) == 0 || len(config.rsync) == 0 {
		return config, config_error(path, 0, "required paths must not be empty"), false
	}
	if peer_ssh_status == .Found && len(config.peer_ssh) == 0 ||
	   ssh_status == .Found && len(config.ssh) == 0 {
		return config, config_error(path, 0, "SSH values must not be empty"), false
	}
	if !filepath.is_abs(config.rsync) || len(config.ssh) > 0 && !filepath.is_abs(config.ssh) {
		return config, config_error(path, 0, "tool paths must be absolute"), false
	}
	if (len(config.peer_ssh) > 0) != (len(config.ssh) > 0) {
		return config, config_error(path, 0, "SSH peer requires tools.ssh; local peer must omit it"), false
	}
	if len(config.peer_ssh) == 0 && ssh_debug_status == .Found {
		return config, config_error(path, 0, "local peer must omit ssh_debug_flags"), false
	}
	if rsync_debug_status == .Missing {
		config.rsync_debug_flag = strings.clone("-v")
	}
	if len(config.peer_ssh) > 0 && ssh_debug_status == .Missing {
		config.ssh_debug_flag = strings.clone("-v")
	}

	resolved_mailbox := resolve_local_path(directory, config.local_mailbox)
	delete(config.local_mailbox)
	config.local_mailbox = resolved_mailbox
	if len(config.peer_ssh) == 0 {
		resolved_peer := resolve_local_path(directory, config.peer_path)
		delete(config.peer_path)
		config.peer_path = resolved_peer
	}
	return config, Config_Error{}, true
}

destroy_config :: proc(config: ^Config) {
	values := []string{
		config.path,
		config.directory,
		config.local_mailbox,
		config.peer_path,
		config.peer_ssh,
		config.rsync,
		config.ssh,
		config.rsync_debug_flag,
		config.ssh_debug_flag,
	}
	for value in values {
		if len(value) > 0 {
			delete(value)
		}
	}
	config^ = {}
}

load_config :: proc(selected_path: string) -> (Config, Config_Error, bool) {
	absolute_path, path_error := os.get_absolute_path(selected_path, context.allocator)
	if path_error != nil {
		return Config{}, config_error(selected_path, 0, "cannot resolve configuration path"), false
	}
	defer delete(absolute_path)

	contents, read_error := os.read_entire_file(absolute_path, context.allocator)
	if read_error != nil {
		return Config{}, config_error(absolute_path, 0, "cannot read configuration"), false
	}
	defer delete(contents)

	directory := filepath.dir(absolute_path)
	return parse_config(string(contents), absolute_path, directory)
}
// END org:block config-schema-and-resolution
