// BEGIN org:block config-toml-tests
package config_toml

import "core:mem"
import "core:strings"
import "core:testing"

@(test)
test_valid_queries_and_enumeration_are_owned :: proc(t: ^testing.T) {
	allocator := context.allocator
	document, problem, ok := parse(`name = "seal"
[debug]
flags = ["-v"]
`, "valid.toml", allocator)
	defer destroy(&document)
	defer destroy_parse_error(&problem)
	testing.expect(t, ok, parse_error_message(&problem))

	keys, status := table_keys(&document, nil, allocator)
	defer destroy_string_array(keys, allocator)
	testing.expect_value(t, status, Lookup_Status.Found)
	testing.expect_value(t, len(keys), 2)

	name, name_status := get_string(&document, []string{"name"}, allocator)
	defer delete(name, allocator)
	testing.expect_value(t, name_status, Lookup_Status.Found)
	testing.expect_value(t, name, "seal")

	flags, flags_status := get_string_array(
		&document,
		[]string{"debug", "flags"},
		allocator,
	)
	defer destroy_string_array(flags, allocator)
	testing.expect_value(t, flags_status, Lookup_Status.Found)
	testing.expect_value(t, flags[0], "-v")

	destroy(&document)
	destroy(&document)
	testing.expect_value(t, name, "seal")
	testing.expect_value(t, flags[0], "-v")
	found_name, found_debug := false, false
	for key in keys {
		found_name = found_name || key == "name"
		found_debug = found_debug || key == "debug"
	}
	testing.expect(t, found_name)
	testing.expect(t, found_debug)
}

@(test)
test_queries_distinguish_missing_and_wrong_type :: proc(t: ^testing.T) {
	allocator := context.allocator
	document, problem, ok := parse(`name = "seal"
count = 1
`, "types.toml", allocator)
	defer destroy(&document)
	defer destroy_parse_error(&problem)
	testing.expect(t, ok, parse_error_message(&problem))

	_, missing := get_string(&document, []string{"absent"}, allocator)
	_, wrong := get_string(&document, []string{"count"}, allocator)
	_, through_scalar := get_string(
		&document,
		[]string{"name", "child"},
		allocator,
	)
	testing.expect_value(t, missing, Lookup_Status.Missing)
	testing.expect_value(t, wrong, Lookup_Status.Wrong_Type)
	testing.expect_value(t, through_scalar, Lookup_Status.Wrong_Type)
}

@(test)
test_allocator_switch_does_not_change_destruction :: proc(t: ^testing.T) {
	base_allocator := context.allocator
	allocator_a_state, allocator_b_state: mem.Tracking_Allocator
	mem.tracking_allocator_init(&allocator_a_state, base_allocator, base_allocator)
	mem.tracking_allocator_init(&allocator_b_state, base_allocator, base_allocator)
	defer {
		context.allocator = base_allocator
		mem.tracking_allocator_destroy(&allocator_b_state)
		mem.tracking_allocator_destroy(&allocator_a_state)
	}
	allocator_a := mem.tracking_allocator(&allocator_a_state)
	allocator_b := mem.tracking_allocator(&allocator_b_state)

	document, problem, ok := parse(`name = "seal"
[debug]
flags = ["-v"]
`, "allocator.toml", allocator_a)
	testing.expect(t, ok, parse_error_message(&problem))
	keys, _ := table_keys(&document, nil, allocator_a)
	name, _ := get_string(&document, []string{"name"}, allocator_a)
	flags, _ := get_string_array(&document, []string{"debug", "flags"}, allocator_a)

	context.allocator = allocator_b
	destroy(&document)
	destroy(&document)
	destroy_parse_error(&problem)
	destroy_string_array(keys, allocator_a)
	delete(name, allocator_a)
	destroy_string_array(flags, allocator_a)

	broken_document, broken_problem, parsed := parse(
		"name = [\n",
		"broken.toml",
		allocator_a,
	)
	testing.expect(t, !parsed)
	testing.expect(t, parse_error_line(&broken_problem) > 0)
	testing.expect(t, !strings.contains(
		parse_error_message(&broken_problem),
		"broken.toml",
	))
	context.allocator = allocator_b
	destroy(&broken_document)
	destroy_parse_error(&broken_problem)
	destroy_parse_error(&broken_problem)

	duplicate_document, duplicate_problem, duplicate_ok := parse(
		"a = 1\na = 2\n",
		"duplicate.toml",
		allocator_a,
	)
	testing.expect(t, !duplicate_ok)
	context.allocator = allocator_b
	destroy(&duplicate_document)
	destroy_parse_error(&duplicate_problem)

	testing.expect_value(t, len(allocator_a_state.bad_free_array), 0)
	testing.expect_value(t, len(allocator_a_state.allocation_map), 0)
}
// END org:block config-toml-tests
