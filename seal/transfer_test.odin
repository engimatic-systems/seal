// BEGIN org:block transfer-test-package-fixtures
package main

import "core:testing"
import seal_config "config"

expect_arguments :: proc(t: ^testing.T, actual: []string, expected: []string) {
	testing.expect_value(t, len(actual), len(expected))
	if len(actual) != len(expected) {
		return
	}
	for argument, index in actual {
		testing.expect_value(t, argument, expected[index])
	}
}
// END org:block transfer-test-package-fixtures
// BEGIN org:block local-pull-plan-test
@(test)
test_local_pull_plan_is_exact :: proc(t: ^testing.T) {
	config := seal_config.Config{
		local_mailbox = "/work/local mailbox",
		peer_path = "/work/peer mailbox/",
		rsync = "/tools/pinned-rsync",
		rsync_debug_flag = "-vvv",
	}
	plan := plan_pull(config, false, false)
	defer destroy_process_plan(&plan)
	testing.expect_value(t, plan.executable, "/tools/pinned-rsync")
	expect_arguments(t, plan.argv[:], []string{
		"--recursive",
		"--links",
		"--perms",
		"--times",
		"--checksum",
		"--",
		"/work/peer mailbox/",
		"/work/local mailbox/",
	})
}
// END org:block local-pull-plan-test
// BEGIN org:block ssh-pull-plan-test
@(test)
test_ssh_debug_dry_run_plan_is_exact :: proc(t: ^testing.T) {
	config := seal_config.Config{
		local_mailbox = "/work/mailbox",
		peer_path = "/home/agent/mailbox",
		peer_ssh = "agent alias",
		rsync = "/tools/rsync",
		ssh = "/tools/ssh",
		rsync_debug_flag = "-vv",
		ssh_debug_flag = "-vvv",
	}
	plan := plan_pull(config, true, true)
	defer destroy_process_plan(&plan)
	expect_arguments(t, plan.argv[:], []string{
		"--recursive",
		"--links",
		"--perms",
		"--times",
		"--checksum",
		"--dry-run",
		"-vv",
		"--secluded-args",
		"--rsh",
		"/tools/ssh -vvv",
		"--",
		"agent alias:/home/agent/mailbox/",
		"/work/mailbox/",
	})
}
// END org:block ssh-pull-plan-test
// BEGIN org:block child-failure-test
@(test)
test_child_failure_status_is_returned :: proc(t: ^testing.T) {
	plan := Process_Plan{executable = "/run/current-system/sw/bin/false"}
	status := invoke_process_plan(plan, false)
	testing.expect_value(t, status, 1)
}
// END org:block child-failure-test
