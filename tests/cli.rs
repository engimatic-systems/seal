// Generated from SEAL.org; edit that file instead.

use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Output},
    sync::atomic::{AtomicU64, Ordering},
};

static NEXT_DIRECTORY: AtomicU64 = AtomicU64::new(0);

struct TestDir(PathBuf);

impl TestDir {
    fn new() -> Self {
        let number = NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed);
        let path =
            std::env::temp_dir().join(format!("seal-car002-{}-{number}", std::process::id()));
        fs::create_dir_all(&path).expect("test directory should be created");
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }

    fn write(&self, relative: &str, contents: &str) -> PathBuf {
        let path = self.0.join(relative);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("fixture parent should be created");
        }
        fs::write(&path, contents).expect("fixture should be written");
        path
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).expect("test directory should be removed");
    }
}

fn seal() -> Command {
    Command::new(env!("CARGO_BIN_EXE_seal"))
}

fn stdout(output: &Output) -> &str {
    std::str::from_utf8(&output.stdout).expect("stdout should be UTF-8")
}

fn stderr(output: &Output) -> &str {
    std::str::from_utf8(&output.stderr).expect("stderr should be UTF-8")
}

fn local_config(rsync: &Path) -> String {
    format!(
        r#"local_mailbox = "mailbox"

[peer]
path = "peer-mailbox"

[tools]
rsync = "{}"
"#,
        rsync.display()
    )
}

#[test]
fn help_names_cfg_and_global_selection() {
    let output = seal().arg("--help").output().expect("seal should run");

    assert!(output.status.success());
    assert!(stdout(&output).contains("Usage: seal [OPTIONS] <COMMAND>"));
    assert!(stdout(&output).contains("cfg  Inspect effective configuration"));
    assert!(stdout(&output).contains("--config <PATH>"));
    assert_eq!(stderr(&output), "");
}

#[test]
fn version_does_not_load_configuration() {
    let directory = TestDir::new();
    let output = seal()
        .current_dir(directory.path())
        .arg("--version")
        .output()
        .expect("seal should run");

    assert!(output.status.success());
    assert_eq!(
        stdout(&output),
        format!("seal {}\n", env!("CARGO_PKG_VERSION"))
    );
    assert_eq!(stderr(&output), "");
}

#[test]
fn debug_version_retains_seed_process_facts() {
    let directory = TestDir::new();
    let output = seal()
        .current_dir(directory.path())
        .args(["--debug", "--version"])
        .output()
        .expect("seal should run");

    assert!(output.status.success());
    assert_eq!(
        stderr(&output),
        format!(
            "[debug] :: process working directory: {}\n\
             [debug] :: Seal version: {}\n",
            directory.path().display(),
            env!("CARGO_PKG_VERSION")
        )
    );
}

#[test]
fn invalid_control_argument_remains_one_canonical_record() {
    let output = seal()
        .arg("--unknown\n\u{1b}[31m[error] :: forged")
        .output()
        .expect("seal should run");

    assert_eq!(output.status.code(), Some(2));
    assert_eq!(stdout(&output), "");
    assert_eq!(
        stderr(&output),
        "[error] :: unrecognized argument: --unknown\\n\\u{1b}[31m[error] :: forged\n"
    );
    assert_eq!(stderr(&output).lines().count(), 1);
}

#[test]
fn cfg_reports_default_local_configuration() {
    let directory = TestDir::new();
    directory.write("seal.toml", &local_config(Path::new("/not-run/rsync")));
    let local_mailbox = directory.path().join("mailbox");
    let peer_mailbox = directory.path().join("peer-mailbox");
    assert!(!local_mailbox.exists());
    assert!(!peer_mailbox.exists());

    let output = seal()
        .current_dir(directory.path())
        .arg("cfg")
        .output()
        .expect("seal should run");

    assert!(output.status.success(), "{}", stderr(&output));
    let ordinary = stdout(&output);
    assert!(ordinary.contains(&format!(
        "config.path = {:?}\n",
        directory.path().join("seal.toml")
    )));
    assert!(ordinary.contains("config.selection = default ./seal.toml\n"));
    assert!(ordinary.contains("local_mailbox.configured = \"mailbox\"\n"));
    assert!(ordinary.contains(&format!(
        "local_mailbox.resolved = {:?}\n",
        directory.path().join("mailbox")
    )));
    assert!(ordinary.contains("peer.kind = local\n"));
    assert!(ordinary.contains(&format!("peer.path.resolved = {peer_mailbox:?}\n")));
    assert!(ordinary.contains("tools.rsync = \"/not-run/rsync\"\n"));
    assert!(ordinary.contains("debug.rsync_debug_flags = [\"-v\"]\n"));
    assert!(ordinary.contains("transfer.profile = seal-v0-fixed\n"));
    assert!(ordinary.contains(
        "transfer.flags = [\"--recursive\", \"--links\", \"--perms\", \"--times\", \"--checksum\"]\n"
    ));
    assert_eq!(stderr(&output), "");
    assert!(!local_mailbox.exists(), "cfg created the local mailbox");
    assert!(!peer_mailbox.exists(), "cfg created the peer mailbox");
}

