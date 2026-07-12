// Generated from SEAL.org; edit the literate source instead.
use std::{
    fs,
    path::{Path, PathBuf},
};

use serde::Deserialize;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Config {
    pub(crate) local_mailbox: PathBuf,
    pub(crate) peer: Peer,
    pub(crate) tools: Tools,
    #[serde(default)]
    pub(crate) debug: DebugConfig,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Peer {
    pub(crate) path: PathBuf,
    pub(crate) ssh: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Tools {
    pub(crate) rsync: PathBuf,
    pub(crate) ssh: Option<PathBuf>,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct DebugConfig {
    pub(crate) rsync_debug_flags: Option<Vec<String>>,
    pub(crate) ssh_debug_flags: Option<Vec<String>>,
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

pub(crate) struct LoadedConfig {
    pub(crate) config: Config,
    pub(crate) path: PathBuf,
    pub(crate) selection: &'static str,
}

pub(crate) fn load_config(
    cwd: &Path,
    explicit_path: Option<&Path>,
) -> Result<LoadedConfig, String> {
    let (config_path, selection) = match explicit_path {
        Some(path) if path.is_absolute() => (path.to_path_buf(), "explicit --config PATH"),
        Some(path) => (cwd.join(path), "explicit --config PATH"),
        None => (cwd.join("seal.toml"), "default ./seal.toml"),
    };
    let source = fs::read_to_string(&config_path).map_err(|error| {
        format!(
            "cannot read configuration {}: {error}",
            config_path.display()
        )
    })?;
    let config: Config = toml::from_str(&source)
        .map_err(|error| format!("invalid configuration {}: {error}", config_path.display()))?;
    config
        .validate()
        .map_err(|error| format!("invalid configuration {}: {error}", config_path.display()))?;

    Ok(LoadedConfig {
        config,
        path: config_path,
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
    match flags {
        Some(flags) => format!("{flags:?}"),
        None => "[\"-v\"]".into(),
    }
}
