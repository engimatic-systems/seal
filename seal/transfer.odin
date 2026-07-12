// BEGIN org:block transfer-package-plan
package main

import "core:fmt"
import "core:os"
import "core:strings"

TRANSFER_FLAGS :: [?]string{
	"--recursive",
	"--links",
	"--perms",
	"--times",
	"--checksum",
}

SSH_TRANSFER_FLAG :: "--secluded-args"

Process_Plan :: struct {
	executable: string,
	argv:       [dynamic]string,
}

Transfer_Direction :: enum {
	Pull,
	Push,
}

destroy_process_plan :: proc(plan: ^Process_Plan) {
	delete(plan.executable)
	for argument in plan.argv {
		delete(argument)
	}
	delete(plan.argv)
	plan^ = {}
}

append_plan_argument :: proc(plan: ^Process_Plan, argument: string) {
	append(&plan.argv, strings.clone(argument))
}
// END org:block transfer-package-plan
// BEGIN org:block transfer-plan
with_trailing_slash :: proc(path: string) -> string {
	if strings.has_suffix(path, "/") {
		return strings.clone(path)
	}
	return fmt.aprintf("%s/", path)
}

plan_transfer :: proc(
	config: Config,
	direction: Transfer_Direction,
	debug_enabled, dry_run: bool,
) -> Process_Plan {
	plan := Process_Plan{executable = strings.clone(config.rsync)}
	for flag in TRANSFER_FLAGS {
		append_plan_argument(&plan, flag)
	}
	if dry_run {
		append_plan_argument(&plan, "--dry-run")
	}
	if debug_enabled && len(config.rsync_debug_flag) > 0 {
		append_plan_argument(&plan, config.rsync_debug_flag)
	}

	if len(config.peer_ssh) > 0 {
		append_plan_argument(&plan, SSH_TRANSFER_FLAG)
		append_plan_argument(&plan, "--rsh")
		remote_shell := strings.clone(config.ssh)
		if debug_enabled && len(config.ssh_debug_flag) > 0 {
			delete(remote_shell)
			remote_shell = fmt.aprintf("%s %s", config.ssh, config.ssh_debug_flag)
		}
		append_plan_argument(&plan, remote_shell)
		delete(remote_shell)
	}

	peer_path := with_trailing_slash(config.peer_path)
	defer delete(peer_path)
	if len(config.peer_ssh) > 0 {
		remote_path := fmt.aprintf("%s:%s", config.peer_ssh, peer_path)
		delete(peer_path)
		peer_path = remote_path
	}
	local_path := with_trailing_slash(config.local_mailbox)
	defer delete(local_path)

	append_plan_argument(&plan, "--")
	if direction == .Pull {
		append_plan_argument(&plan, peer_path)
		append_plan_argument(&plan, local_path)
	} else {
		append_plan_argument(&plan, local_path)
		append_plan_argument(&plan, peer_path)
	}
	return plan
}
// END org:block transfer-plan
// BEGIN org:block transfer-invocation
debug_process_plan :: proc(plan: Process_Plan) {
	debug("process executable", fmt.tprintf("%q", plan.executable))
	fmt.eprintf("[debug] :: process argv: [")
	for argument, index in plan.argv {
		if index > 0 {
			fmt.eprintf(", ")
		}
		fmt.eprintf("%q", argument)
	}
	fmt.eprintfln("]")
}

invoke_process_plan :: proc(plan: Process_Plan, debug_enabled: bool) -> int {
	if debug_enabled {
		debug_process_plan(plan)
	}
	command := make([]string, len(plan.argv) + 1)
	defer delete(command)
	command[0] = plan.executable
	copy(command[1:], plan.argv[:])
	process, start_error := os.process_start(os.Process_Desc{
		command = command,
		stdin = os.stdin,
		stdout = os.stdout,
		stderr = os.stderr,
	})
	if start_error != nil {
		error("cannot start rsync", fmt.tprint(start_error))
		return 1
	}
	state, wait_error := os.process_wait(process)
	if wait_error != nil {
		error("cannot wait for rsync", fmt.tprint(wait_error))
		return 1
	}
	if debug_enabled {
		debug("child status", fmt.tprintf("%d", state.exit_code))
	}
	if state.success && state.exit_code == 0 {
		return 0
	}
	if state.exit_code != 0 {
		return state.exit_code
	}
	return 1
}
// END org:block transfer-invocation
// BEGIN org:block transfer-command
run_transfer :: proc(cli: Cli, direction: Transfer_Direction) -> int {
	config, config_problem, ok := load_config(cli.config)
	if !ok {
		defer destroy_config(&config)
		defer destroy_config_error(&config_problem)
		if config_problem.line > 0 {
			error("configuration", fmt.tprintf(
				"%s:%d: %s",
				config_problem.path,
				config_problem.line,
				config_problem.message,
			))
		} else {
			error("configuration", fmt.tprintf(
				"%s: %s",
				config_problem.path,
				config_problem.message,
			))
		}
		return 1
	}
	defer destroy_config(&config)
	if cli.debug {
		cwd, cwd_error := os.get_absolute_path(".", context.allocator)
		if cwd_error != nil {
			error("cannot determine current directory", fmt.tprint(cwd_error))
			return 1
		}
		defer delete(cwd)
		debug("cwd", cwd)
		if cli.explicit_config {
			debug("configuration selection", "--config")
		} else {
			debug("configuration selection", "default ./seal.toml")
		}
		debug("configuration path", config.path)
		debug("local mailbox", config.local_mailbox)
		debug("peer path", config.peer_path)
		debug("rsync", config.rsync)
		if len(config.rsync_debug_flag) == 0 {
			debug("rsync debug flags", "[]")
		} else {
			debug("rsync debug flags", config.rsync_debug_flag)
		}
		if len(config.peer_ssh) > 0 {
			debug("peer ssh", config.peer_ssh)
			debug("ssh", config.ssh)
			if len(config.ssh_debug_flag) == 0 {
				debug("ssh debug flags", "[]")
			} else {
				debug("ssh debug flags", config.ssh_debug_flag)
			}
		}
	}
	plan := plan_transfer(config, direction, cli.debug, cli.dry_run)
	defer destroy_process_plan(&plan)
	return invoke_process_plan(plan, cli.debug)
}
// END org:block transfer-command
