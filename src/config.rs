// Generated from SEAL.org; edit that file instead.

use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
};

pub const TRANSFER_FLAGS: &[&str] = &["--recursive", "--links", "--perms", "--times", "--checksum"];
pub const SSH_TRANSFER_FLAGS: &[&str] = &["--secluded-args"];

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawConfig {
    local_mailbox: Option<PathBuf>,
    peer: Option<RawPeer>,
    tools: Option<RawTools>,
    debug: Option<RawDebug>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawPeer {
    path: Option<PathBuf>,
    ssh: Option<String>,
    rsync: Option<PathBuf>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawTools {
    rsync: Option<PathBuf>,
    ssh: Option<PathBuf>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawDebug {
    rsync_debug_flags: Option<Vec<String>>,
    ssh_debug_flags: Option<Vec<String>>,
}

#[derive(Debug, Eq, PartialEq)]
pub struct LocalPath {
    pub configured: PathBuf,
    pub resolved: PathBuf,
}

#[derive(Debug, Eq, PartialEq)]
pub enum Peer {
    Local {
        path: LocalPath,
    },
    Ssh {
        path: PathBuf,
        destination: String,
        rsync: PathBuf,
    },
}

#[derive(Debug, Eq, PartialEq)]
pub struct Tools {
    pub rsync: PathBuf,
    pub ssh: Option<PathBuf>,
}

#[derive(Debug, Eq, PartialEq)]
pub struct DebugFlags {
    pub rsync: Vec<String>,
    pub ssh: Option<Vec<String>>,
}

#[derive(Debug, Eq, PartialEq)]
pub struct Config {
    pub local_mailbox: LocalPath,
    pub peer: Peer,
    pub tools: Tools,
    pub debug: DebugFlags,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SelectionReason {
    Default,
    Explicit,
}

impl SelectionReason {
    pub const fn description(self) -> &'static str {
        match self {
            Self::Default => "default ./seal.toml",
            Self::Explicit => "explicit --config",
        }
    }
}

#[derive(Debug, Eq, PartialEq)]
pub struct Selection {
    pub path: PathBuf,
    pub reason: SelectionReason,
}

impl Selection {
    pub fn new(current_dir: &Path, explicit: Option<&Path>) -> Self {
        let (configured, reason) = match explicit {
            Some(path) => (path, SelectionReason::Explicit),
            None => (Path::new("seal.toml"), SelectionReason::Default),
        };

        Self {
            path: resolve_local_path(current_dir, configured),
            reason,
        }
    }

    fn directory(&self) -> &Path {
        self.path
            .parent()
            .expect("an absolute selected configuration path has a parent")
    }
}

pub fn resolve_local_path(base: &Path, configured: &Path) -> PathBuf {
    if configured.is_absolute() {
        configured.to_path_buf()
    } else {
        base.join(configured)
    }
}

pub fn load(selection: &Selection) -> Result<Config, Vec<String>> {
    let source = fs::read_to_string(&selection.path).map_err(|error| {
        vec![format!(
            "cannot read configuration {}: {error}",
            selection.path.display()
        )]
    })?;
    parse(&source, selection.directory()).map_err(|errors| {
        errors
            .into_iter()
            .map(|error| format!("{}: {error}", selection.path.display()))
            .collect()
    })
}

#[derive(Serialize)]
struct InitialConfig<'a> {
    local_mailbox: &'static str,
    peer: InitialPeer<'a>,
    tools: InitialTools<'a>,
    debug: InitialDebug,
}

#[derive(Serialize)]
struct InitialPeer<'a> {
    path: &'a Path,
    #[serde(skip_serializing_if = "Option::is_none")]
    ssh: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    rsync: Option<&'a Path>,
}

#[derive(Serialize)]
struct InitialTools<'a> {
    rsync: &'a Path,
    #[serde(skip_serializing_if = "Option::is_none")]
    ssh: Option<&'a Path>,
}

