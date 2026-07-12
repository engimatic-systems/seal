// BEGIN org:block config-test-package
package main

import "core:testing"
// END org:block config-test-package
// BEGIN org:block local-config-test
@(test)
test_local_config_resolves_from_config_directory :: proc(t: ^testing.T) {
	text := `# local workspace
local_mailbox = "../mailbox"

[peer] # local coordinates
path = "peer/mailbox"

[tools]
rsync = "/run/current-system/sw/bin/rsync"

[debug]
rsync_debug_flags = [] # quiet when --debug is present
`
	config, problem, ok := parse_config(text, "/work/seal/config/seal.toml", "/work/seal/config")
	defer destroy_config(&config)
	testing.expect(t, ok, problem.message)
	testing.expect_value(t, config.local_mailbox, "/work/seal/mailbox")
	testing.expect_value(t, config.peer_path, "/work/seal/config/peer/mailbox")
	testing.expect(t, !config.has_peer_ssh)
	testing.expect(t, !config.has_ssh)
	testing.expect_value(t, config.rsync_debug_flag, "")
}
// END org:block local-config-test
// BEGIN org:block ssh-config-test
@(test)
test_ssh_config_keeps_remote_path :: proc(t: ^testing.T) {
	text := `local_mailbox = "mailbox"

[peer]
path = "/home/agent/mailbox" # peer-side path
ssh = "experiment.\"agent"

[tools]
rsync = "/bin/rsync"
ssh = "/bin/ssh"

[debug]
ssh_debug_flags = ["-vvv"]
`
	config, problem, ok := parse_config(text, "/work/seal.toml", "/work")
	defer destroy_config(&config)
	testing.expect(t, ok, problem.message)
	testing.expect_value(t, config.local_mailbox, "/work/mailbox")
	testing.expect_value(t, config.peer_path, "/home/agent/mailbox")
	testing.expect_value(t, config.peer_ssh, "experiment.\"agent")
	testing.expect_value(t, config.rsync_debug_flag, "-v")
	testing.expect_value(t, config.ssh_debug_flag, "-vvv")
}
// END org:block ssh-config-test
// BEGIN org:block invalid-config-test
@(test)
test_invalid_config_reports_first_path_and_line :: proc(t: ^testing.T) {
	text := `local_mailbox = "mailbox"
[peer]
destination = "agent"
`
	config, problem, ok := parse_config(text, "/work/bad.toml", "/work")
	defer destroy_config(&config)
	defer destroy_config_error(&problem)
	testing.expect(t, !ok)
	testing.expect_value(t, problem.path, "/work/bad.toml")
	testing.expect_value(t, problem.line, 3)
	testing.expect_value(t, problem.message, "unknown key in current table")
}
// END org:block invalid-config-test
