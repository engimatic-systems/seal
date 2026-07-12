// Generated from SEAL.org; edit the literate source instead.
mod config;
mod init;

use std::{
    env,
    fmt::Display,
    path::{Path, PathBuf},
    process::ExitCode,
};

use clap::{Parser, Subcommand};

use config::{LoadedConfig, effective_debug_flags, load_config, resolve_local};
use init::{InitializedWorkspace, initialize_workspace};

#[derive(Parser)]
#[command(version, about, arg_required_else_help = true)]
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

    /// Create a local Seal workspace
    Init {
        /// Peer mailbox path
        #[arg(value_name = "PEER_PATH")]
        peer_path: PathBuf,

        /// Reach the peer through this SSH destination
        #[arg(long, value_name = "SSH_DESTINATION")]
        ssh: Option<String>,
    },
}

fn main() -> ExitCode {
    let cli = Cli::parse();

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
        Some(Command::Cfg) => load_config(&cwd, cli.config.as_deref()).and_then(print_config),
        Some(Command::Init { peer_path, ssh }) => {
            run_init(&cwd, cli.config.as_deref(), peer_path, ssh)
        }
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

fn info(label: &str, value: impl Display) {
    eprintln!("[info] :: {label}: {value}");
}

const FIXED_TRANSFER_PROFILE: &[&str] =
    &["--recursive", "--links", "--perms", "--times", "--checksum"];

fn print_config(loaded: LoadedConfig) -> Result<(), String> {
    let LoadedConfig {
        config,
        path,
        selection,
    } = loaded;
    let config_dir = path
        .parent()
        .ok_or_else(|| format!("configuration has no parent directory: {}", path.display()))?;
    let local_mailbox = resolve_local(config_dir, &config.local_mailbox);

    println!("config selection: {selection}");
    println!("config path: {}", path.display());
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

fn run_init(
    cwd: &Path,
    requested_config_path: Option<&Path>,
    peer_path: PathBuf,
    peer_ssh: Option<String>,
) -> Result<(), String> {
    let InitializedWorkspace {
        config_path,
        mailbox_path,
        rsync,
        ssh,
    } = initialize_workspace(cwd, requested_config_path, peer_path, peer_ssh)?;

    info("created configuration", config_path.display());
    info("created mailbox", mailbox_path.display());
    info("pinned rsync", rsync.display());
    if let Some(ssh) = ssh {
        info("pinned ssh", ssh.display());
    }
    Ok(())
}