#[test]
fn explicit_config_wins_over_existing_invalid_default() {
    let directory = TestDir::new();
    directory.write("seal.toml", "unknown = true\n");
    let explicit = directory.write("selected.toml", &local_config(Path::new("/not-run/rsync")));

    let output = seal()
        .current_dir(directory.path())
        .args(["--config"])
        .arg(&explicit)
        .arg("cfg")
        .output()
        .expect("seal should run");

    assert!(output.status.success(), "{}", stderr(&output));
    assert!(stdout(&output).contains("config.selection = explicit --config\n"));
    assert!(stdout(&output).contains(&format!("config.path = {explicit:?}\n")));
}

#[test]
fn cfg_reports_explicit_ssh_configuration_and_debug_facts() {
    let directory = TestDir::new();
    let config_path = directory.write(
        "configuration/ssh.toml",
        r#"local_mailbox = "../mailbox"

[peer]
path = "relative/on-peer"
ssh = "agent.alias"
rsync = "/run/current-system/sw/bin/rsync"

[tools]
rsync = "/run/current-system/sw/bin/rsync"
ssh = "/run/current-system/sw/bin/ssh"

[debug]
rsync_debug_flags = ["--info=name"]
ssh_debug_flags = []
"#,
    );

    let output = seal()
        .current_dir(directory.path())
        .args(["--debug", "--config"])
        .arg(&config_path)
        .arg("cfg")
        .output()
        .expect("seal should run");

    assert!(output.status.success(), "{}", stderr(&output));
    assert!(stdout(&output).contains("config.selection = explicit --config\n"));
    assert!(stdout(&output).contains("peer.kind = ssh\n"));
    assert!(stdout(&output).contains("peer.path = \"relative/on-peer\"\n"));
    assert!(stdout(&output).contains("peer.ssh = \"agent.alias\"\n"));
    assert!(stdout(&output).contains("peer.rsync = \"/run/current-system/sw/bin/rsync\"\n"));
    assert!(stdout(&output).contains("tools.ssh = \"/run/current-system/sw/bin/ssh\"\n"));
    assert!(stdout(&output).contains("debug.rsync_debug_flags = [\"--info=name\"]\n"));
    assert!(stdout(&output).contains("debug.ssh_debug_flags = []\n"));
    assert!(stderr(&output).contains("[debug] :: config.selection = explicit --config\n"));
    assert!(stderr(&output).contains("[debug] :: peer.path = \"relative/on-peer\"\n"));
}

#[test]
fn cfg_escapes_operator_values_that_could_forge_records() {
    let directory = TestDir::new();
    directory.write(
        "seal.toml",
        r#"local_mailbox = "mailbox"

[peer]
path = "/srv/mailbox"
ssh = """agent
peer.kind = local"""
rsync = "/usr/bin/rsync"

[tools]
rsync = "/usr/bin/rsync"
ssh = "/usr/bin/ssh"
"#,
    );

    let output = seal()
        .current_dir(directory.path())
        .arg("cfg")
        .output()
        .expect("seal should run");

    assert!(output.status.success(), "{}", stderr(&output));
    assert!(stdout(&output).contains("peer.ssh = \"agent\\npeer.kind = local\"\n"));
    assert_eq!(
        stdout(&output)
            .lines()
            .filter(|line| line.starts_with("peer.kind = "))
            .count(),
        1
    );
}

#[test]
fn cfg_reports_independent_validation_errors_together() {
    let directory = TestDir::new();
    directory.write(
        "seal.toml",
        r#"[peer]
path = "mailbox"
ssh = "agent"
rsync = "/usr/bin/rsync;false"

[tools]
rsync = "rsync"
ssh = "/usr/../bin/ssh"

[debug]
rsync_debug_flags = ["--delete"]
ssh_debug_flags = ["-oProxyCommand=false"]
"#,
    );

    let output = seal()
        .current_dir(directory.path())
        .arg("cfg")
        .output()
        .expect("seal should run");

    assert_eq!(output.status.code(), Some(1));
    assert_eq!(stdout(&output), "");
    let prefix = format!(
        "[error] :: {}:",
        directory.path().join("seal.toml").display()
    );
    assert_eq!(
        stderr(&output),
        format!(
            "{prefix} missing local_mailbox\n\
             {prefix} tools.rsync must be an absolute path\n\
             {prefix} debug.rsync_debug_flags contains unsupported flag \"--delete\"\n\
             {prefix} peer.rsync must be an absolute executable path with restricted components\n\
             {prefix} tools.ssh must be an absolute executable path with restricted components\n\
             {prefix} debug.ssh_debug_flags contains unsupported flag \"-oProxyCommand=false\"\n"
        )
    );
}

#[cfg(unix)]
#[test]
fn cfg_invokes_no_configured_or_path_process() {
    use std::os::unix::fs::PermissionsExt;

    let directory = TestDir::new();
    let marker = directory.path().join("process-ran");
    let spy = directory.write(
        "spies/rsync",
        &format!("#!/bin/sh\nprintf ran > {}\n", marker.display()),
    );
    fs::set_permissions(&spy, fs::Permissions::from_mode(0o755)).expect("spy should be executable");
    directory.write("seal.toml", &local_config(&spy));

    let output = seal()
        .current_dir(directory.path())
        .env("PATH", spy.parent().unwrap())
        .arg("cfg")
        .output()
        .expect("seal should run");

    assert!(output.status.success(), "{}", stderr(&output));
    assert!(!marker.exists(), "cfg executed an external process");
}
