// Generated from SEAL.org; edit the literate source instead.
use std::{
    env, fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Command, Output},
};

#[test]
fn visible_seed_behavior() {
    let binary = env!("CARGO_BIN_EXE_seal");

    let bare = Command::new(binary).output().unwrap();
    assert!(!bare.status.success());
    assert!(String::from_utf8_lossy(&bare.stderr).contains("Usage: seal [OPTIONS] [COMMAND]"));

    let help = Command::new(binary).arg("--help").output().unwrap();
    assert!(help.status.success());
    assert!(String::from_utf8_lossy(&help.stdout).contains("Usage: seal [OPTIONS] [COMMAND]"));

    let version = Command::new(binary).arg("--version").output().unwrap();
    assert!(version.status.success());
    assert_eq!(String::from_utf8_lossy(&version.stdout), "seal 0.1.0\n");

    let cwd = env!("CARGO_MANIFEST_DIR");
    let debug = Command::new(binary)
        .arg("--debug")
        .current_dir(cwd)
        .output()
        .unwrap();
    assert!(debug.status.success());
    assert_eq!(
        String::from_utf8_lossy(&debug.stderr),
        format!("[debug] :: cwd: {cwd}\n[debug] :: version: 0.1.0\n")
    );
}

#[test]
fn configuration_inspection() {
    let binary = env!("CARGO_BIN_EXE_seal");
    let fixtures = format!("{}/tests/fixtures", env!("CARGO_MANIFEST_DIR"));

    let local = Command::new(binary)
        .arg("cfg")
        .current_dir(format!("{fixtures}/local"))
        .output()
        .unwrap();
    assert!(local.status.success());
    let stdout = String::from_utf8_lossy(&local.stdout);
    assert!(stdout.contains("config selection: default ./seal.toml"));
    assert!(stdout.contains(&format!("local mailbox: {fixtures}/local/mailbox")));
    assert!(stdout.contains(&format!("peer path: {fixtures}/local/peer-mailbox")));
    assert!(stdout.contains("rsync tool: /run/current-system/sw/bin/rsync"));
    assert!(stdout.contains("rsync debug flags: []"));

    let ssh = Command::new(binary)
        .args(["--config", "ssh.toml", "cfg"])
        .current_dir(&fixtures)
        .output()
        .unwrap();
    assert!(ssh.status.success());
    let stdout = String::from_utf8_lossy(&ssh.stdout);
    assert!(stdout.contains("config selection: explicit --config PATH"));
    assert!(stdout.contains("peer kind: ssh"));
    assert!(stdout.contains("peer ssh: experiment.agent"));
    assert!(stdout.contains("peer path: /home/agent/mailbox"));
    assert!(stdout.contains("ssh tool: /run/current-system/sw/bin/ssh"));
    assert!(stdout.contains("rsync debug flags: [\"-v\"]"));
    assert!(stdout.contains("ssh debug flags: [\"-v\"]"));
    assert!(stdout.contains(
        "fixed transfer profile: [\"--recursive\", \"--links\", \"--perms\", \"--times\", \"--checksum\"]"
    ));

    let invalid = Command::new(binary)
        .args(["--config", "invalid.toml", "cfg"])
        .current_dir(&fixtures)
        .output()
        .unwrap();
    assert!(!invalid.status.success());
    assert!(String::from_utf8_lossy(&invalid.stderr).contains(
        "debug.rsync_debug_flags must be empty or contain exactly one of -v, -vv, or -vvv"
    ));
}

#[test]
fn configuration_rejects_empty_coordinates() {
    let root = test_root("empty-coordinates");
    let cases = [
        (
            "local-mailbox.toml",
            "local_mailbox = \"\"\n[peer]\npath = \"peer\"\n[tools]\nrsync = \"/bin/true\"\n",
            "local_mailbox must not be empty",
        ),
        (
            "peer-path.toml",
            "local_mailbox = \"mailbox\"\n[peer]\npath = \"\"\n[tools]\nrsync = \"/bin/true\"\n",
            "peer.path must not be empty",
        ),
        (
            "peer-ssh.toml",
            "local_mailbox = \"mailbox\"\n[peer]\npath = \"/peer\"\nssh = \"\"\n[tools]\nrsync = \"/bin/true\"\nssh = \"/bin/true\"\n",
            "peer.ssh must not be empty",
        ),
    ];

    for (name, source, expected) in cases {
        let path = root.join(name);
        fs::write(&path, source).unwrap();
        let output = Command::new(env!("CARGO_BIN_EXE_seal"))
            .args(["--config", path.to_str().unwrap(), "cfg"])
            .current_dir(&root)
            .output()
            .unwrap();
        assert!(!output.status.success());
        assert!(String::from_utf8_lossy(&output.stderr).contains(expected));
    }
}

#[test]
fn local_initialization() {
    let root = test_root("local-init");
    let tools = root.join("tools");
    let workspace = root.join("workspace");
    fs::create_dir_all(&tools).unwrap();
    fs::create_dir(&workspace).unwrap();
    let rsync = write_tool(&tools, "rsync");

    let output = run_seal(
        &root,
        &tools,
        &["--config", "workspace/seal.toml", "init", "../peer-mailbox"],
    );
    assert_success(&output);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains(&format!(
        "[info] :: created configuration: {}",
        workspace.join("seal.toml").display()
    )));
    assert!(stderr.contains(&format!(
        "[info] :: created mailbox: {}",
        workspace.join("mailbox").display()
    )));
    assert!(stderr.contains(&format!("[info] :: pinned rsync: {}", rsync.display())));
    assert!(workspace.join("mailbox").is_dir());
    let source = fs::read_to_string(workspace.join("seal.toml")).unwrap();
    assert!(source.contains("local_mailbox = \"mailbox\""));
    assert!(source.contains("path = \"../peer-mailbox\""));
    assert!(source.contains(&format!("rsync = {:?}", rsync.to_string_lossy())));
    assert!(!source.contains("ssh"));

    let parsed = run_seal(&workspace, &tools, &["cfg"]);
    assert_success(&parsed);
    assert!(String::from_utf8_lossy(&parsed.stdout).contains("peer kind: local"));
}

