// Generated from SEAL.org; edit that file instead.

mod config;

use config::{Config, Peer, SSH_TRANSFER_FLAGS, Selection, TRANSFER_FLAGS};
use std::{
    env,
    ffi::OsString,
    path::{Path, PathBuf},
    process::ExitCode,
};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const HELP: &str = "\
Opaque mailbox transport

Usage: seal [OPTIONS] <COMMAND>

Commands:
  cfg  Inspect effective configuration without contacting the peer

Options:
      --config <PATH>  Read PATH instead of ./seal.toml
      --debug          Report configuration selection and resolution
  -h, --help           Print help
  -V, --version        Print version";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Action {
    Help,
    Version,
    Cfg,
}

#[derive(Debug, Eq, PartialEq)]
struct Cli {
    debug: bool,
    config: Option<PathBuf>,
    action: Action,
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

    fn format(level: Level, message: &str) -> String {
        let mut escaped = String::with_capacity(message.len());
        for character in message.chars() {
            if character.is_control() {
                escaped.extend(character.escape_default());
            } else {
                escaped.push(character);
            }
        }
        format!("[{}] :: {escaped}", level.label())
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
    let mut arguments = args.into_iter();
    let mut debug = false;
    let mut config = None;
    let mut action = None;

    while let Some(argument) = arguments.next() {
        match argument.to_str() {
            Some("--debug") => debug = true,
            Some("--config") => {
                if config.is_some() {
                    return Err("--config may be supplied only once".to_owned());
                }
                config = Some(PathBuf::from(
                    arguments
                        .next()
                        .ok_or_else(|| "--config requires a path".to_owned())?,
                ));
            }
            Some("cfg") => select_action(&mut action, Action::Cfg)?,
            Some("-h" | "--help") => select_action(&mut action, Action::Help)?,
            Some("-V" | "--version") => select_action(&mut action, Action::Version)?,
            Some(value) => return Err(format!("unrecognized argument: {value}")),
            None => return Err("argument is not valid UTF-8".to_owned()),
        }
    }

    Ok(Cli {
        debug,
        config,
        action: action.unwrap_or(Action::Help),
    })
}

fn select_action(selected: &mut Option<Action>, candidate: Action) -> Result<(), String> {
    match selected {
        Some(previous) if *previous != candidate => {
            Err("only one command, --help, or --version may be selected".to_owned())
        }
        Some(_) => Err("command may be supplied only once".to_owned()),
        None => {
            *selected = Some(candidate);
            Ok(())
        }
    }
}

fn format_flags(flags: &[String]) -> String {
    format!("{flags:?}")
}

fn format_fixed_flags(flags: &[&str]) -> String {
    format!("{flags:?}")
}

fn format_path(path: &Path) -> String {
    format!("{path:?}")
}

fn cfg_lines(selection: &Selection, config: &Config) -> Vec<String> {
    let mut lines = vec![
        format!("seal.version = {VERSION}"),
        format!("config.path = {}", format_path(&selection.path)),
        format!("config.selection = {}", selection.reason.description()),
        format!(
            "local_mailbox.configured = {}",
            format_path(&config.local_mailbox.configured)
        ),
        format!(
            "local_mailbox.resolved = {}",
            format_path(&config.local_mailbox.resolved)
        ),
    ];

    match &config.peer {
        Peer::Local { path } => {
            lines.push("peer.kind = local".to_owned());
            lines.push(format!(
                "peer.path.configured = {}",
                format_path(&path.configured)
            ));
            lines.push(format!(
                "peer.path.resolved = {}",
                format_path(&path.resolved)
            ));
        }
        Peer::Ssh {
            path,
            destination,
            rsync,
        } => {
            lines.push("peer.kind = ssh".to_owned());
            lines.push(format!("peer.path = {}", format_path(path)));
            lines.push(format!("peer.ssh = {destination:?}"));
            lines.push(format!("peer.rsync = {}", format_path(rsync)));
        }
    }

    lines.push(format!(
        "tools.rsync = {}",
        format_path(&config.tools.rsync)
    ));
    if let Some(ssh) = &config.tools.ssh {
        lines.push(format!("tools.ssh = {}", format_path(ssh)));
    }
    lines.push(format!(
        "debug.rsync_debug_flags = {}",
        format_flags(&config.debug.rsync)
    ));
    if let Some(ssh) = &config.debug.ssh {
        lines.push(format!("debug.ssh_debug_flags = {}", format_flags(ssh)));
    }
    lines.push("transfer.profile = seal-v0-fixed".to_owned());
    lines.push(format!(
        "transfer.flags = {}",
        format_fixed_flags(TRANSFER_FLAGS)
    ));
    lines.push(format!(
        "transfer.ssh_flags = {}",
        format_fixed_flags(SSH_TRANSFER_FLAGS)
    ));
    lines
}

fn debug_config(selection: &Selection, config: &Config) {
    for line in cfg_lines(selection, config).into_iter().skip(3) {
        report::debug(&line);
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

    if cli.debug && cli.action != Action::Cfg {
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

    match cli.action {
        Action::Help => {
            println!("{HELP}");
            ExitCode::SUCCESS
        }
        Action::Version => {
            println!("seal {VERSION}");
            ExitCode::SUCCESS
        }
        Action::Cfg => run_cfg(cli),
    }
}

fn run_cfg(cli: Cli) -> ExitCode {
    let current_dir = match env::current_dir() {
        Ok(path) => path,
        Err(error) => {
            report::error(&format!(
                "cannot resolve process working directory: {error}"
            ));
            return ExitCode::FAILURE;
        }
    };
    let selection = Selection::new(&current_dir, cli.config.as_deref());

    if cli.debug {
        report::debug(&format!(
            "process working directory: {}",
            current_dir.display()
        ));
        report::debug(&format!("Seal version: {VERSION}"));
        report::debug(&format!("config.path = {}", format_path(&selection.path)));
        report::debug(&format!(
            "config.selection = {}",
            selection.reason.description()
        ));
    }

    let config = match config::load(&selection) {
        Ok(config) => config,
        Err(errors) => {
            for error in errors {
                report::error(&error);
            }
            return ExitCode::FAILURE;
        }
    };

    if cli.debug {
        debug_config(&selection, &config);
    }
    for line in cfg_lines(&selection, &config) {
        println!("{line}");
    }
    ExitCode::SUCCESS
}

fn main() -> ExitCode {
    run(env::args_os().skip(1))
}

#[cfg(test)]
mod tests {
    use super::{Action, Cli, parse_args};

    #[test]
    fn config_and_debug_are_global_around_cfg() {
        let arguments = ["cfg", "--config", "other.toml", "--debug"].map(Into::into);
        assert_eq!(
            parse_args(arguments),
            Ok(Cli {
                debug: true,
                config: Some("other.toml".into()),
                action: Action::Cfg,
            })
        );
    }

    #[test]
    fn help_and_version_still_conflict() {
        let arguments = ["--help", "--version"].map(Into::into);
        assert_eq!(
            parse_args(arguments),
            Err("only one command, --help, or --version may be selected".to_owned())
        );
    }
}
