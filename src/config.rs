// Generated from SEAL.org; edit the literate source instead.
use std::{
    fs,
    path::{Path, PathBuf},
};

use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Config {
    pub(crate) local_mailbox: PathBuf,
    pub(crate) peer: Peer,
    pub(crate) tools: Tools,
    #[serde(default, skip_serializing_if = "DebugConfig::is_empty")]
    pub(crate) debug: DebugConfig,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Peer {
    pub(crate) path: PathBuf,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) ssh: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Tools {
    pub(crate) rsync: PathBuf,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) ssh: Option<PathBuf>,
}

#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct DebugConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) rsync_debug_flags: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) ssh_debug_flags: Option<Vec<String>>,
}

impl DebugConfig {
    fn is_empty(&self) -> bool {
        self.rsync_debug_flags.is_none() && self.ssh_debug_flags.is_none()
    }
}

impl Config {
    pub(crate) fn initialized(
        peer_path: PathBuf,
        peer_ssh: Option<String>,
        rsync: PathBuf,
        ssh: Option<PathBuf>,
    ) -> Self {
        Self {
            local_mailbox: PathBuf::from("mailbox"),
            peer: Peer {
                path: peer_path,
                ssh: peer_ssh,
            },
            tools: Tools { rsync, ssh },
            debug: DebugConfig::default(),
        }
    }

    pub(crate) fn to_toml(&self) -> Result<String, String> {
        self.validate()
            .map_err(|error| format!("invalid initial configuration: {error}"))?;
        toml::to_string_pretty(self)
            .map_err(|error| format!("cannot serialize configuration: {error}"))
    }

    fn validate(&self) -> Result<(), String> {
        if self.local_mailbox.as_os_str().is_empty() {
            return Err("local_mailbox must not be empty".into());
        }
        if self.peer.path.as_os_str().is_empty() {
            return Err("peer.path must not be empty".into());
        }
        if matches!(self.peer.ssh.as_deref(), Some("")) {
            return Err("peer.ssh must not be empty".into());
        }
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

pub(crate) struct LoadedConfig {
    pub(crate) config: Config,
    pub(crate) path: PathBuf,
    pub(crate) directory: PathBuf,
    pub(crate) selection: &'static str,
}

pub(crate) fn load_config(
    cwd: &Path,
    requested_config_path: Option<&Path>,
) -> Result<LoadedConfig, String> {
    let (resolved_config_path, selection) = match requested_config_path {
        Some(path) if path.is_absolute() => (path.to_path_buf(), "explicit --config PATH"),
        Some(path) => (cwd.join(path), "explicit --config PATH"),
        None => (cwd.join("seal.toml"), "default ./seal.toml"),
    };
    let source = fs::read_to_string(&resolved_config_path).map_err(|error| {
        format!(
            "cannot read configuration {}: {error}",
            resolved_config_path.display()
        )
    })?;
    let config: Config = toml::from_str(&source).map_err(|error| {
        format!(
            "invalid configuration {}: {error}",
            resolved_config_path.display()
        )
    })?;
    config.validate().map_err(|error| {
        format!(
            "invalid configuration {}: {error}",
            resolved_config_path.display()
        )
    })?;
    let config_directory = resolved_config_path
        .parent()
        .ok_or_else(|| {
            format!(
                "configuration has no parent directory: {}",
                resolved_config_path.display()
            )
        })?
        .to_path_buf();

    Ok(LoadedConfig {
        config,
        path: resolved_config_path,
        directory: config_directory,
        selection,
    })
}

pub(crate) fn resolve_local(config_dir: &Path, path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        config_dir.join(path)
    }
}

pub(crate) fn effective_debug_flags(flags: Option<&[String]>) -> String {
    format!(
        "{:?}",
        effective_debug_flag(flags).into_iter().collect::<Vec<_>>()
    )
}

pub(crate) fn effective_debug_flag(flags: Option<&[String]>) -> Option<&str> {
    match flags {
        None => Some("-v"),
        Some([]) => None,
        Some([flag]) => Some(flag),
        Some(_) => unreachable!("configuration debug flags were validated"),
    }
}
