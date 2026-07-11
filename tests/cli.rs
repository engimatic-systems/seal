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
            std::env::temp_dir().join(format!("seal-car003-{}-{number}", std::process::id()));
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

fn make_tool(directory: &TestDir, name: &str, marker: &Path) -> PathBuf {
    let tool = directory.write(
        &format!("tools/{name}"),
        &format!("#!/bin/sh\nprintf ran > {}\n", marker.display()),
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        fs::set_permissions(&tool, fs::Permissions::from_mode(0o755))
            .expect("fake tool should be executable");
    }
    tool
}

fn tool_path(directory: &TestDir) -> PathBuf {
    directory.path().join("tools")
}

#[test]
fn help_names_cfg_init_and_global_selection() {
    let output = seal().arg("--help").output().expect("seal should run");

    assert!(output.status.success());
    assert!(stdout(&output).contains("seal [OPTIONS] cfg"));
    assert!(stdout(&output).contains("seal [OPTIONS] init <PEER_PATH>"));
    assert!(stdout(&output).contains("--ssh <DEST>"));
    assert!(stdout(&output).contains("--peer-rsync <PATH>"));
    assert!(stdout(&output).contains("cfg               Inspect effective configuration"));
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

#[test]
fn init_local_creates_exact_round_tripping_workspace_without_execution() {
    let directory = TestDir::new();
    let marker = directory.path().join("tool-ran");
    let rsync = make_tool(&directory, "rsync", &marker);
    let peer = directory.path().join("peer-does-not-exist");

    let output = seal()
        .current_dir(directory.path())
        .env("PATH", "tools")
        .args(["init", "peer-does-not-exist"])
        .output()
        .expect("seal should run");

    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), "");
    assert_eq!(
        stderr(&output),
        format!(
            "[info] :: created configuration {}\n\
             [info] :: created mailbox {}\n",
            directory.path().join("seal.toml").display(),
            directory.path().join("mailbox").display()
        )
    );
    assert!(directory.path().join("mailbox").is_dir());
    assert!(!peer.exists(), "init created local peer directory");
    assert!(!marker.exists(), "init executed selected rsync");

    let expected = format!(
        "local_mailbox = \"mailbox\"\n\n\
         [peer]\n\
         path = \"peer-does-not-exist\"\n\n\
         [tools]\n\
         rsync = \"{}\"\n\n\
         [debug]\n\
         rsync_debug_flags = [\"-v\"]\n",
        rsync.display()
    );
    assert_eq!(
        fs::read_to_string(directory.path().join("seal.toml")).unwrap(),
        expected
    );

    let inspected = seal()
        .current_dir(directory.path())
        .arg("cfg")
        .output()
        .expect("seal cfg should run");
    assert!(inspected.status.success(), "{}", stderr(&inspected));
    assert!(stdout(&inspected).contains(&format!("tools.rsync = {rsync:?}\n")));
    assert!(stdout(&inspected).contains("peer.kind = local\n"));
    assert!(!marker.exists(), "cfg executed selected rsync");
}