#[derive(Serialize)]
struct InitialDebug {
    rsync_debug_flags: [&'static str; 1],
    #[serde(skip_serializing_if = "Option::is_none")]
    ssh_debug_flags: Option<[&'static str; 1]>,
}

pub fn render_initial(
    peer_path: &Path,
    ssh_destination: Option<&str>,
    peer_rsync: Option<&Path>,
    local_rsync: &Path,
    local_ssh: Option<&Path>,
    config_dir: &Path,
) -> Result<String, Vec<String>> {
    let initial = InitialConfig {
        local_mailbox: "mailbox",
        peer: InitialPeer {
            path: peer_path,
            ssh: ssh_destination,
            rsync: peer_rsync,
        },
        tools: InitialTools {
            rsync: local_rsync,
            ssh: local_ssh,
        },
        debug: InitialDebug {
            rsync_debug_flags: ["-v"],
            ssh_debug_flags: ssh_destination.map(|_| ["-v"]),
        },
    };
    let source = toml::to_string_pretty(&initial)
        .map_err(|error| vec![format!("cannot serialize initial configuration: {error}")])?;
    parse(&source, config_dir)?;
    Ok(source)
}

fn parse(source: &str, config_dir: &Path) -> Result<Config, Vec<String>> {
    let raw: RawConfig =
        toml::from_str(source).map_err(|error| vec![format!("invalid TOML: {error}")])?;
    validate(raw, config_dir)
}

fn validate(raw: RawConfig, config_dir: &Path) -> Result<Config, Vec<String>> {
    let mut errors = Vec::new();
    let local_mailbox =
        require(raw.local_mailbox, "missing local_mailbox", &mut errors).map(|configured| {
            LocalPath {
                resolved: resolve_local_path(config_dir, &configured),
                configured,
            }
        });
    let peer = raw.peer.unwrap_or_else(|| {
        errors.push("missing [peer] table".to_owned());
        RawPeer {
            path: None,
            ssh: None,
            rsync: None,
        }
    });
    let tools = raw.tools.unwrap_or_else(|| {
        errors.push("missing [tools] table".to_owned());
        RawTools {
            rsync: None,
            ssh: None,
        }
    });
    let debug = raw.debug.unwrap_or_default();

    let peer_path = require(peer.path, "missing peer.path", &mut errors);
    let local_rsync = require(tools.rsync, "missing tools.rsync", &mut errors);
    if let Some(path) = &local_rsync
        && !path.is_absolute()
    {
        errors.push("tools.rsync must be an absolute path".to_owned());
    }

    let rsync_debug = debug
        .rsync_debug_flags
        .unwrap_or_else(|| vec!["-v".to_owned()]);
    for flag in &rsync_debug {
        if !valid_rsync_debug_flag(flag) {
            errors.push(format!(
                "debug.rsync_debug_flags contains unsupported flag {flag:?}"
            ));
        }
    }

    let effective_peer = if let Some(destination) = peer.ssh {
        let peer_rsync = require(
            peer.rsync,
            "peer.rsync is required when peer.ssh is set",
            &mut errors,
        );
        if let Some(path) = &peer_rsync {
            validate_restricted_executable(path, "peer.rsync", &mut errors);
        }

        let local_ssh = require(
            tools.ssh,
            "tools.ssh is required when peer.ssh is set",
            &mut errors,
        );
        if let Some(path) = &local_ssh {
            validate_restricted_executable(path, "tools.ssh", &mut errors);
        }

        let ssh_debug = debug
            .ssh_debug_flags
            .unwrap_or_else(|| vec!["-v".to_owned()]);
        for flag in &ssh_debug {
            if !matches!(flag.as_str(), "-v" | "-vv" | "-vvv") {
                errors.push(format!(
                    "debug.ssh_debug_flags contains unsupported flag {flag:?}"
                ));
            }
        }

        (
            match (peer_path, peer_rsync) {
                (Some(path), Some(rsync)) => Some(Peer::Ssh {
                    path,
                    destination,
                    rsync,
                }),
                _ => None,
            },
            local_ssh,
            Some(ssh_debug),
        )
    } else {
        if peer.rsync.is_some() {
            errors.push("peer.rsync is invalid without peer.ssh".to_owned());
        }
        if tools.ssh.is_some() {
            errors.push("tools.ssh is invalid without peer.ssh".to_owned());
        }
        if debug.ssh_debug_flags.is_some() {
            errors.push("debug.ssh_debug_flags is invalid without peer.ssh".to_owned());
        }

        (
            peer_path.map(|configured| Peer::Local {
                path: LocalPath {
                    resolved: resolve_local_path(config_dir, &configured),
                    configured,
                },
            }),
            None,
            None,
        )
    };

    if !errors.is_empty() {
        return Err(errors);
    }

    Ok(Config {
        local_mailbox: local_mailbox.expect("validated local_mailbox"),
        peer: effective_peer.0.expect("validated peer"),
        tools: Tools {
            rsync: local_rsync.expect("validated tools.rsync"),
            ssh: effective_peer.1,
        },
        debug: DebugFlags {
            rsync: rsync_debug,
            ssh: effective_peer.2,
        },
    })
}

fn require<T>(value: Option<T>, message: &str, errors: &mut Vec<String>) -> Option<T> {
    if value.is_none() {
        errors.push(message.to_owned());
    }
    value
}

pub fn validate_restricted_executable_path(path: &Path, field: &str) -> Result<(), String> {
    let mut errors = Vec::new();
    validate_restricted_executable(path, field, &mut errors);
    match errors.pop() {
        Some(error) => Err(error),
        None => Ok(()),
    }
}

fn validate_restricted_executable(path: &Path, field: &str, errors: &mut Vec<String>) {
    let Some(value) = path.to_str() else {
        errors.push(format!("{field} is not valid UTF-8"));
        return;
    };
    let components: Vec<_> = value
        .strip_prefix('/')
        .unwrap_or(value)
        .split('/')
        .collect();
    let valid = path.is_absolute()
        && !components.is_empty()
        && components.iter().all(|component| {
            !component.is_empty()
                && !matches!(*component, "." | "..")
                && component.bytes().all(|byte| {
                    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'+' | b'-')
                })
        });

    if !valid {
        errors.push(format!(
            "{field} must be an absolute executable path with restricted components"
        ));
    }
}

fn valid_rsync_debug_flag(flag: &str) -> bool {
    flag == "--verbose"
        || flag
            .strip_prefix('-')
            .is_some_and(|rest| !rest.is_empty() && rest.bytes().all(|byte| byte == b'v'))
        || flag
            .strip_prefix("--info=")
            .is_some_and(|value| valid_rsync_categories(value, INFO_CATEGORIES))
        || flag
            .strip_prefix("--debug=")
            .is_some_and(|value| valid_rsync_categories(value, DEBUG_CATEGORIES))
}

const INFO_CATEGORIES: &[&str] = &[
    "backup", "copy", "del", "flist", "misc", "mount", "name", "nonreg", "progress", "remove",
    "skip", "stats", "symsafe", "all", "none",
];
const DEBUG_CATEGORIES: &[&str] = &[
    "acl", "backup", "bind", "chdir", "connect", "cmd", "del", "deltasum", "dup", "exit", "filter",
    "flist", "fuzzy", "genr", "hash", "hlink", "iconv", "io", "nstr", "own", "proto", "recv",
    "send", "time", "all", "none",
];

fn valid_rsync_categories(value: &str, allowed: &[&str]) -> bool {
    value.split(',').all(|setting| {
        let category = setting.trim_end_matches(|character: char| character.is_ascii_digit());
        let level = &setting[category.len()..];
        !category.is_empty()
            && (level.is_empty() || level.bytes().all(|byte| byte.is_ascii_digit()))
            && allowed
                .iter()
                .any(|allowed| category.eq_ignore_ascii_case(allowed))
    })
}

#[cfg(test)]
mod tests {
    use super::{DebugFlags, LocalPath, Peer, Selection, SelectionReason, Tools, parse};
    use std::path::{Path, PathBuf};

