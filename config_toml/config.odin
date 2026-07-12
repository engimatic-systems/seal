// BEGIN org:block config-toml-package
package config_toml

import "core:strings"
import toml "../vendor/toml"

@private
Backend_State :: struct {
	table: ^toml.Table,
}

// Document owns private backend state and its parser tree.
Document :: struct {
	state: ^Backend_State,
}

Parse_Error :: struct {
	line:    int,
	message: string,
}

Lookup_Status :: enum {
	Found,
	Missing,
	Wrong_Type,
}

@private
backend_table :: proc(document: ^Document) -> ^toml.Table {
	if document.state == nil {
		return nil
	}
	return document.state.table
}

parse :: proc(text, source: string) -> (Document, Parse_Error, bool) {
	table, upstream_error := toml.parse(text, source)
	if upstream_error.type == .None {
		state := new(Backend_State)
		state.table = table
		return Document{state = state}, Parse_Error{}, true
	}
	defer toml.delete_error(&upstream_error)
	formatted, _ := toml.format_error(&upstream_error)
	message := formatted
	if len(formatted) >= len(source) {
		separator := strings.index_byte(formatted[len(source):], ' ')
		if separator >= 0 {
			message = formatted[len(source) + separator + 1:]
		}
	}
	return Document{}, Parse_Error{
		line = upstream_error.line,
		message = strings.clone(strings.trim_space(message)),
	}, false
}

destroy :: proc(document: ^Document) {
	if document.state != nil {
		_ = toml.deep_delete(backend_table(document))
		free(document.state)
	}
	document^ = {}
}

destroy_parse_error :: proc(problem: ^Parse_Error) {
	if len(problem.message) > 0 {
		delete(problem.message)
	}
	problem^ = {}
}

@private
lookup :: proc(document: ^Document, path: []string) -> (toml.Type, Lookup_Status) {
	table := backend_table(document)
	if table == nil || len(path) == 0 {
		return nil, .Missing
	}
	for component in path[:len(path) - 1] {
		value, present := table[component]
		if !present {
			return nil, .Missing
		}
		next, is_table := value.(^toml.Table)
		if !is_table {
			return nil, .Wrong_Type
		}
		table = next
	}
	value, present := table[path[len(path) - 1]]
	if !present {
		return nil, .Missing
	}
	return value, .Found
}

@private
table_at :: proc(document: ^Document, path: []string) -> (^toml.Table, Lookup_Status) {
	if len(path) == 0 {
		table := backend_table(document)
		if table == nil {
			return nil, .Missing
		}
		return table, .Found
	}
	value, status := lookup(document, path)
	if status != .Found {
		return nil, status
	}
	table, ok := value.(^toml.Table)
	if !ok {
		return nil, .Wrong_Type
	}
	return table, .Found
}

table_keys :: proc(document: ^Document, path: ..string) -> ([]string, Lookup_Status) {
	table, status := table_at(document, path)
	if status != .Found {
		return nil, status
	}
	keys := make([]string, len(table))
	i := 0
	for key in table {
		keys[i] = strings.clone(key)
		i += 1
	}
	return keys, .Found
}

get_string :: proc(document: ^Document, path: ..string) -> (string, Lookup_Status) {
	value, status := lookup(document, path)
	if status != .Found {
		return "", status
	}
	result, ok := value.(string)
	if !ok {
		return "", .Wrong_Type
	}
	return strings.clone(result), .Found
}

get_string_array :: proc(document: ^Document, path: ..string) -> ([]string, Lookup_Status) {
	value, status := lookup(document, path)
	if status != .Found {
		return nil, status
	}
	list, ok := value.(^toml.List)
	if !ok {
		return nil, .Wrong_Type
	}
	result := make([]string, len(list))
	for item, i in list {
		string_item, is_string := item.(string)
		if !is_string {
			destroy_string_items(result[:i])
			delete(result)
			return nil, .Wrong_Type
		}
		result[i] = strings.clone(string_item)
	}
	return result, .Found
}

@private
destroy_string_items :: proc(values: []string) {
	for value in values {
		delete(value)
	}
}

destroy_string_array :: proc(values: []string) {
	destroy_string_items(values)
	delete(values)
}
// END org:block config-toml-package
