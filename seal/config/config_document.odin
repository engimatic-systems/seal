// BEGIN org:block config-document-parse-state
package config

import "core:strings"

@(private)
Config_Table :: enum {
	Root,
	Peer,
	Tools,
	Debug,
}

@(private)
Config_State :: struct {
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
@(private)
select_config_table :: proc(name: string) -> (Config_Table, string) {
	switch name {
	case "peer":
		return .Peer, ""
	case "tools":
		return .Tools, ""
	case "debug":
		return .Debug, ""
	case:
		return .Root, "unknown table"
	}
}
// END org:block config-document-table-structure
// BEGIN org:block config-document-field-structure
@(private)
assign_config_value :: proc(destination: ^string, present: ^bool, value: string) -> string {
	replacement := strings.clone(value)
	if len(destination^) > 0 {
		delete(destination^)
	}
	destination^ = replacement
	present^ = true
	return ""
}

@(private)
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
@(private)
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
@(private)
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
			table, problem = select_config_table(parsed.key)
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