    const LOCAL: &str = r#"
local_mailbox = "mailbox"

[peer]
path = "../peer"

[tools]
rsync = "/usr/bin/rsync"
"#;

    const SSH: &str = r#"
local_mailbox = "mailbox"

[peer]
path = "/srv/mailbox"
ssh = "agent.example"
rsync = "/run/current-system/sw/bin/rsync"

[tools]
rsync = "/usr/bin/rsync"
ssh = "/usr/bin/ssh"

[debug]
rsync_debug_flags = []
ssh_debug_flags = ["-vv"]
"#;

    #[test]
    fn default_selection_is_only_cwd_seal_toml() {
        assert_eq!(
            Selection::new(Path::new("/work/project"), None),
            Selection {
                path: PathBuf::from("/work/project/seal.toml"),
                reason: SelectionReason::Default,
            }
        );
    }

    #[test]
    fn explicit_selection_joins_without_normalizing_dot_components() {
        assert_eq!(
            Selection::new(
                Path::new("/work/project"),
                Some(Path::new("cfg/../other.toml"))
            )
            .path,
            PathBuf::from("/work/project/cfg/../other.toml")
        );
    }

    #[test]
    fn local_config_resolves_both_local_paths_and_defaults_debug() {
        let config = parse(LOCAL, Path::new("/work/project")).expect("valid local config");

        assert_eq!(
            config.local_mailbox,
            LocalPath {
                configured: PathBuf::from("mailbox"),
                resolved: PathBuf::from("/work/project/mailbox"),
            }
        );
        assert_eq!(
            config.peer,
            Peer::Local {
                path: LocalPath {
                    configured: PathBuf::from("../peer"),
                    resolved: PathBuf::from("/work/project/../peer"),
                }
            }
        );
        assert_eq!(
            config.tools,
            Tools {
                rsync: PathBuf::from("/usr/bin/rsync"),
                ssh: None,
            }
        );
        assert_eq!(
            config.debug,
            DebugFlags {
                rsync: vec!["-v".to_owned()],
                ssh: None,
            }
        );
    }

