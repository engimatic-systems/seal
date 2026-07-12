// BEGIN org:block test-package-imports
package main

import "core:strings"
import "core:testing"
// END org:block test-package-imports
// BEGIN org:block visible-seed-test
@(test)
test_visible_seed_behavior :: proc(t: ^testing.T) {
	usage := parse_args([]string{})
	testing.expect_value(t, usage.action, Cli_Action.Usage)

	help := parse_args([]string{"--help"})
	testing.expect_value(t, help.action, Cli_Action.Help)

	version := parse_args([]string{"-V"})
	testing.expect_value(t, version.action, Cli_Action.Version)

	debug_run := parse_args([]string{"--debug"})
	testing.expect_value(t, debug_run.action, Cli_Action.Run)
	testing.expect(t, debug_run.debug)

	invalid := parse_args([]string{"pull"})
	testing.expect_value(t, invalid.action, Cli_Action.Invalid)
	testing.expect_value(t, invalid.invalid, "pull")

	testing.expect_value(t, VERSION, "0.1.0")
	testing.expect(t, strings.contains(HELP_TEXT, "seal [OPTIONS] cfg"))

	cfg := parse_args([]string{"--config", "elsewhere.toml", "cfg"})
	testing.expect_value(t, cfg.action, Cli_Action.Cfg)
	testing.expect_value(t, cfg.config, "elsewhere.toml")
	testing.expect(t, cfg.explicit_config)

	init := parse_args([]string{"--config", "workspace/seal.toml", "init", "peer/mailbox"})
	testing.expect_value(t, init.action, Cli_Action.Init)
	testing.expect_value(t, init.peer_path, "peer/mailbox")
	testing.expect(t, !init.explicit_peer_ssh)

	ssh_init := parse_args([]string{"init", "/home/agent/mailbox", "--ssh", "experiment.agent"})
	testing.expect_value(t, ssh_init.action, Cli_Action.Init)
	testing.expect_value(t, ssh_init.peer_ssh, "experiment.agent")
	testing.expect(t, ssh_init.explicit_peer_ssh)
}

@(test)
test_missing_init_peer_uses_init_usage :: proc(t: ^testing.T) {
	missing_peer := parse_args([]string{"init"})
	testing.expect_value(t, missing_peer.action, Cli_Action.Init_Usage)
	testing.expect_value(t, INIT_USAGE, "seal init PEER_PATH [--ssh SSH_DESTINATION]")
}
// END org:block visible-seed-test
