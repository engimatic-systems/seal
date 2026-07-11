// Generated from SEAL.org; edit that file instead.

use std::{env, ffi::OsString, process::ExitCode};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const HELP: &str = "\
Seal executable seed

Usage: seal [OPTIONS]

Options:
      --debug    Report process working directory and Seal version
  -h, --help     Print help
  -V, --version  Print version";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Display {
    Help,
    Version,
}

impl Display {
    const fn flag(self) -> &'static str {
        match self {
            Self::Help => "--help",
            Self::Version => "--version",
        }
    }
}

#[derive(Debug, Eq, PartialEq)]
struct Cli {
    debug: bool,
    display: Display,
}

mod report {
    #[derive(Clone, Copy)]
    enum Level {
        Info,
        Warn,
        Error,
        Debug,
    }

    impl Level {
        const fn label(self) -> &'static str {
            match self {
                Self::Info => "info",
                Self::Warn => "warn",
                Self::Error => "error",
                Self::Debug => "debug",
            }
        }
    }

    fn escape_control_characters(message: &str) -> String {
        let mut escaped = String::with_capacity(message.len());

        for character in message.chars() {
            if character.is_control() {
                escaped.extend(character.escape_default());
            } else {
                escaped.push(character);
            }
        }

        escaped
    }

    fn format(level: Level, message: &str) -> String {
        format!(
            "[{}] :: {}",
            level.label(),
            escape_control_characters(message)
        )
    }

    fn emit(level: Level, message: &str) {
        eprintln!("{}", format(level, message));
    }

    #[allow(dead_code)]
    pub fn info(message: &str) {
        emit(Level::Info, message);
    }

    #[allow(dead_code)]
    pub fn warn(message: &str) {
        emit(Level::Warn, message);
    }

    pub fn error(message: &str) {
        emit(Level::Error, message);
    }

    pub fn debug(message: &str) {
        emit(Level::Debug, message);
    }

    #[cfg(test)]
    mod tests {
        use super::{Level, format};

        #[test]
        fn formats_each_contract_level() {
            assert_eq!(format(Level::Info, "message"), "[info] :: message");
            assert_eq!(format(Level::Warn, "message"), "[warn] :: message");
            assert_eq!(format(Level::Error, "message"), "[error] :: message");
            assert_eq!(format(Level::Debug, "message"), "[debug] :: message");
        }
    }
}

fn parse_args(args: impl IntoIterator<Item = OsString>) -> Result<Cli, String> {
    let mut debug = false;
    let mut display = None;

    for argument in args {
        let argument = argument
            .into_string()
            .map_err(|_| "argument is not valid UTF-8".to_owned())?;

        match argument.as_str() {
            "--debug" => debug = true,
            "-h" | "--help" => select_display(&mut display, Display::Help)?,
            "-V" | "--version" => select_display(&mut display, Display::Version)?,
            _ => return Err(format!("unrecognized argument: {argument}")),
        }
    }

    Ok(Cli {
        debug,
        display: display.unwrap_or(Display::Help),
    })
}

fn select_display(selected: &mut Option<Display>, candidate: Display) -> Result<(), String> {
    match selected {
        Some(previous) if *previous != candidate => Err(format!(
            "{} and {} cannot be used together",
            previous.flag(),
            candidate.flag()
        )),
        _ => {
            *selected = Some(candidate);
            Ok(())
        }
    }
}

fn run(args: impl IntoIterator<Item = OsString>) -> ExitCode {
    let cli = match parse_args(args) {
        Ok(cli) => cli,
        Err(message) => {
            report::error(&message);
            return ExitCode::from(2);
        }
    };

    if cli.debug {
        let current_dir = match env::current_dir() {
            Ok(path) => path,
            Err(error) => {
                report::error(&format!(
                    "cannot resolve process working directory: {error}"
                ));
                return ExitCode::FAILURE;
            }
        };

        report::debug(&format!(
            "process working directory: {}",
            current_dir.display()
        ));
        report::debug(&format!("Seal version: {VERSION}"));
    }

    match cli.display {
        Display::Help => println!("{HELP}"),
        Display::Version => println!("seal {VERSION}"),
    }

    ExitCode::SUCCESS
}

fn main() -> ExitCode {
    run(env::args_os().skip(1))
}

#[cfg(test)]
mod tests {
    use super::{Cli, Display, parse_args};

    #[test]
    fn no_arguments_select_help_without_debug() {
        assert_eq!(
            parse_args(Vec::new()),
            Ok(Cli {
                debug: false,
                display: Display::Help,
            })
        );
    }

    #[test]
    fn help_and_version_conflict() {
        let arguments = ["--help", "--version"].map(Into::into);

        assert_eq!(
            parse_args(arguments),
            Err("--help and --version cannot be used together".to_owned())
        );
    }
}