    #[test]
    fn ssh_config_keeps_peer_path_peer_side_and_accepts_empty_flags() {
        let config = parse(SSH, Path::new("/work/project")).expect("valid SSH config");

        assert_eq!(
            config.peer,
            Peer::Ssh {
                path: PathBuf::from("/srv/mailbox"),
                destination: "agent.example".to_owned(),
                rsync: PathBuf::from("/run/current-system/sw/bin/rsync"),
            }
        );
        assert_eq!(config.debug.rsync, Vec::<String>::new());
        assert_eq!(config.debug.ssh, Some(vec!["-vv".to_owned()]));
    }

    #[test]
    fn missing_fields_are_reported_together() {
        let errors = parse("", Path::new("/work")).expect_err("config should be incomplete");

        assert_eq!(
            errors,
            [
                "missing local_mailbox",
                "missing [peer] table",
                "missing [tools] table",
                "missing peer.path",
                "missing tools.rsync",
            ]
        );
    }

    #[test]
    fn ssh_conditional_fields_are_reported_together() {
        let source = LOCAL.replace("path = \"../peer\"", "path = \"peer\"\nssh = \"agent\"");
        let errors = parse(&source, Path::new("/work")).expect_err("SSH fields should be required");

        assert_eq!(
            errors,
            [
                "peer.rsync is required when peer.ssh is set",
                "tools.ssh is required when peer.ssh is set",
            ]
        );
    }

    #[test]
    fn local_peer_rejects_ssh_only_fields() {
        let source = format!("{LOCAL}\n[debug]\nssh_debug_flags = [\"-v\"]\n")
            .replace(
                "[tools]\nrsync = \"/usr/bin/rsync\"",
                "[tools]\nrsync = \"/usr/bin/rsync\"\nssh = \"/usr/bin/ssh\"",
            )
            .replace(
                "path = \"../peer\"",
                "path = \"../peer\"\nrsync = \"/usr/bin/rsync\"",
            );
        let errors = parse(&source, Path::new("/work")).expect_err("SSH-only fields should fail");

        assert_eq!(
            errors,
            [
                "peer.rsync is invalid without peer.ssh",
                "tools.ssh is invalid without peer.ssh",
                "debug.ssh_debug_flags is invalid without peer.ssh",
            ]
        );
    }

    #[test]
    fn restricted_paths_reject_shell_and_ambiguous_components() {
        for invalid in [
            "rsync",
            "/usr//bin/rsync",
            "/usr/../bin/rsync",
            "/usr/bin/rsync -v",
        ] {
            let source = SSH.replace("/run/current-system/sw/bin/rsync", invalid);
            assert!(
                parse(&source, Path::new("/work")).is_err(),
                "accepted {invalid}"
            );
        }

        let source = SSH.replace("/usr/bin/ssh", "/usr/bin/ssh;true");
        assert!(parse(&source, Path::new("/work")).is_err());
    }

    #[test]
    fn local_tool_paths_must_be_absolute() {
        let errors = parse(
            &LOCAL.replace("/usr/bin/rsync", "bin/rsync"),
            Path::new("/work"),
        )
        .expect_err("relative tool should fail");
        assert_eq!(errors, ["tools.rsync must be an absolute path"]);
    }

    #[test]
    fn invalid_debug_flags_are_aggregated() {
        let source = SSH
            .replace(
                "rsync_debug_flags = []",
                "rsync_debug_flags = [\"--delete\"]",
            )
            .replace(
                "ssh_debug_flags = [\"-vv\"]",
                "ssh_debug_flags = [\"-oProxyCommand=x\"]",
            );
        let errors = parse(&source, Path::new("/work")).expect_err("behavior flags should fail");

        assert_eq!(errors.len(), 2);
        assert!(errors[0].contains("debug.rsync_debug_flags"));
        assert!(errors[1].contains("debug.ssh_debug_flags"));
    }

    #[test]
    fn rsync_debug_categories_are_validated_before_execution() {
        for invalid in [
            "--info=bogus",
            "--info=help",
            "--info=99",
            "--info=name,",
            "--debug=bogus",
            "--debug=help",
            "--debug=cmd?",
        ] {
            let source = SSH.replace(
                "rsync_debug_flags = []",
                &format!("rsync_debug_flags = [\"{invalid}\"]"),
            );
            assert!(
                parse(&source, Path::new("/work")).is_err(),
                "accepted {invalid}"
            );
        }

        let source = SSH.replace(
            "rsync_debug_flags = []",
            "rsync_debug_flags = [\"--info=name10,stats\", \"--debug=cmd99,io\"]",
        );
        assert!(parse(&source, Path::new("/work")).is_ok());
    }

    #[test]
    fn unknown_fields_are_rejected() {
        let error = parse(&format!("{LOCAL}\ndelete = true\n"), Path::new("/work"))
            .expect_err("unknown field should fail");
        assert!(error[0].contains("unknown field `delete`"));
    }
}
