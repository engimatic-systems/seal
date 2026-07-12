// Generated from SEAL.org; edit the literate source instead.
use std::{
    env,
    fmt::Display,
    fs,
    path::{Path, PathBuf},
    process::ExitCode,
};

use clap::{Parser, Subcommand};
use serde::Deserialize;

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    /// Report process facts on standard error
    #[arg(long, global = true)]
    debug: bool,

    /// Read configuration from PATH
    #[arg(long, global = true, value_name = "PATH")]
    config: Option<PathBuf>,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Print the effective configuration
    Cfg,
}

fn main() -> ExitCode {
    let cli = Cli::parse();

    if !cli.debug && cli.command.is_none() {
        return ExitCode::SUCCESS;
    }

    let cwd = match env::current_dir() {
        Ok(cwd) => cwd,
        Err(error) => {
            eprintln!("[error] :: cannot determine current directory: {error}");
            return ExitCode::FAILURE;
        }
    };

    if cli.debug {
        debug("cwd", cwd.display());
        debug("version", env!("CARGO_PKG_VERSION"));
    }

    let result = match cli.command {
        Some(Command::Cfg) => print_config(&cwd, cli.config.as_deref()),
        None => Ok(()),
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("[error] :: {error}");
            ExitCode::FAILURE
        }
    }
}

fn debug(label: &str, value: impl Display) {
    eprintln!("[debug] :: {label}: {value}");
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    local_mailbox: PathBuf,
    peer: Peer,
    tools: Tools,
    #[serde(default)]
    debug: DebugConfig,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Peer {
    path: PathBuf,
    ssh: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Tools {
    rsync: PathBuf,
    ssh: Option<PathBuf>,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct DebugConfig {
    rsync_debug_flags: Option<Vec<String>>,
    ssh_debug_flags: Option<Vec<String>>,
}

impl Config {
    fn validate(&self) -> Result<(), String> {
        if !self.tools.rsync.is_absolute() {
            return Err("tools.rsync must be an absolute path".into());
        }
        validate_debug_flags(
            "debug.rsync_debug_flags",
            self.debug.rsync_debug_flags.as_deref(),
        )?;

        match (&self.peer.ssh, &self.tools.ssh) {
            (Some(_), Some(ssh)) if !ssh.is_absolute() => {
                return Err("tools.ssh must be an absolute path".into());
            }
            (Some(_), None) => return Err("an SSH peer requires tools.ssh".into()),
            (None, Some(_)) => return Err("a local peer must omit tools.ssh".into()),
            _ => {}
        }

        if self.peer.ssh.is_some() {
            validate_debug_flags(
                "debug.ssh_debug_flags",
                self.debug.ssh_debug_flags.as_deref(),
            )?;
        } else if self.debug.ssh_debug_flags.is_some() {
            return Err("a local peer must omit debug.ssh_debug_flags".into());
        }

        Ok(())
    }
}

fn validate_debug_flags(label: &str, flags: Option<&[String]>) -> Result<(), String> {
    let valid = match flags {
        None | Some([]) => true,
        Some([flag]) => matches!(flag.as_str(), "-v" | "-vv" | "-vvv"),
        Some(_) => false,
    };

    if valid {
        Ok(())
    } else {
        Err(format!(
            "{label} must be empty or contain exactly one of -v, -vv, or -vvv"
        ))
    }
}

const FIXED_TRANSFER_PROFILE: &[&str] =
    &["--recursive", "--links", "--perms", "--times", "--checksum"];

fn print_config(cwd: &Path, explicit_path: Option<&Path>) -> Result<(), String> {
    let (selected, selection) = match explicit_path {
        Some(path) => (path.to_path_buf(), "explicit --config PATH"),
        None => (PathBuf::from("./seal.toml"), "default ./seal.toml"),
    };
    let candidate = if selected.is_absolute() {
        selected.clone()
    } else {
        cwd.join(&selected)
    };
    let resolved = candidate.canonicalize().map_err(|error| {
        format!(
            "cannot resolve configuration {}: {error}",
            selected.display()
        )
    })?;
    let source = fs::read_to_string(&resolved)
        .map_err(|error| format!("cannot read configuration {}: {error}", resolved.display()))?;
    let config: Config = toml::from_str(&source)
        .map_err(|error| format!("invalid configuration {}: {error}", resolved.display()))?;
    config
        .validate()
        .map_err(|error| format!("invalid configuration {}: {error}", resolved.display()))?;

    let config_dir = resolved.parent().ok_or_else(|| {
        format!(
            "configuration has no parent directory: {}",
            resolved.display()
        )
    })?;
    let local_mailbox = resolve_local(config_dir, &config.local_mailbox);

    println!("config selection: {selection}");
    println!("selected config: {}", selected.display());
    println!("resolved config: {}", resolved.display());
    println!("local mailbox: {}", local_mailbox.display());
    match &config.peer.ssh {
        Some(destination) => {
            println!("peer kind: ssh");
            println!("peer ssh: {destination}");
            println!("peer path: {}", config.peer.path.display());
        }
        None => {
            println!("peer kind: local");
            println!(
                "peer path: {}",
                resolve_local(config_dir, &config.peer.path).display()
            );
        }
    }
    println!("rsync tool: {}", config.tools.rsync.display());
    println!(
        "rsync debug flags: {}",
        effective_debug_flags(config.debug.rsync_debug_flags.as_deref())
    );
    if let Some(ssh) = &config.tools.ssh {
        println!("ssh tool: {}", ssh.display());
        println!(
            "ssh debug flags: {}",
            effective_debug_flags(config.debug.ssh_debug_flags.as_deref())
        );
    }
    println!("version: {}", env!("CARGO_PKG_VERSION"));
    println!("fixed transfer profile: {FIXED_TRANSFER_PROFILE:?}");

    Ok(())
}

fn resolve_local(config_dir: &Path, path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        config_dir.join(path)
    }
}

fn effective_debug_flags(flags: Option<&[String]>) -> String {
    match flags {
        Some(flags) => format!("{flags:?}"),
        None => "[\"-v\"]".into(),
    }
}
