// BEGIN org:block config-schema-tests
package main

import "core:testing"

@(test)
test_local_config_resolves_from_config_directory :: proc(t: ^testing.T) {
	text := `local_mailbox = "../mailbox"

[peer]
path = "peer/mailbox"

[tools]
rsync = "/run/current-system/sw/bin/rsync"

[debug]
rsync_debug_flags = ""
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
test_ssh_config_keeps_remote_path_and_defaults :: proc(t: ^testing.T) {
	text := `local_mailbox = "mailbox"

[peer]
path = "/home/agent/mailbox"
ssh = "experiment.agent"

[tools]
rsync = "/bin/rsync"
ssh = "/bin/ssh"

[debug]
ssh_debug_flags = "-vvv"
`
	config, problem, ok := parse_config(text, "/work/seal.toml", "/work")
	defer destroy_config(&config)
	defer destroy_config_error(&problem)
	testing.expect(t, ok, problem.message)
	testing.expect_value(t, config.local_mailbox, "/work/mailbox")
	testing.expect_value(t, config.peer_path, "/home/agent/mailbox")
	testing.expect_value(t, config.peer_ssh, "experiment.agent")
	testing.expect_value(t, config.rsync_debug_flag, "-v")
	testing.expect_value(t, config.ssh_debug_flag, "-vvv")
}

@(test)
test_config_policy_rejects_unknown_and_invalid_lines :: proc(t: ^testing.T) {
	unknown := `local_mailbox = "mailbox"
[peer]
destination = "agent"
`
	config, problem, ok := parse_config(unknown, "/work/unknown.toml", "/work")
	testing.expect(t, !ok)
	testing.expect_value(t, problem.line, 3)
	testing.expect_value(t, problem.message, "unknown key in current table")
	destroy_config(&config)
	destroy_config_error(&problem)

	invalid := `local_mailbox = "mailbox"
[ peer]
`
	config, problem, ok = parse_config(invalid, "/work/invalid.toml", "/work")
	testing.expect(t, !ok)
	testing.expect_value(t, problem.line, 2)
	testing.expect_value(t, problem.message, "invalid configuration syntax")
	destroy_config(&config)
	destroy_config_error(&problem)
}

@(test)
test_config_document_uses_last_seen_tables_and_fields :: proc(t: ^testing.T) {
	text := `local_mailbox = "first"
local_mailbox = ""
local_mailbox = "mailbox"

[peer]
path = "first-peer"

[tools]
rsync = "/bin/false"

[peer]
path = ""

[peer]
path = "final-peer"

[tools]
rsync = "/bin/rsync"
`
	config, problem, ok := parse_config(text, "/work/repeated.toml", "/work")
	defer destroy_config(&config)
	defer destroy_config_error(&problem)
	testing.expect(t, ok, problem.message)
	testing.expect_value(t, config.local_mailbox, "/work/mailbox")
	testing.expect_value(t, config.peer_path, "/work/final-peer")
	testing.expect_value(t, config.rsync, "/bin/rsync")
}
// END org:block config-schema-tests
