// Generated from SEAL.org; edit the literate source instead.
mod config;
mod init;
mod transfer;

use std::{
    env,
    fmt::{self, Display},
    io,
    path::{Path, PathBuf},
    process::ExitCode,
};

use clap::{Parser, Subcommand};

use config::{LoadedConfig, effective_debug_flags, load_config, resolve_local};
use init::{InitializedWorkspace, initialize_workspace};
use transfer::{FIXED_TRANSFER_FLAGS, PlanError, plan_pull};

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

    /// Pull the peer mailbox into the local mailbox
    Pull {
        /// Report changes without applying them
        #[arg(long)]
        dry_run: bool,
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
        Some(Command::Cfg) => load_config(&cwd, cli.config.as_deref())
            .and_then(print_config)
            .map(|()| ExitCode::SUCCESS),
        Some(Command::Init { peer_path, ssh }) => {
            run_init(&cwd, cli.config.as_deref(), peer_path, ssh).map(|()| ExitCode::SUCCESS)
        }
        Some(Command::Pull { dry_run }) => {
            pull(&cwd, cli.config.as_deref(), cli.debug, dry_run).map_err(|error| error.to_string())
        }
        None => Ok(ExitCode::SUCCESS),
    };

    match result {
        Ok(exit_code) => exit_code,
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

fn print_config(loaded: LoadedConfig) -> Result<(), String> {
    let LoadedConfig {
        config,
        path,
        directory,
        selection,
    } = loaded;
    let local_mailbox = resolve_local(&directory, &config.local_mailbox);

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
                resolve_local(&directory, &config.peer.path).display()
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
    println!("fixed transfer profile: {FIXED_TRANSFER_FLAGS:?}");

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

#[derive(Debug)]
enum TransferError {
    Configuration(String),
    Planning(PlanError),
    CannotStart {
        executable: PathBuf,
        source: io::Error,
    },
}

impl fmt::Display for TransferError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Configuration(error) => formatter.write_str(error),
            Self::Planning(error) => write!(formatter, "cannot plan transfer: {error}"),
            Self::CannotStart { executable, source } => {
                write!(
                    formatter,
                    "cannot run rsync {}: {source}",
                    executable.display()
                )
            }
        }
    }
}

fn pull(
    cwd: &Path,
    requested_config_path: Option<&Path>,
    debug_enabled: bool,
    dry_run: bool,
) -> Result<ExitCode, TransferError> {
    let LoadedConfig {
        config,
        path,
        directory,
        selection,
    } = load_config(cwd, requested_config_path).map_err(TransferError::Configuration)?;
    let local_mailbox = resolve_local(&directory, &config.local_mailbox);
    let peer_path = match config.peer.ssh {
        Some(_) => config.peer.path.clone(),
        None => resolve_local(&directory, &config.peer.path),
    };
    let plan = plan_pull(&config, &peer_path, &local_mailbox, debug_enabled, dry_run)
        .map_err(TransferError::Planning)?;

    if debug_enabled {
        debug("config selection", selection);
        debug("config path", path.display());
        debug("effective configuration", format!("{config:?}"));
        debug("local mailbox", local_mailbox.display());
        debug("rsync executable", format!("{:?}", plan.executable()));
        debug("rsync argv", format!("{:?}", plan.argv()));
    }

    let status = plan
        .execute()
        .map_err(|source| TransferError::CannotStart {
            executable: plan.executable().to_path_buf(),
            source,
        })?;
    if debug_enabled {
        debug("child exit status", status);
    }
    match status.code() {
        Some(code @ 0..=255) => Ok(ExitCode::from(code as u8)),
        _ => Ok(ExitCode::FAILURE),
    }
}
