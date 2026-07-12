// BEGIN org:block config-toml-package
package config_toml

import "base:runtime"
import "core:mem"
import "core:strings"
import toml "../vendor/toml"

@private
Backend_State :: struct {
	table:            ^toml.Table,
	arena:            mem.Dynamic_Arena,
	parent_allocator: runtime.Allocator,
}

@private
Error_State :: struct {
	line:      int,
	message:   string,
	allocator: runtime.Allocator,
}

// Document is a single-owner handle. Do not copy it after successful parse.
// Pass its address to queries and destroy exactly once; destroy zeros the handle.
Document :: distinct rawptr

// Parse_Error is a single-owner error handle returned by parse. Do not copy it.
Parse_Error :: distinct rawptr

Lookup_Status :: enum {
	Found,
	Missing,
	Wrong_Type,
}

@private
document_state :: proc(document: ^Document) -> ^Backend_State {
	if document == nil || document^ == Document(nil) {
		return nil
	}
	return transmute(^Backend_State)document^
}

@private
error_state :: proc(problem: ^Parse_Error) -> ^Error_State {
	if problem == nil || problem^ == Parse_Error(nil) {
		return nil
	}
	return transmute(^Error_State)problem^
}

parse :: proc(
	text, source: string,
	allocator := context.allocator,
) -> (Document, Parse_Error, bool) {
	state := new(Backend_State, allocator)
	state.parent_allocator = allocator
	mem.dynamic_arena_init(&state.arena, allocator, allocator)
	arena_allocator := mem.dynamic_arena_allocator(&state.arena)
	table, upstream_error := toml.parse(text, source, arena_allocator)
	if upstream_error.type == .None {
		state.table = table
		return Document(rawptr(state)), Parse_Error(nil), true
	}
	context.allocator = arena_allocator
	formatted, _ := toml.format_error(&upstream_error, arena_allocator)
	message := formatted
	if len(formatted) >= len(source) {
		separator := strings.index_byte(formatted[len(source):], ' ')
		if separator >= 0 {
			message = formatted[len(source) + separator + 1:]
		}
	}
	problem_state := new(Error_State, allocator)
	problem_state.line = upstream_error.line
	problem_state.message = strings.clone(strings.trim_space(message), allocator)
	problem_state.allocator = allocator
	toml.delete_error(&upstream_error)
	mem.dynamic_arena_destroy(&state.arena)
	free(state, allocator)
	return Document(nil), Parse_Error(rawptr(problem_state)), false
}

destroy :: proc(document: ^Document) {
	state := document_state(document)
	if state == nil {
		return
	}
	allocator := state.parent_allocator
	mem.dynamic_arena_destroy(&state.arena)
	free(state, allocator)
	document^ = Document(nil)
}

destroy_parse_error :: proc(problem: ^Parse_Error) {
	state := error_state(problem)
	if state == nil {
		return
	}
	allocator := state.allocator
	delete(state.message, allocator)
	free(state, allocator)
	problem^ = Parse_Error(nil)
}

parse_error_line :: proc(problem: ^Parse_Error) -> int {
	state := error_state(problem)
	return state.line if state != nil else 0
}

// parse_error_message borrows storage owned by problem until destroy_parse_error.
parse_error_message :: proc(problem: ^Parse_Error) -> string {
	state := error_state(problem)
	return state.message if state != nil else ""
}

@private
backend_table :: proc(document: ^Document) -> ^toml.Table {
	state := document_state(document)
	return state.table if state != nil else nil
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

// Returned keys and their slice use allocator; destroy with destroy_string_array.
table_keys :: proc(
	document: ^Document,
	path: []string,
	allocator := context.allocator,
) -> ([]string, Lookup_Status) {
	table, status := table_at(document, path)
	if status != .Found {
		return nil, status
	}
	keys := make([]string, len(table), allocator)
	i := 0
	for key in table {
		keys[i] = strings.clone(key, allocator)
		i += 1
	}
	return keys, .Found
}

// Returned string uses allocator and remains valid independently of document.
get_string :: proc(
	document: ^Document,
	path: []string,
	allocator := context.allocator,
) -> (string, Lookup_Status) {
	value, status := lookup(document, path)
	if status != .Found {
		return "", status
	}
	result, ok := value.(string)
	if !ok {
		return "", .Wrong_Type
	}
	return strings.clone(result, allocator), .Found
}

// Returned strings and their slice use allocator; destroy with destroy_string_array.
get_string_array :: proc(
	document: ^Document,
	path: []string,
	allocator := context.allocator,
) -> ([]string, Lookup_Status) {
	value, status := lookup(document, path)
	if status != .Found {
		return nil, status
	}
	list, ok := value.(^toml.List)
	if !ok {
		return nil, .Wrong_Type
	}
	result := make([]string, len(list), allocator)
	for item, i in list {
		string_item, is_string := item.(string)
		if !is_string {
			destroy_string_items(result[:i], allocator)
			delete(result, allocator)
			return nil, .Wrong_Type
		}
		result[i] = strings.clone(string_item, allocator)
	}
	return result, .Found
}

@private
destroy_string_items :: proc(values: []string, allocator: runtime.Allocator) {
	for value in values {
		delete(value, allocator)
	}
}

destroy_string_array :: proc(values: []string, allocator: runtime.Allocator) {
	destroy_string_items(values, allocator)
	delete(values, allocator)
}
// END org:block config-toml-package