#[test]
fn init_ssh_writes_exact_config_and_debug_plan_without_execution() {
    let directory = TestDir::new();
    let marker = directory.path().join("tool-ran");
    let rsync = make_tool(&directory, "rsync", &marker);
    let ssh = make_tool(&directory, "ssh", &marker);
    let peer_rsync = "/run/current-system/sw/bin/rsync";

    let output = seal()
        .current_dir(directory.path())
        .env("PATH", tool_path(&directory))
        .args([
            "--debug",
            "init",
            "/srv/agent/mailbox",
            "--ssh",
            "agent.alias",
            "--peer-rsync",
            peer_rsync,
        ])
        .output()
        .expect("seal should run");

    assert!(output.status.success(), "{}", stderr(&output));
    assert!(!marker.exists(), "init executed a local or peer tool");
    let expected = format!(
        "local_mailbox = \"mailbox\"\n\n\
         [peer]\n\
         path = \"/srv/agent/mailbox\"\n\
         ssh = \"agent.alias\"\n\
         rsync = \"{peer_rsync}\"\n\n\
         [tools]\n\
         rsync = \"{}\"\n\
         ssh = \"{}\"\n\n\
         [debug]\n\
         rsync_debug_flags = [\"-v\"]\n\
         ssh_debug_flags = [\"-v\"]\n",
        rsync.display(),
        ssh.display()
    );
    assert_eq!(
        fs::read_to_string(directory.path().join("seal.toml")).unwrap(),
        expected
    );
    let diagnostic = stderr(&output);
    assert!(diagnostic.contains("[debug] :: peer.kind = ssh\n"));
    assert!(diagnostic.contains("[debug] :: peer.ssh = \"agent.alias\"\n"));
    assert!(diagnostic.contains(&format!("[debug] :: peer.rsync = {peer_rsync:?}\n")));
    assert!(diagnostic.contains(&format!("[debug] :: tools.rsync = {rsync:?}\n")));
    assert!(diagnostic.contains(&format!("[debug] :: tools.ssh = {ssh:?}\n")));

    let inspected = seal()
        .current_dir(directory.path())
        .arg("cfg")
        .output()
        .expect("seal cfg should run");
    assert!(inspected.status.success(), "{}", stderr(&inspected));
    assert!(stdout(&inspected).contains("peer.kind = ssh\n"));
    assert!(stdout(&inspected).contains("debug.ssh_debug_flags = [\"-v\"]\n"));
}

#[test]
fn init_explicit_config_uses_existing_parent_and_sibling_mailbox() {
    let directory = TestDir::new();
    let marker = directory.path().join("tool-ran");
    let rsync = make_tool(&directory, "rsync", &marker);
    fs::create_dir(directory.path().join("selected")).unwrap();
    let config = directory.path().join("selected/custom.toml");

    let output = seal()
        .current_dir(directory.path())
        .env("PATH", tool_path(&directory))
        .args(["--config"])
        .arg(&config)
        .args(["init", "../peer"])
        .output()
        .expect("seal should run");

    assert!(output.status.success(), "{}", stderr(&output));
    assert!(config.is_file());
    assert!(directory.path().join("selected/mailbox").is_dir());
    assert!(!directory.path().join("seal.toml").exists());
    assert!(!directory.path().join("mailbox").exists());
    assert!(!marker.exists());

    let inspected = seal()
        .current_dir(directory.path())
        .args(["--config"])
        .arg(&config)
        .arg("cfg")
        .output()
        .expect("seal cfg should run");
    assert!(inspected.status.success(), "{}", stderr(&inspected));
    assert!(stdout(&inspected).contains(&format!("config.path = {config:?}\n")));
    assert!(stdout(&inspected).contains(&format!("tools.rsync = {rsync:?}\n")));
    assert!(stdout(&inspected).contains(&format!(
        "local_mailbox.resolved = {:?}\n",
        directory.path().join("selected/mailbox")
    )));
}

#[test]
fn init_rejects_invalid_ssh_flag_combinations_before_mutation() {
    for arguments in [
        vec!["init", "peer", "--ssh", "agent"],
        vec!["init", "peer", "--peer-rsync", "/usr/bin/rsync"],
        vec![
            "init",
            "peer",
            "--ssh",
            "agent",
            "--peer-rsync",
            "/usr/bin/rsync;false",
        ],
    ] {
        let directory = TestDir::new();
        let output = seal()
            .current_dir(directory.path())
            .env("PATH", directory.path())
            .args(arguments)
            .output()
            .expect("seal should run");

        assert!(!output.status.success());
        assert!(!directory.path().join("seal.toml").exists());
        assert!(!directory.path().join("mailbox").exists());
    }
}

