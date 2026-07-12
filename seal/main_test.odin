// BEGIN org:block test-package-imports
package main

import "core:strings"
import "core:testing"
// END org:block test-package-imports
// BEGIN org:block visible-seed-test
@(test)
test_visible_seed_behavior :: proc(t: ^testing.T) {
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
	testing.expect(t, strings.contains(HELP_TEXT, "Usage: seal [OPTIONS] cfg"))

	cfg := parse_args([]string{"--config", "elsewhere.toml", "cfg"})
	testing.expect_value(t, cfg.action, Cli_Action.Cfg)
	testing.expect_value(t, cfg.config, "elsewhere.toml")
	testing.expect(t, cfg.explicit_config)
}
// END org:block visible-seed-test
