// Generated from SEAL.org; edit the literate source instead.
use std::{
    ffi::{OsStr, OsString},
    fmt, io,
    os::unix::ffi::{OsStrExt, OsStringExt},
    path::{Path, PathBuf},
    process::{Command, ExitStatus},
};

use crate::config::{Config, effective_debug_flag};

pub(crate) const FIXED_TRANSFER_FLAGS: &[&str] =
    &["--recursive", "--links", "--perms", "--times", "--checksum"];
const SSH_TRANSFER_FLAGS: &[&str] = &["--secluded-args"];
const REMOTE_SHELL_FLAG: &str = "--rsh";

pub(crate) struct ProcessPlan {
    executable: PathBuf,
    argv: Vec<OsString>,
}

impl ProcessPlan {
    pub(crate) fn executable(&self) -> &Path {
        &self.executable
    }

    pub(crate) fn argv(&self) -> &[OsString] {
        &self.argv
    }

    pub(crate) fn execute(&self) -> io::Result<ExitStatus> {
        Command::new(&self.executable).args(&self.argv).status()
    }
}

#[derive(Debug)]
pub(crate) enum PlanError {
    MissingSshTool,
    UnrepresentableSshTool,
}

impl fmt::Display for PlanError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingSshTool => formatter.write_str("an SSH peer requires tools.ssh"),
            Self::UnrepresentableSshTool => formatter.write_str("tools.ssh contains a null byte"),
        }
    }
}

// Rsync splits --rsh itself: quotes group one word and a doubled quote emits
// that quote. This is deliberately rsync grammar, not POSIX shell quoting.
fn quote_remote_shell_word(value: &OsStr) -> Result<OsString, PlanError> {
    if value.as_bytes().contains(&0) {
        return Err(PlanError::UnrepresentableSshTool);
    }

    let mut quoted = Vec::with_capacity(value.as_bytes().len() + 2);
    quoted.push(b'\'');
    for byte in value.as_bytes() {
        quoted.push(*byte);
        if *byte == b'\'' {
            quoted.push(b'\'');
        }
    }
    quoted.push(b'\'');
    Ok(OsString::from_vec(quoted))
}

fn trailing_slash(path: &Path) -> OsString {
    let mut value = path.as_os_str().to_os_string();
    if !has_trailing_slash(&value) {
        value.push("/");
    }
    value
}

// Encoded bytes preserve ASCII slash identity without requiring Unicode paths.
fn has_trailing_slash(value: &OsStr) -> bool {
    value.as_encoded_bytes().ends_with(b"/")
}

pub(crate) fn plan_pull(
    config: &Config,
    peer_path: &Path,
    local_mailbox: &Path,
    debug_enabled: bool,
    dry_run: bool,
) -> Result<ProcessPlan, PlanError> {
    // Profile controls precede transport-specific arguments.
    let mut argv: Vec<OsString> = FIXED_TRANSFER_FLAGS.iter().map(OsString::from).collect();
    if debug_enabled {
        if let Some(flag) = effective_debug_flag(config.debug.rsync_debug_flags.as_deref()) {
            argv.push(flag.into());
        }
    }
    if dry_run {
        argv.push("--dry-run".into());
    }

    // SSH coordinates stay opaque here; rsync owns their remote interpretation.
    let source = match &config.peer.ssh {
        Some(destination) => {
            argv.extend(SSH_TRANSFER_FLAGS.iter().map(OsString::from));
            let ssh = config
                .tools
                .ssh
                .as_deref()
                .ok_or(PlanError::MissingSshTool)?;
            let mut remote_shell = quote_remote_shell_word(ssh.as_os_str())?;
            if debug_enabled {
                if let Some(flag) = effective_debug_flag(config.debug.ssh_debug_flags.as_deref()) {
                    remote_shell.push(" ");
                    remote_shell.push(flag);
                }
            }
            remote_shell.push(" --");
            argv.push(REMOTE_SHELL_FLAG.into());
            argv.push(remote_shell);

            let mut source = OsString::from(destination);
            source.push(":");
            source.push(trailing_slash(peer_path));
            source
        }
        None => trailing_slash(peer_path),
    };

    // The terminator fixes the remaining operands as pull source then destination.
    argv.push("--".into());
    argv.push(source);
    argv.push(trailing_slash(local_mailbox));
    Ok(ProcessPlan {
        executable: config.tools.rsync.clone(),
        argv,
    })
}