#[test]
fn init_missing_required_local_tools_leaves_no_state() {
    let local = TestDir::new();
    let output = seal()
        .current_dir(local.path())
        .env("PATH", local.path())
        .args(["init", "peer"])
        .output()
        .expect("seal should run");
    assert_eq!(output.status.code(), Some(1));
    assert!(stderr(&output).contains("cannot find executable rsync in PATH"));
    assert!(!local.path().join("seal.toml").exists());
    assert!(!local.path().join("mailbox").exists());

    let remote = TestDir::new();
    let marker = remote.path().join("rsync-ran");
    make_tool(&remote, "rsync", &marker);
    let output = seal()
        .current_dir(remote.path())
        .env("PATH", tool_path(&remote))
        .args([
            "init",
            "peer",
            "--ssh",
            "agent",
            "--peer-rsync",
            "/usr/bin/rsync",
        ])
        .output()
        .expect("seal should run");
    assert_eq!(output.status.code(), Some(1));
    assert!(stderr(&output).contains("cannot find executable ssh in PATH"));
    assert!(!remote.path().join("seal.toml").exists());
    assert!(!remote.path().join("mailbox").exists());
    assert!(!marker.exists(), "rsync lookup executed the candidate");
}

#[cfg(unix)]
#[test]
fn init_rejects_every_existing_config_entry_shape() {
    use std::os::unix::fs::symlink;

    for shape in ["file", "directory", "symlink", "dangling-symlink"] {
        let directory = TestDir::new();
        let marker = directory.path().join("tool-ran");
        make_tool(&directory, "rsync", &marker);
        let config = directory.path().join("seal.toml");
        match shape {
            "file" => fs::write(&config, "operator state\n").unwrap(),
            "directory" => fs::create_dir(&config).unwrap(),
            "symlink" => {
                fs::write(directory.path().join("operator-target"), "state\n").unwrap();
                symlink("operator-target", &config).unwrap();
            }
            "dangling-symlink" => symlink("missing-target", &config).unwrap(),
            _ => unreachable!(),
        }

        let output = seal()
            .current_dir(directory.path())
            .env("PATH", tool_path(&directory))
            .args(["init", "peer"])
            .output()
            .expect("seal should run");

        assert_eq!(output.status.code(), Some(1), "shape {shape}");
        assert!(stderr(&output).contains("configuration target already exists"));
        assert!(fs::symlink_metadata(&config).is_ok(), "removed {shape}");
        assert!(!directory.path().join("mailbox").exists());
        assert!(!marker.exists());
    }
}

#[cfg(unix)]
#[test]
fn init_rejects_every_existing_mailbox_entry_shape() {
    use std::os::unix::fs::symlink;

    for shape in ["file", "directory", "symlink", "dangling-symlink"] {
        let directory = TestDir::new();
        let marker = directory.path().join("tool-ran");
        make_tool(&directory, "rsync", &marker);
        let mailbox = directory.path().join("mailbox");
        match shape {
            "file" => fs::write(&mailbox, "operator state\n").unwrap(),
            "directory" => fs::create_dir(&mailbox).unwrap(),
            "symlink" => {
                fs::create_dir(directory.path().join("operator-mailbox")).unwrap();
                symlink("operator-mailbox", &mailbox).unwrap();
            }
            "dangling-symlink" => symlink("missing-mailbox", &mailbox).unwrap(),
            _ => unreachable!(),
        }

        let output = seal()
            .current_dir(directory.path())
            .env("PATH", tool_path(&directory))
            .args(["init", "peer"])
            .output()
            .expect("seal should run");

        assert_eq!(output.status.code(), Some(1), "shape {shape}");
        assert!(stderr(&output).contains("mailbox target already exists"));
        assert!(fs::symlink_metadata(&mailbox).is_ok(), "removed {shape}");
        assert!(!directory.path().join("seal.toml").exists());
        assert!(!marker.exists());
    }
}

#[test]
fn init_requires_an_existing_directory_config_parent() {
    let directory = TestDir::new();
    let marker = directory.path().join("tool-ran");
    make_tool(&directory, "rsync", &marker);

    for config in [
        directory.path().join("missing/seal.toml"),
        directory.path().join("blocked/seal.toml"),
    ] {
        fs::write(directory.path().join("blocked"), "not a directory\n").unwrap();
        let output = seal()
            .current_dir(directory.path())
            .env("PATH", tool_path(&directory))
            .args(["--config"])
            .arg(&config)
            .args(["init", "peer"])
            .output()
            .expect("seal should run");
        assert_eq!(output.status.code(), Some(1));
        assert!(!directory.path().join("mailbox").exists());
        fs::remove_file(directory.path().join("blocked")).unwrap();
    }
    assert!(!marker.exists());
}

