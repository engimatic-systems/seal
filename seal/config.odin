// BEGIN org:block config-schema
package main

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

Config_Table :: enum {
	Root,
	Peer,
	Tools,
	Debug,
}

Config_State :: struct {
	peer_table:       bool,
	tools_table:      bool,
	debug_table:      bool,
	local_mailbox:    bool,
	peer_path:        bool,
	peer_ssh:         bool,
	rsync:            bool,
	ssh:              bool,
	rsync_debug_flag: bool,
	ssh_debug_flag:   bool,
}

config_error :: proc(path: string, line: int, message: string) -> Config_Error {
	return Config_Error{path = strings.clone(path), line = line, message = message}
}

destroy_config_error :: proc(problem: ^Config_Error) {
	if len(problem.path) > 0 {
		delete(problem.path)
	}
	problem^ = {}
}

select_config_table :: proc(name: string, state: ^Config_State) -> (Config_Table, string) {
	switch name {
	case "peer":
		if state.peer_table {
			return .Root, "duplicate table [peer]"
		}
		state.peer_table = true
		return .Peer, ""
	case "tools":
		if state.tools_table {
			return .Root, "duplicate table [tools]"
		}
		state.tools_table = true
		return .Tools, ""
	case "debug":
		if state.debug_table {
			return .Root, "duplicate table [debug]"
		}
		state.debug_table = true
		return .Debug, ""
	case:
		return .Root, "unknown table"
	}
}

assign_config_value :: proc(destination: ^string, present: ^bool, value: string) -> string {
	if present^ {
		return "duplicate field"
	}
	destination^ = strings.clone(value)
	present^ = true
	return ""
}

assign_config_field :: proc(
	config: ^Config,
	state: ^Config_State,
	table: Config_Table,
	key, value: string,
) -> string {
	switch table {
	case .Root:
		if key == "local_mailbox" {
			return assign_config_value(&config.local_mailbox, &state.local_mailbox, value)
		}
	case .Peer:
		switch key {
		case "path":
			return assign_config_value(&config.peer_path, &state.peer_path, value)
		case "ssh":
			return assign_config_value(&config.peer_ssh, &state.peer_ssh, value)
		}
	case .Tools:
		switch key {
		case "rsync":
			return assign_config_value(&config.rsync, &state.rsync, value)
		case "ssh":
			return assign_config_value(&config.ssh, &state.ssh, value)
		}
	case .Debug:
		switch key {
		case "rsync_debug_flags":
			return assign_config_value(
				&config.rsync_debug_flag,
				&state.rsync_debug_flag,
				value,
			)
		case "ssh_debug_flags":
			return assign_config_value(
				&config.ssh_debug_flag,
				&state.ssh_debug_flag,
				value,
			)
		}
	}
	return "unknown key in current table"
}

valid_debug_flag :: proc(value: string) -> bool {
	return len(value) == 0 || value == "-v" || value == "-vv" || value == "-vvv"
}

resolve_local_path :: proc(directory, path: string) -> string {
	if filepath.is_abs(path) {
		return strings.clone(path)
	}
	joined, _ := filepath.join([]string{directory, path})
	return joined
}

parse_config :: proc(text, path, directory: string) -> (Config, Config_Error, bool) {
	config := Config{
		path = strings.clone(path),
		directory = strings.clone(directory),
	}
	state := Config_State{}
	table := Config_Table.Root
	remaining := text
	line_number := 0
	for {
		line, ok := strings.split_lines_iterator(&remaining)
		if !ok {
			break
		}
		line_number += 1
		parsed := parse_config_syntax_line(line)
		switch parsed.kind {
		case .Blank:
			continue
		case .Table:
			problem: string
			table, problem = select_config_table(parsed.key, &state)
			if len(problem) > 0 {
				return config, config_error(path, line_number, problem), false
			}
		case .Assignment:
			problem := assign_config_field(&config, &state, table, parsed.key, parsed.value)
			if len(problem) > 0 {
				return config, config_error(path, line_number, problem), false
			}
		case .Invalid:
			return config, config_error(path, line_number, "invalid configuration syntax"), false
		}
	}

	if !state.local_mailbox {
		return config, config_error(path, line_number + 1, "missing local_mailbox"), false
	}
	if !state.peer_path {
		return config, config_error(path, line_number + 1, "missing peer.path"), false
	}
	if !state.rsync {
		return config, config_error(path, line_number + 1, "missing tools.rsync"), false
	}
	if len(config.local_mailbox) == 0 || len(config.peer_path) == 0 || len(config.rsync) == 0 {
		return config, config_error(path, line_number + 1, "required paths must not be empty"), false
	}
	if state.peer_ssh && len(config.peer_ssh) == 0 || state.ssh && len(config.ssh) == 0 {
		return config, config_error(path, line_number + 1, "SSH values must not be empty"), false
	}
	if !filepath.is_abs(config.rsync) || state.ssh && !filepath.is_abs(config.ssh) {
		return config, config_error(path, line_number + 1, "tool paths must be absolute"), false
	}
	if state.peer_ssh != state.ssh {
		return config, config_error(path, line_number + 1, "SSH peer requires tools.ssh; local peer must omit it"), false
	}
	if !state.peer_ssh && state.ssh_debug_flag {
		return config, config_error(path, line_number + 1, "local peer must omit ssh_debug_flags"), false
	}
	if state.rsync_debug_flag && !valid_debug_flag(config.rsync_debug_flag) ||
	   state.ssh_debug_flag && !valid_debug_flag(config.ssh_debug_flag) {
		return config, config_error(path, line_number + 1, "debug flag must be empty, -v, -vv, or -vvv"), false
	}
	if !state.rsync_debug_flag {
		config.rsync_debug_flag = strings.clone("-v")
	}
	if state.peer_ssh && !state.ssh_debug_flag {
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
// END org:block config-schema
