// BEGIN org:block config-syntax-tests
package main

import "core:testing"

@(test)
test_config_syntax_recognizes_complete_lines :: proc(t: ^testing.T) {
	blank := parse_config_syntax_line(" \t ")
	testing.expect_value(t, blank.kind, Config_Syntax_Kind.Blank)

	table := parse_config_syntax_line("  [peer]\t")
	testing.expect_value(t, table.kind, Config_Syntax_Kind.Table)
	testing.expect_value(t, table.key, "peer")

	assignment := parse_config_syntax_line("local_mailbox \t=  \"mail # box\"")
	testing.expect_value(t, assignment.kind, Config_Syntax_Kind.Assignment)
	testing.expect_value(t, assignment.key, "local_mailbox")
	testing.expect_value(t, assignment.value, "mail # box")
}

@(test)
test_config_syntax_rejects_non_contract_forms :: proc(t: ^testing.T) {
	invalid := []string{
		"# comment",
		"[ peer]",
		"[peer ]",
		"1key = \"value\"",
		"key-name = \"value\"",
		"key = value",
		"key = \"escaped\\nvalue\"",
		"key = \"unicode: \xc3\xa9\"",
		"key = \"value\" trailing",
		"key = []",
		"key = [\"-v\"]",
	}
	for line in invalid {
		parsed := parse_config_syntax_line(line)
		testing.expect_value(t, parsed.kind, Config_Syntax_Kind.Invalid)
	}
}
// END org:block config-syntax-tests
