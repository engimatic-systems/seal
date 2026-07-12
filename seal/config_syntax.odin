// BEGIN org:block config-syntax-result-types
package main

Config_Syntax_Kind :: enum {
	Invalid,
	Blank,
	Table,
	Assignment,
}

Config_Syntax_Line :: struct {
	kind:  Config_Syntax_Kind,
	key:   string,
	value: string,
}
// END org:block config-syntax-result-types
// BEGIN org:block config-syntax-predicate-helpers
is_horizontal_space :: proc(byte_value: byte) -> bool {
	return byte_value == ' ' || byte_value == '\t'
}

trim_horizontal_space :: proc(input: string) -> string {
	start := 0
	for start < len(input) && is_horizontal_space(input[start]) {
		start += 1
	}
	end := len(input)
	for end > start && is_horizontal_space(input[end - 1]) {
		end -= 1
	}
	return input[start:end]
}

is_ascii_alpha :: proc(byte_value: byte) -> bool {
	return byte_value >= 'A' && byte_value <= 'Z' ||
		byte_value >= 'a' && byte_value <= 'z'
}

is_key_byte :: proc(byte_value: byte) -> bool {
	return is_ascii_alpha(byte_value) ||
		byte_value >= '0' && byte_value <= '9' ||
		byte_value == '_'
}

valid_config_key :: proc(input: string) -> bool {
	if len(input) == 0 || !is_ascii_alpha(input[0]) {
		return false
	}
	for byte_value in transmute([]byte)input[1:] {
		if !is_key_byte(byte_value) {
			return false
		}
	}
	return true
}
// END org:block config-syntax-predicate-helpers
// BEGIN org:block config-syntax-complete-line-parser
parse_config_syntax_line :: proc(input: string) -> Config_Syntax_Line {
	line := trim_horizontal_space(input)
	if len(line) == 0 {
		return Config_Syntax_Line{kind = .Blank}
	}
	if line[0] == '[' {
		if len(line) < 3 || line[len(line) - 1] != ']' {
			return Config_Syntax_Line{kind = .Invalid}
		}
		key := line[1:len(line) - 1]
		if !valid_config_key(key) {
			return Config_Syntax_Line{kind = .Invalid}
		}
		return Config_Syntax_Line{kind = .Table, key = key}
	}

	i := 0
	if !is_ascii_alpha(line[i]) {
		return Config_Syntax_Line{kind = .Invalid}
	}
	for i < len(line) && is_key_byte(line[i]) {
		i += 1
	}
	key := line[:i]
	for i < len(line) && is_horizontal_space(line[i]) {
		i += 1
	}
	if i >= len(line) || line[i] != '=' {
		return Config_Syntax_Line{kind = .Invalid}
	}
	i += 1
	for i < len(line) && is_horizontal_space(line[i]) {
		i += 1
	}
	if i >= len(line) || line[i] != '"' {
		return Config_Syntax_Line{kind = .Invalid}
	}
	i += 1
	value_start := i
	for i < len(line) {
		byte_value := line[i]
		if byte_value == '"' {
			if i + 1 != len(line) {
				return Config_Syntax_Line{kind = .Invalid}
			}
			return Config_Syntax_Line{
				kind = .Assignment,
				key = key,
				value = line[value_start:i],
			}
		}
		if byte_value < 0x20 || byte_value > 0x7e || byte_value == '\\' {
			return Config_Syntax_Line{kind = .Invalid}
		}
		i += 1
	}
	return Config_Syntax_Line{kind = .Invalid}
}
// END org:block config-syntax-complete-line-parser
