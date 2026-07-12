// BEGIN org:block config-behavior-tests
package main

import "core:strings"
import "core:testing"

@(test)
test_local_config_resolves_from_config_directory :: proc(t: ^testing.T) {
	text := `# local workspace
local_mailbox = "../mailbox"

[peer]
path = "peer/mailbox"

[tools]
rsync = "/run/current-system/sw/bin/rsync"

[debug]
rsync_debug_flags = []
`
	config, problem, ok := parse_config(text, "/work/seal/config/seal.toml", "/work/seal/config")
	defer destroy_config(&config)
	defer destroy_config_error(&problem)
	testing.expect(t, ok, problem.message)
	testing.expect_value(t, config.local_mailbox, "/work/seal/mailbox")
	testing.expect_value(t, config.peer_path, "/work/seal/config/peer/mailbox")
	testing.expect_value(t, config.peer_ssh, "")
	testing.expect_value(t, config.ssh, "")
	testing.expect_value(t, config.rsync_debug_flag, "")
}

@(test)
test_ssh_config_keeps_remote_path_and_applies_defaults :: proc(t: ^testing.T) {
	text := `local_mailbox = "mailbox"

[peer]
path = "/home/agent/mailbox"
ssh = "experiment.\"agent"

[tools]
rsync = "/bin/rsync"
ssh = "/bin/ssh"

[debug]
ssh_debug_flags = ["-vvv"]
`
	config, problem, ok := parse_config(text, "/work/seal.toml", "/work")
	defer destroy_config(&config)
	defer destroy_config_error(&problem)
	testing.expect(t, ok, problem.message)
	testing.expect_value(t, config.local_mailbox, "/work/mailbox")
	testing.expect_value(t, config.peer_path, "/home/agent/mailbox")
	testing.expect_value(t, config.peer_ssh, "experiment.\"agent")
	testing.expect_value(t, config.rsync_debug_flag, "-v")
	testing.expect_value(t, config.ssh_debug_flag, "-vvv")
}

@(test)
test_schema_rejects_unknown_names :: proc(t: ^testing.T) {
	unknown_root := `local_mailbox = "mailbox"
surprise = "value"
[peer]
path = "peer"
[tools]
rsync = "/bin/rsync"
`
	config, problem, ok := parse_config(unknown_root, "/work/root.toml", "/work")
	testing.expect(t, !ok)
	testing.expect_value(t, problem.message, "unknown root key or table")
	destroy_config(&config)
	destroy_config_error(&problem)

	unknown_table := `local_mailbox = "mailbox"
[peer]
path = "peer"
[tools]
rsync = "/bin/rsync"
[extra]
value = "unknown"
`
	config, problem, ok = parse_config(unknown_table, "/work/table.toml", "/work")
	testing.expect(t, !ok)
	testing.expect_value(t, problem.message, "unknown root key or table")
	destroy_config(&config)
	destroy_config_error(&problem)
}

@(test)
test_schema_rejects_wrong_type :: proc(t: ^testing.T) {
	text := `local_mailbox = 42
[peer]
path = "peer"
[tools]
rsync = "/bin/rsync"
`
	config, problem, ok := parse_config(text, "/work/type.toml", "/work")
	defer destroy_config(&config)
	defer destroy_config_error(&problem)
	testing.expect(t, !ok)
	testing.expect_value(t, problem.message, "local_mailbox must be a string")
}

@(test)
test_schema_rejects_empty_ssh_and_unlisted_debug_flag :: proc(t: ^testing.T) {
	empty_ssh := `local_mailbox = "mailbox"
[peer]
path = "/srv/mailbox"
ssh = ""
[tools]
rsync = "/bin/rsync"
ssh = "/bin/ssh"
`
	config, problem, ok := parse_config(empty_ssh, "/work/empty-ssh.toml", "/work")
	testing.expect(t, !ok)
	testing.expect_value(t, problem.message, "SSH values must not be empty")
	destroy_config(&config)
	destroy_config_error(&problem)

	bad_debug := `local_mailbox = "mailbox"
[peer]
path = "peer"
[tools]
rsync = "/bin/rsync"
[debug]
rsync_debug_flags = ["--verbose"]
`
	config, problem, ok = parse_config(bad_debug, "/work/debug.toml", "/work")
	testing.expect(t, !ok)
	testing.expect_value(t, problem.message, "debug flag must be -v, -vv, or -vvv")
	destroy_config(&config)
	destroy_config_error(&problem)
}

@(test)
test_invalid_toml_reports_parser_error :: proc(t: ^testing.T) {
	config, problem, ok := parse_config("local_mailbox = [\n", "/work/bad.toml", "/work")
	defer destroy_config(&config)
	defer destroy_config_error(&problem)
	testing.expect(t, !ok)
	testing.expect(t, problem.line > 0)
	testing.expect(t, !strings.contains(problem.message, "/work/bad.toml"))
}
// END org:block config-behavior-tests
