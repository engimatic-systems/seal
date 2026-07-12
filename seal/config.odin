// BEGIN org:block config-package-types
package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

Config :: struct {
	path:               string,
	directory:          string,
	local_mailbox:      string,
	peer_path:          string,
	peer_ssh:           string,
	has_peer_ssh:       bool,
	rsync:              string,
	ssh:                string,
	has_ssh:            bool,
	rsync_debug_flag:   string,
	ssh_debug_flag:     string,
	has_ssh_debug_flag: bool,
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

Config_Seen :: struct {
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
// END org:block config-package-types
// BEGIN org:block config-basic-values
parse_basic_string :: proc(input: string) -> (value, rest, problem: string) {
	if len(input) == 0 || input[0] != '"' {
		return "", "", "expected quoted string"
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	for i := 1; i < len(input); i += 1 {
		byte_value := input[i]
		if byte_value == '"' {
			return strings.clone(strings.to_string(builder)), input[i + 1:], ""
		}
		if byte_value < 0x20 {
			return "", "", "control byte in quoted string"
		}
		if byte_value != '\\' {
			strings.write_byte(&builder, byte_value)
			continue
		}

		i += 1
		if i >= len(input) {
			return "", "", "unterminated escape"
		}
		switch input[i] {
		case '\\':
			strings.write_byte(&builder, '\\')
		case '"':
			strings.write_byte(&builder, '"')
		case 'n':
			strings.write_byte(&builder, '\n')
		case 'r':
			strings.write_byte(&builder, '\r')
		case 't':
			strings.write_byte(&builder, '\t')
		case:
			return "", "", "unsupported string escape"
		}
	}
	return "", "", "unterminated quoted string"
}

trailing_comment_or_empty :: proc(input: string) -> bool {
	rest := strings.trim_space(input)
	return len(rest) == 0 || rest[0] == '#'
}

parse_string_value :: proc(input: string) -> (value, problem: string) {
	rest: string
	value, rest, problem = parse_basic_string(input)
	if len(problem) != 0 {
		return "", problem
	}
	if !trailing_comment_or_empty(rest) {
		delete(value)
		return "", "unexpected syntax after string"
	}
	return value, ""
}

valid_debug_flag :: proc(value: string) -> bool {
	return value == "-v" || value == "-vv" || value == "-vvv"
}

parse_debug_value :: proc(input: string) -> (value, problem: string) {
	if len(input) == 0 || input[0] != '[' {
		return "", "expected debug flag array"
	}
	rest := strings.trim_left_space(input[1:])
	if len(rest) > 0 && rest[0] == ']' {
		if !trailing_comment_or_empty(rest[1:]) {
			return "", "unexpected syntax after debug flag array"
		}
		return "", ""
	}

	suffix: string
	value, suffix, problem = parse_basic_string(rest)
	if len(problem) != 0 {
		return "", problem
	}
	suffix = strings.trim_left_space(suffix)
	if len(suffix) == 0 || suffix[0] != ']' {
		delete(value)
		return "", "debug flag array must contain one value"
	}
	if !trailing_comment_or_empty(suffix[1:]) {
		delete(value)
		return "", "unexpected syntax after debug flag array"
	}
	if !valid_debug_flag(value) {
		delete(value)
		return "", "debug flag must be -v, -vv, or -vvv"
	}
	return value, ""
}
// END org:block config-basic-values
// BEGIN org:block config-line-parser
config_error :: proc(path: string, line: int, message: string) -> Config_Error {
	return Config_Error{path = strings.clone(path), line = line, message = message}
}

destroy_config_error :: proc(problem: ^Config_Error) {
	if len(problem.path) > 0 {
		delete(problem.path)
	}
	problem^ = {}
}

parse_table :: proc(line: string, seen: ^Config_Seen) -> (Config_Table, string) {
	closing := strings.index_byte(line, ']')
	if closing < 0 || !trailing_comment_or_empty(line[closing + 1:]) {
		return .Root, "malformed table header"
	}
	name := line[1:closing]
	switch name {
	case "peer":
		if seen.peer_table {
			return .Root, "duplicate table [peer]"
		}
		seen.peer_table = true
		return .Peer, ""
	case "tools":
		if seen.tools_table {
			return .Root, "duplicate table [tools]"
		}
		seen.tools_table = true
		return .Tools, ""
	case "debug":
		if seen.debug_table {
			return .Root, "duplicate table [debug]"
		}
		seen.debug_table = true
		return .Debug, ""
	case:
		return .Root, "unknown table"
	}
}

assign_string :: proc(destination: ^string, present: ^bool, input: string) -> string {
	if present^ {
		return "duplicate field"
	}
	value, problem := parse_string_value(input)
	if len(problem) != 0 {
		return problem
	}
	destination^ = value
	present^ = true
	return ""
}

assign_debug :: proc(destination: ^string, present: ^bool, input: string) -> string {
	if present^ {
		return "duplicate field"
	}
	value, problem := parse_debug_value(input)
	if len(problem) != 0 {
		return problem
	}
	destination^ = value
	present^ = true
	return ""
}

parse_assignment :: proc(
	config: ^Config,
	seen: ^Config_Seen,
	table: Config_Table,
	line: string,
) -> string {
	equals := strings.index_byte(line, '=')
	if equals < 0 {
		return "expected key = value"
	}
	key := strings.trim_space(line[:equals])
	value := strings.trim_left_space(line[equals + 1:])
	switch table {
	case .Root:
		if key == "local_mailbox" {
			return assign_string(&config.local_mailbox, &seen.local_mailbox, value)
		}
	case .Peer:
		switch key {
		case "path":
			return assign_string(&config.peer_path, &seen.peer_path, value)
		case "ssh":
			problem := assign_string(&config.peer_ssh, &seen.peer_ssh, value)
			config.has_peer_ssh = len(problem) == 0
			return problem
		}
	case .Tools:
		switch key {
		case "rsync":
			return assign_string(&config.rsync, &seen.rsync, value)
		case "ssh":
			problem := assign_string(&config.ssh, &seen.ssh, value)
			config.has_ssh = len(problem) == 0
			return problem
		}
	case .Debug:
		switch key {
		case "rsync_debug_flags":
			return assign_debug(&config.rsync_debug_flag, &seen.rsync_debug_flag, value)
		case "ssh_debug_flags":
			problem := assign_debug(&config.ssh_debug_flag, &seen.ssh_debug_flag, value)
			config.has_ssh_debug_flag = len(problem) == 0
			return problem
		}
	}
	return "unknown key in current table"
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
	seen := Config_Seen{}
	table := Config_Table.Root
	if !utf8.valid_string(text) {
		return config, config_error(path, 1, "configuration is not valid UTF-8"), false
	}

	remaining := text
	line_number := 0
	for {
		line, ok := strings.split_lines_iterator(&remaining)
		if !ok {
			break
		}
		line_number += 1
		line = strings.trim_space(line)
		if len(line) == 0 || line[0] == '#' {
			continue
		}
		if line[0] == '[' {
			problem: string
			table, problem = parse_table(line, &seen)
			if len(problem) != 0 {
				return config, config_error(path, line_number, problem), false
			}
			continue
		}
		problem := parse_assignment(&config, &seen, table, line)
		if len(problem) != 0 {
			return config, config_error(path, line_number, problem), false
		}
	}

	if !seen.local_mailbox {
		return config, config_error(path, line_number + 1, "missing local_mailbox"), false
	}
	if !seen.peer_path {
		return config, config_error(path, line_number + 1, "missing peer.path"), false
	}
	if !seen.rsync {
		return config, config_error(path, line_number + 1, "missing tools.rsync"), false
	}
	if len(config.local_mailbox) == 0 || len(config.peer_path) == 0 || len(config.rsync) == 0 {
		return config, config_error(path, line_number + 1, "required paths must not be empty"), false
	}
	if (config.has_peer_ssh && len(config.peer_ssh) == 0) || (config.has_ssh && len(config.ssh) == 0) {
		return config, config_error(path, line_number + 1, "SSH values must not be empty"), false
	}
	if !filepath.is_abs(config.rsync) || config.has_ssh && !filepath.is_abs(config.ssh) {
		return config, config_error(path, line_number + 1, "tool paths must be absolute"), false
	}
	if config.has_peer_ssh != config.has_ssh {
		return config, config_error(path, line_number + 1, "SSH peer requires tools.ssh; local peer must omit it"), false
	}
	if !config.has_peer_ssh && config.has_ssh_debug_flag {
		return config, config_error(path, line_number + 1, "local peer must omit ssh_debug_flags"), false
	}
	if !seen.rsync_debug_flag {
		config.rsync_debug_flag = strings.clone("-v")
	}
	if config.has_peer_ssh && !seen.ssh_debug_flag {
		config.ssh_debug_flag = strings.clone("-v")
		config.has_ssh_debug_flag = true
	}

	resolved_mailbox := resolve_local_path(directory, config.local_mailbox)
	delete(config.local_mailbox)
	config.local_mailbox = resolved_mailbox
	if !config.has_peer_ssh {
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
// END org:block config-line-parser
// BEGIN org:block config-file-loading
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
// END org:block config-file-loading
