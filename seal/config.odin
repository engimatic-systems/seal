// BEGIN org:block config-model-result-error-types
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
// END org:block config-model-result-error-types
// BEGIN org:block config-model-error-lifetime
config_error :: proc(path: string, line: int, message: string) -> Config_Error {
	return Config_Error{path = strings.clone(path), line = line, message = message}
}

destroy_config_error :: proc(problem: ^Config_Error) {
	if len(problem.path) > 0 {
		delete(problem.path)
	}
	problem^ = {}
}
// END org:block config-model-error-lifetime
// BEGIN org:block config-document-parse-state
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
// END org:block config-document-parse-state
// BEGIN org:block config-document-table-structure
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
// END org:block config-document-table-structure
// BEGIN org:block config-document-field-structure
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
// END org:block config-document-field-structure
// BEGIN org:block config-document-required-fields
validate_required_fields :: proc(state: ^Config_State) -> string {
	if !state.local_mailbox {
		return "missing local_mailbox"
	}
	if !state.peer_path {
		return "missing peer.path"
	}
	if !state.rsync {
		return "missing tools.rsync"
	}
	return ""
}
// END org:block config-document-required-fields
// BEGIN org:block config-document-parser
parse_config_document :: proc(
	text: string,
	config: ^Config,
	state: ^Config_State,
) -> (line_number: int, problem: string) {
	table := Config_Table.Root
	remaining := text
	line_number = 0
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
			table, problem = select_config_table(parsed.key, state)
			if len(problem) > 0 {
				return line_number, problem
			}
		case .Assignment:
			problem = assign_config_field(config, state, table, parsed.key, parsed.value)
			if len(problem) > 0 {
				return line_number, problem
			}
		case .Invalid:
			return line_number, "invalid configuration syntax"
		}
	}
	return line_number, ""
}
// END org:block config-document-parser
// BEGIN org:block config-semantics-helpers
valid_debug_flag :: proc(value: string) -> bool {
	return len(value) == 0 || value == "-v" || value == "-vv" || value == "-vvv"
}
// END org:block config-semantics-helpers
// BEGIN org:block config-semantics-static-validation
validate_config_semantics :: proc(config: ^Config, state: ^Config_State) -> string {
	if len(config.local_mailbox) == 0 || len(config.peer_path) == 0 || len(config.rsync) == 0 {
		return "required paths must not be empty"
	}
	if state.peer_ssh && len(config.peer_ssh) == 0 || state.ssh && len(config.ssh) == 0 {
		return "SSH values must not be empty"
	}
	if !filepath.is_abs(config.rsync) || state.ssh && !filepath.is_abs(config.ssh) {
		return "tool paths must be absolute"
	}
	if state.peer_ssh != state.ssh {
		return "SSH peer requires tools.ssh; local peer must omit it"
	}
	if !state.peer_ssh && state.ssh_debug_flag {
		return "local peer must omit ssh_debug_flags"
	}
	if state.rsync_debug_flag && !valid_debug_flag(config.rsync_debug_flag) ||
	   state.ssh_debug_flag && !valid_debug_flag(config.ssh_debug_flag) {
		return "debug flag must be empty, -v, -vv, or -vvv"
	}
	return ""
}
// END org:block config-semantics-static-validation
// BEGIN org:block config-semantics-defaults
apply_config_defaults :: proc(config: ^Config, state: ^Config_State) {
	if !state.rsync_debug_flag {
		config.rsync_debug_flag = strings.clone("-v")
	}
	if state.peer_ssh && !state.ssh_debug_flag {
		config.ssh_debug_flag = strings.clone("-v")
	}
}
// END org:block config-semantics-defaults
// BEGIN org:block config-semantics-path-interpretation
resolve_local_path :: proc(directory, path: string) -> string {
	if filepath.is_abs(path) {
		return strings.clone(path)
	}
	joined, _ := filepath.join([]string{directory, path})
	return joined
}

resolve_config_paths :: proc(config: ^Config) {
	resolved_mailbox := resolve_local_path(config.directory, config.local_mailbox)
	delete(config.local_mailbox)
	config.local_mailbox = resolved_mailbox
	if len(config.peer_ssh) == 0 {
		resolved_peer := resolve_local_path(config.directory, config.peer_path)
		delete(config.peer_path)
		config.peer_path = resolved_peer
	}
}
// END org:block config-semantics-path-interpretation
// BEGIN org:block config-assembly-parse-interpret
parse_config :: proc(text, path, directory: string) -> (Config, Config_Error, bool) {
	config := Config{
		path = strings.clone(path),
		directory = strings.clone(directory),
	}
	state := Config_State{}
	line_number, problem := parse_config_document(text, &config, &state)
	if len(problem) > 0 {
		return config, config_error(path, line_number, problem), false
	}

	problem = validate_required_fields(&state)
	if len(problem) > 0 {
		return config, config_error(path, line_number + 1, problem), false
	}
	problem = validate_config_semantics(&config, &state)
	if len(problem) > 0 {
		return config, config_error(path, line_number + 1, problem), false
	}
	apply_config_defaults(&config, &state)
	resolve_config_paths(&config)
	return config, Config_Error{}, true
}
// END org:block config-assembly-parse-interpret
// BEGIN org:block config-lifetime-destruction
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
// END org:block config-lifetime-destruction
// BEGIN org:block config-lifetime-file-loading
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
// END org:block config-lifetime-file-loading
