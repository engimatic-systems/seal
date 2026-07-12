// Generated from SEAL.org; edit the literate source instead.
use std::{env, fmt::Display, process::ExitCode};

use clap::Parser;

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    /// Report process facts on standard error
    #[arg(long, global = true)]
    debug: bool,
}

fn main() -> ExitCode {
    let cli = Cli::parse();

    if !cli.debug {
        return ExitCode::SUCCESS;
    }

    match env::current_dir() {
        Ok(cwd) => {
            debug("cwd", cwd.display());
            debug("version", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("[error] :: cannot determine current directory: {error}");
            ExitCode::FAILURE
        }
    }
}

fn debug(label: &str, value: impl Display) {
    eprintln!("[debug] :: {label}: {value}");
}
