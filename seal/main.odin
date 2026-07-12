// BEGIN org:block main-package-imports
package main

import "core:fmt"
import "core:os"
// END org:block main-package-imports
// BEGIN org:block visible-constants
VERSION :: "0.1.0"

HELP_TEXT :: `Seal
Operator-initiated opaque mailbox transport

Usage: seal [OPTIONS]

Options:
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

warn :: proc(label, value: string) {
	diagnostic("warn", label, value)
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
	Help,
	Version,
	Invalid,
}

Cli :: struct {
	action:   Cli_Action,
	debug:    bool,
	invalid:  string,
}
// END org:block cli-state
// BEGIN org:block parse-args
parse_args :: proc(args: []string) -> Cli {
	cli := Cli{}
	for arg in args {
		switch arg {
		case "--debug":
			cli.debug = true
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
