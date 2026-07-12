// BEGIN org:block main-package-imports
package main

import "core:fmt"
import "core:os"
// END org:block main-package-imports
// BEGIN org:block visible-constants
VERSION :: "0.1.0"

DEFAULT_CONFIG_PATH :: "./seal.toml"

HELP_TEXT :: `Seal
Operator-initiated opaque mailbox transport

Usage:
  seal [OPTIONS] cfg
  seal [OPTIONS] init PEER_PATH [--ssh SSH_DESTINATION]
  seal [OPTIONS] pull [--dry-run]
  seal [OPTIONS] push [--dry-run]

Options:
  --config PATH Select configuration instead of ./seal.toml
  --debug       Report process facts on standard error
  -h, --help    Print help
  -V, --version Print version
`
// END org:block visible-constants
// BEGIN org:block diagnostics
diagnostic :: proc(level, label, value: string) {
	fmt.eprintfln("[%s] :: %s: %s", level, label, value)
}

info :: proc(label, value: string) {
	diagnostic("info", label, value)
}

error :: proc(label, value: string) {
	diagnostic("error", label, value)
}

debug :: proc(label, value: string) {
	diagnostic("debug", label, value)
}
// END org:block diagnostics
// BEGIN org:block cli-state
Cli_Action :: enum {
	Run,
	Cfg,
	Init,
	Pull,
	Push,
	Help,
	Version,
	Invalid,
}

Cli :: struct {
	action:          Cli_Action,
	debug:           bool,
	config:          string,
	explicit_config: bool,
	peer_path:       string,
	peer_ssh:          string,
	explicit_peer_ssh: bool,
	dry_run:           bool,
	invalid:         string,
}
// END org:block cli-state
// BEGIN org:block parse-args
parse_args :: proc(args: []string) -> Cli {
	cli := Cli{config = DEFAULT_CONFIG_PATH}
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		switch arg {
		case "--debug":
			cli.debug = true
		case "--config":
			if cli.explicit_config || i + 1 >= len(args) {
				return Cli{action = .Invalid, debug = cli.debug, invalid = "--config"}
			}
			i += 1
			cli.config = args[i]
			cli.explicit_config = true
		case "cfg":
			if cli.action != .Run {
				return Cli{action = .Invalid, debug = cli.debug, invalid = arg}
			}
			cli.action = .Cfg
		case "init":
			if cli.action != .Run || i + 1 >= len(args) {
				return Cli{action = .Invalid, debug = cli.debug, invalid = arg}
			}
			cli.action = .Init
			i += 1
			cli.peer_path = args[i]
		case "pull":
			if cli.action != .Run {
				return Cli{action = .Invalid, debug = cli.debug, invalid = arg}
			}
			cli.action = .Pull
		case "push":
			if cli.action != .Run {
				return Cli{action = .Invalid, debug = cli.debug, invalid = arg}
			}
			cli.action = .Push
		case "--dry-run":
			if (cli.action != .Pull && cli.action != .Push) || cli.dry_run {
				return Cli{action = .Invalid, debug = cli.debug, invalid = arg}
			}
			cli.dry_run = true
		case "--ssh":
			if cli.action != .Init || cli.explicit_peer_ssh || i + 1 >= len(args) {
				return Cli{action = .Invalid, debug = cli.debug, invalid = arg}
			}
			i += 1
			if len(args[i]) == 0 {
				return Cli{action = .Invalid, debug = cli.debug, invalid = arg}
			}
			cli.peer_ssh = args[i]
			cli.explicit_peer_ssh = true
		case "-h", "--help":
			cli.action = .Help
		case "-V", "--version":
			cli.action = .Version
		case:
			return Cli{action = .Invalid, debug = cli.debug, invalid = arg}
		}
	}
	return cli
}
// END org:block parse-args
// BEGIN org:block cfg-display
print_debug_flag :: proc(label, value: string) {
	if len(value) == 0 {
		fmt.printfln("%s: []", label)
		return
	}
	fmt.printfln("%s: [\"%s\"]", label, value)
}

debug_config :: proc(cli: Cli, config: Config) -> bool {
	cwd, cwd_error := os.get_absolute_path(".", context.allocator)
	if cwd_error != nil {
		error("cannot determine current directory", fmt.tprint(cwd_error))
		return false
	}
	defer delete(cwd)
	debug("cwd", cwd)
	if cli.explicit_config {
		debug("configuration selection", fmt.tprintf("--config %s", cli.config))
	} else {
		debug("configuration selection", "default ./seal.toml")
	}
	debug("configuration path", config.path)
	debug("configuration directory", config.directory)
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
	debug("version", VERSION)
	return true
}

run_cfg :: proc(cli: Cli) -> int {
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
	if cli.debug && !debug_config(cli, config) {
		return 1
	}

	if cli.explicit_config {
		fmt.printfln("configuration selection: --config %s", cli.config)
	} else {
		fmt.printfln("configuration selection: default %s", DEFAULT_CONFIG_PATH)
	}
	fmt.printfln("configuration path: %s", config.path)
	fmt.printfln("configuration directory: %s", config.directory)
	fmt.printfln("local mailbox: %s", config.local_mailbox)
	if len(config.peer_ssh) > 0 {
		fmt.println("peer kind: ssh")
		fmt.printfln("peer ssh: %s", config.peer_ssh)
	} else {
		fmt.println("peer kind: local")
	}
	fmt.printfln("peer path: %s", config.peer_path)
	fmt.printfln("rsync: %s", config.rsync)
	if len(config.ssh) > 0 {
		fmt.printfln("ssh: %s", config.ssh)
	} else {
		fmt.println("ssh: not configured")
	}
	print_debug_flag("rsync debug flags", config.rsync_debug_flag)
	if len(config.peer_ssh) > 0 {
		print_debug_flag("ssh debug flags", config.ssh_debug_flag)
	} else {
		fmt.println("ssh debug flags: not applicable")
	}
	fmt.printfln("binary version: %s", VERSION)
	fmt.println("transfer profile:")
	for flag in TRANSFER_FLAGS {
		fmt.printfln("  %s", flag)
	}
	if len(config.peer_ssh) > 0 {
		fmt.printfln("  %s", SSH_TRANSFER_FLAG)
	}
	return 0
}
// END org:block cfg-display
// BEGIN org:block run
run :: proc(args: []string) -> int {
	cli := parse_args(args)
	switch cli.action {
	case .Help:
		fmt.print(HELP_TEXT)
		return 0
	case .Version:
		fmt.printfln("seal %s", VERSION)
		return 0
	case .Invalid:
		error("unexpected argument", cli.invalid)
		return 2
	case .Cfg:
		return run_cfg(cli)
	case .Init:
		return run_init(cli)
	case .Pull:
		return run_transfer(cli, .Pull)
	case .Push:
		return run_transfer(cli, .Push)
	case .Run:
	}

	if !cli.debug {
		return 0
	}

	cwd, cwd_error := os.get_absolute_path(".", context.allocator)
	if cwd_error != nil {
		error("cannot determine current directory", fmt.tprint(cwd_error))
		return 1
	}
	defer delete(cwd)

	debug("cwd", cwd)
	debug("version", VERSION)
	return 0
}

main :: proc() {
	os.exit(run(os.args[1:]))
}
// END org:block run
