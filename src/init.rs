// Generated from SEAL.org; edit the literate source instead.
use std::{
    env,
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
};

use rustix::{
    fs::{Access, access},
    io::Errno,
};

use crate::config::Config;

pub(crate) struct InitializedWorkspace {
    pub(crate) config_path: PathBuf,
    pub(crate) mailbox_path: PathBuf,
    pub(crate) rsync: PathBuf,
    pub(crate) ssh: Option<PathBuf>,
}

pub(crate) fn initialize_workspace(
    cwd: &Path,
    requested_config_path: Option<&Path>,
    peer_path: PathBuf,
    peer_ssh: Option<String>,
) -> Result<InitializedWorkspace, String> {
    let (config_path, mailbox_path) = preflight_paths(cwd, requested_config_path)?;
    let rsync = resolve_tool("rsync")?;
    let ssh = match peer_ssh {
        Some(_) => Some(resolve_tool("ssh")?),
        None => None,
    };
    let source = Config::initialized(peer_path, peer_ssh, rsync.clone(), ssh.clone()).to_toml()?;

    fs::create_dir(&mailbox_path)
        .map_err(|error| format!("cannot create mailbox {}: {error}", mailbox_path.display()))?;
    if let Err(failure) = create_configuration(&config_path, &source) {
        return match fs::remove_dir(&mailbox_path) {
            Ok(()) => Err(failure),
            Err(cleanup_error) => Err(format!(
                "{failure}; cannot remove mailbox {}: {cleanup_error}",
                mailbox_path.display()
            )),
        };
    }

    Ok(InitializedWorkspace {
        config_path,
        mailbox_path,
        rsync,
        ssh,
    })
}

fn preflight_paths(
    cwd: &Path,
    requested_config_path: Option<&Path>,
) -> Result<(PathBuf, PathBuf), String> {
    let requested_config_path = requested_config_path.unwrap_or_else(|| Path::new("seal.toml"));
    let config_path = if requested_config_path.is_absolute() {
        requested_config_path.to_path_buf()
    } else {
        cwd.join(requested_config_path)
    };
    let config_dir = config_path.parent().ok_or_else(|| {
        format!(
            "configuration has no parent directory: {}",
            config_path.display()
        )
    })?;
    let mailbox_path = config_dir.join("mailbox");

    refuse_existing(&config_path, "configuration")?;
    refuse_existing(&mailbox_path, "mailbox")?;

    Ok((config_path, mailbox_path))
}

fn refuse_existing(path: &Path, label: &str) -> Result<(), String> {
    match fs::symlink_metadata(path) {
        Ok(_) => Err(format!("{label} already exists: {}", path.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!(
            "cannot inspect {label} {}: {error}",
            path.display()
        )),
    }
}

fn resolve_tool(name: &str) -> Result<PathBuf, String> {
    let path = env::var_os("PATH").ok_or_else(|| format!("cannot find {name}: PATH is not set"))?;
    for directory in env::split_paths(&path) {
        let candidate = directory.join(name);
        let metadata = match fs::metadata(&candidate) {
            Ok(metadata) => metadata,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
                ) =>
            {
                continue;
            }
            Err(error) => {
                return Err(format!(
                    "cannot inspect {name} candidate {}: {error}",
                    candidate.display()
                ));
            }
        };
        if !metadata.is_file() {
            continue;
        }
        match access(&candidate, Access::EXEC_OK) {
            Ok(()) => {}
            Err(Errno::ACCESS | Errno::PERM | Errno::NOENT | Errno::NOTDIR) => continue,
            Err(error) => {
                return Err(format!(
                    "cannot test {name} candidate {} for execution: {error}",
                    candidate.display()
                ));
            }
        }
        return candidate
            .canonicalize()
            .map_err(|error| format!("cannot resolve {name} {}: {error}", candidate.display()));
    }
    Err(format!("cannot find executable {name} in PATH"))
}

fn create_configuration(path: &Path, source: &str) -> Result<(), String> {
    let mut file = match OpenOptions::new().write(true).create_new(true).open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            return Err(format!("configuration already exists: {}", path.display()));
        }
        Err(error) => {
            return Err(format!(
                "cannot create configuration {}: {error}",
                path.display()
            ));
        }
    };
    if let Err(error) = file.write_all(source.as_bytes()) {
        drop(file);
        let failure = format!("cannot write configuration {}: {error}", path.display());
        return match fs::remove_file(path) {
            Ok(()) => Err(failure),
            Err(cleanup_error) => Err(format!(
                "{failure}; cannot remove configuration {}: {cleanup_error}",
                path.display()
            )),
        };
    }
    Ok(())
}