#[test]
fn init_rejects_config_mailbox_alias_before_mutation_or_tool_lookup() {
    let directory = TestDir::new();
    fs::create_dir(directory.path().join("nested")).unwrap();

    for config in ["mailbox", "./mailbox", "nested/../mailbox"] {
        let output = seal()
            .current_dir(directory.path())
            .env("PATH", directory.path())
            .args(["--config", config, "init", "peer"])
            .output()
            .expect("seal should run");

        assert_eq!(output.status.code(), Some(1), "alias {config}");
        assert!(stderr(&output).contains("configuration target aliases mailbox target"));
        assert!(!directory.path().join("mailbox").exists());
        assert!(!directory.path().join("seal.toml").exists());
    }
}

#[cfg(unix)]
#[test]
fn init_reports_atomic_mailbox_creation_failure_without_partial_state() {
    use std::os::unix::fs::PermissionsExt;

    let directory = TestDir::new();
    let marker = directory.path().join("tool-ran");
    make_tool(&directory, "rsync", &marker);
    let parent = directory.path().join("readonly");
    fs::create_dir(&parent).unwrap();
    fs::set_permissions(&parent, fs::Permissions::from_mode(0o555)).unwrap();

    let output = seal()
        .current_dir(directory.path())
        .env("PATH", tool_path(&directory))
        .args(["--config"])
        .arg(parent.join("seal.toml"))
        .args(["init", "peer"])
        .output()
        .expect("seal should run");

    assert_eq!(output.status.code(), Some(1));
    assert!(stderr(&output).contains("cannot create mailbox"));
    assert!(!parent.join("seal.toml").exists());
    assert!(!parent.join("mailbox").exists());
    assert!(!marker.exists());
    fs::set_permissions(&parent, fs::Permissions::from_mode(0o755)).unwrap();
}

#[cfg(unix)]
#[test]
fn init_uses_effective_user_execute_access_not_any_mode_bit() {
    use std::os::unix::fs::PermissionsExt;

    let directory = TestDir::new();
    let tool = directory.write("wrong-class/rsync", "#!/bin/sh\nexit 0\n");
    fs::set_permissions(&tool, fs::Permissions::from_mode(0o010)).unwrap();

    let output = seal()
        .current_dir(directory.path())
        .env("PATH", directory.path().join("wrong-class"))
        .args(["init", "peer"])
        .output()
        .expect("seal should run");

    assert_eq!(output.status.code(), Some(1));
    assert!(stderr(&output).contains("cannot find executable rsync in PATH"));
    assert!(!directory.path().join("mailbox").exists());
    assert!(!directory.path().join("seal.toml").exists());
}

#[cfg(unix)]
#[test]
fn init_pins_path_symlink_without_canonicalizing_or_executing_it() {
    use std::os::unix::fs::symlink;

    let directory = TestDir::new();
    let marker = directory.path().join("tool-ran");
    let real = directory.write(
        "real/rsync",
        &format!("#!/bin/sh\nprintf ran > {}\n", marker.display()),
    );
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&real, fs::Permissions::from_mode(0o755)).unwrap();
    fs::create_dir(directory.path().join("linked-tools")).unwrap();
    symlink(&real, directory.path().join("linked-tools/rsync")).unwrap();

    let output = seal()
        .current_dir(directory.path())
        .env("PATH", directory.path().join("linked-tools"))
        .args(["init", "peer"])
        .output()
        .expect("seal should run");

    assert!(output.status.success(), "{}", stderr(&output));
    let lexical = directory.path().join("linked-tools/rsync");
    let source = fs::read_to_string(directory.path().join("seal.toml")).unwrap();
    assert!(source.contains(&format!("rsync = \"{}\"", lexical.display())));
    assert!(!source.contains(&format!("rsync = \"{}\"", real.display())));
    assert!(!marker.exists());
}
