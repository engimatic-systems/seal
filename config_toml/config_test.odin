// BEGIN org:block config-toml-tests
package config_toml

import "core:strings"
import "core:testing"

@(test)
test_valid_queries_and_enumeration_are_owned :: proc(t: ^testing.T) {
	document, problem, ok := parse(`name = "seal"
[debug]
flags = ["-v"]
`, "valid.toml")
	defer destroy(&document)
	defer destroy_parse_error(&problem)
	testing.expect(t, ok, problem.message)

	keys, status := table_keys(&document)
	defer destroy_string_array(keys)
	testing.expect_value(t, status, Lookup_Status.Found)
	testing.expect_value(t, len(keys), 2)

	name, name_status := get_string(&document, "name")
	defer delete(name)
	testing.expect_value(t, name_status, Lookup_Status.Found)
	testing.expect_value(t, name, "seal")

	flags, flags_status := get_string_array(&document, "debug", "flags")
	defer destroy_string_array(flags)
	testing.expect_value(t, flags_status, Lookup_Status.Found)
	testing.expect_value(t, flags[0], "-v")

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
	document, problem, ok := parse(`name = "seal"
count = 1
`, "types.toml")
	defer destroy(&document)
	defer destroy_parse_error(&problem)
	testing.expect(t, ok, problem.message)

	_, missing := get_string(&document, "absent")
	_, wrong := get_string(&document, "count")
	_, through_scalar := get_string(&document, "name", "child")
	testing.expect_value(t, missing, Lookup_Status.Missing)
	testing.expect_value(t, wrong, Lookup_Status.Wrong_Type)
	testing.expect_value(t, through_scalar, Lookup_Status.Wrong_Type)
}

@(test)
test_syntax_error_is_normalized_and_owned :: proc(t: ^testing.T) {
	document, problem, ok := parse("name = [\n", "broken.toml")
	defer destroy(&document)
	defer destroy_parse_error(&problem)
	testing.expect(t, !ok)
	testing.expect(t, problem.line > 0)
	testing.expect(t, !strings.contains(problem.message, "broken.toml"))
}
// END org:block config-toml-tests