#[test]
fn ssh_initialization() {
    let root = test_root("ssh-init");
    let tools = root.join("tools");
    fs::create_dir(&tools).unwrap();
    let rsync = write_tool(&tools, "rsync");
    let ssh = write_tool(&tools, "ssh");

    let output = run_seal(
        &root,
        &tools,
        &["init", "/home/agent/mailbox", "--ssh", "experiment.agent"],
    );
    assert_success(&output);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains(&format!("[info] :: pinned rsync: {}", rsync.display())));
    assert!(stderr.contains(&format!("[info] :: pinned ssh: {}", ssh.display())));
    assert!(root.join("mailbox").is_dir());
    let source = fs::read_to_string(root.join("seal.toml")).unwrap();
    assert!(source.contains("path = \"/home/agent/mailbox\""));
    assert!(source.contains("ssh = \"experiment.agent\""));
    assert!(source.contains(&format!("rsync = {:?}", rsync.to_string_lossy())));
    assert!(source.contains(&format!("ssh = {:?}", ssh.to_string_lossy())));

    let parsed = run_seal(&root, &tools, &["cfg"]);
    assert_success(&parsed);
    let stdout = String::from_utf8_lossy(&parsed.stdout);
    assert!(stdout.contains("peer kind: ssh"));
    assert!(stdout.contains("peer ssh: experiment.agent"));
}

#[test]
fn initialization_preserves_tool_lookup_errors() {
    let root = test_root("init-tool-error");
    let tools = root.join("tools");
    fs::create_dir(&tools).unwrap();
    std::os::unix::fs::symlink("rsync", tools.join("rsync")).unwrap();

    let output = run_seal(&root, &tools, &["init", "peer"]);
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("cannot inspect rsync candidate"));
    assert!(!stderr.contains("cannot find executable rsync in PATH"));
    assert!(!root.join("seal.toml").exists());
    assert!(!root.join("mailbox").exists());
}

#[test]
fn initialization_skips_nonexecutable_tool_candidates() {
    let root = test_root("init-nonexec-tool");
    let nonexec_tools = root.join("nonexec-tools");
    let valid_tools = root.join("valid-tools");
    fs::create_dir(&nonexec_tools).unwrap();
    fs::create_dir(&valid_tools).unwrap();
    let nonexec = write_tool(&nonexec_tools, "rsync");
    let mut permissions = fs::metadata(&nonexec).unwrap().permissions();
    permissions.set_mode(0o644);
    fs::set_permissions(&nonexec, permissions).unwrap();
    let rsync = write_tool(&valid_tools, "rsync");
    let path = env::join_paths([&nonexec_tools, &valid_tools]).unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_seal"))
        .args(["init", "peer"])
        .env("PATH", path)
        .current_dir(&root)
        .output()
        .unwrap();
    assert_success(&output);
    let source = fs::read_to_string(root.join("seal.toml")).unwrap();
    assert!(source.contains(&format!("rsync = {:?}", rsync.to_string_lossy())));
}

#[test]
fn initialization_refuses_known_conflicts() {
    let root = test_root("init-conflicts");
    let tools = root.join("tools");
    fs::create_dir(&tools).unwrap();
    write_tool(&tools, "rsync");

    let config_conflict = root.join("config-conflict");
    fs::create_dir(&config_conflict).unwrap();
    fs::write(config_conflict.join("seal.toml"), "keep me\n").unwrap();
    let output = run_seal(&config_conflict, &tools, &["init", "peer"]);
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("configuration already exists"));
    assert_eq!(
        fs::read_to_string(config_conflict.join("seal.toml")).unwrap(),
        "keep me\n"
    );
    assert!(!config_conflict.join("mailbox").exists());

    let mailbox_conflict = root.join("mailbox-conflict");
    fs::create_dir(&mailbox_conflict).unwrap();
    fs::write(mailbox_conflict.join("mailbox"), "keep me\n").unwrap();
    let output = run_seal(&mailbox_conflict, &tools, &["init", "peer"]);
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("mailbox already exists"));
    assert!(!mailbox_conflict.join("seal.toml").exists());
    assert_eq!(
        fs::read_to_string(mailbox_conflict.join("mailbox")).unwrap(),
        "keep me\n"
    );
}

fn test_root(name: &str) -> PathBuf {
    let root = env::temp_dir().join(format!("seal-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir(&root).unwrap();
    root
}

fn run_seal(cwd: &Path, tools: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_seal"))
        .args(args)
        .env("PATH", tools)
        .current_dir(cwd)
        .output()
        .unwrap()
}

fn assert_success(output: &Output) {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn write_tool(directory: &Path, name: &str) -> PathBuf {
    let path = directory.join(name);
    fs::write(&path, "#!/bin/sh\nexit 0\n").unwrap();
    let mut permissions = fs::metadata(&path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&path, permissions).unwrap();
    path.canonicalize().unwrap()
}
