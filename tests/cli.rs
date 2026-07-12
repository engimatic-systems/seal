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

#[test]
fn exact_local_and_ssh_pull_plans() {
    let root = test_root("pull-plans");
    let tools = root.join("tools");
    fs::create_dir(&tools).unwrap();
    let rsync = write_tool(&tools, "rsync");
    fs::write(&rsync, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n").unwrap();
    let ssh = write_tool(&tools, "ssh");

    let local = root.join("local");
    fs::create_dir(&local).unwrap();
    fs::write(
        local.join("seal.toml"),
        format!(
            "local_mailbox = \"mailbox\"\n\n[peer]\npath = \"peer\"\n\n[tools]\nrsync = {:?}\n\n[debug]\nrsync_debug_flags = [\"-vv\"]\n",
            rsync.to_string_lossy()
        ),
    )
    .unwrap();
    let local_output = run_seal(&local, &tools, &["--debug", "pull", "--dry-run"]);
    assert_success(&local_output);
    let local_args = vec![
        "--recursive".to_string(),
        "--links".to_string(),
        "--perms".to_string(),
        "--times".to_string(),
        "--checksum".to_string(),
        "-vv".to_string(),
        "--dry-run".to_string(),
        "--".to_string(),
        format!("{}/peer/", local.display()),
        format!("{}/mailbox/", local.display()),
    ];
    assert_eq!(
        String::from_utf8_lossy(&local_output.stdout),
        format!("{}\n", local_args.join("\n"))
    );
    assert!(
        String::from_utf8_lossy(&local_output.stderr).contains(&format!(
            "[debug] :: rsync executable: {:?}\n[debug] :: rsync argv: {:?}\n",
            rsync, local_args
        ))
    );

    let remote = root.join("remote");
    fs::create_dir(&remote).unwrap();
    fs::write(
        remote.join("seal.toml"),
        format!(
            "local_mailbox = \"mailbox\"\n\n[peer]\npath = \"/peer/mailbox\"\nssh = \"-v\"\n\n[tools]\nrsync = {:?}\nssh = {:?}\n\n[debug]\nrsync_debug_flags = [\"-vvv\"]\nssh_debug_flags = [\"-vv\"]\n",
            rsync.to_string_lossy(),
            ssh.to_string_lossy()
        ),
    )
    .unwrap();
    let remote_output = run_seal(&remote, &tools, &["--debug", "pull"]);
    assert_success(&remote_output);
    let remote_args = vec![
        "--recursive".to_string(),
        "--links".to_string(),
        "--perms".to_string(),
        "--times".to_string(),
        "--checksum".to_string(),
        "-vvv".to_string(),
        "--secluded-args".to_string(),
        "--rsh".to_string(),
        format!("'{}' -vv --", ssh.display()),
        "--".to_string(),
        "-v:/peer/mailbox/".to_string(),
        format!("{}/mailbox/", remote.display()),
    ];
    assert_eq!(
        String::from_utf8_lossy(&remote_output.stdout),
        format!("{}\n", remote_args.join("\n"))
    );
    assert!(
        String::from_utf8_lossy(&remote_output.stderr).contains(&format!(
            "[debug] :: rsync executable: {:?}\n[debug] :: rsync argv: {:?}\n",
            rsync, remote_args
        ))
    );
}

#[test]
fn pull_preserves_child_failure_status() {
    let root = test_root("pull-failure");
    let tools = root.join("tools");
    fs::create_dir(&tools).unwrap();
    let rsync = write_tool(&tools, "rsync");
    fs::write(&rsync, "#!/bin/sh\nexit 23\n").unwrap();
    fs::write(
        root.join("seal.toml"),
        format!(
            "local_mailbox = \"mailbox\"\n\n[peer]\npath = \"peer\"\n\n[tools]\nrsync = {:?}\n",
            rsync.to_string_lossy()
        ),
    )
    .unwrap();

    let output = run_seal(&root, &tools, &["pull"]);
    assert_eq!(output.status.code(), Some(23));
}

#[test]
fn real_rsync_decodes_quoted_ssh_and_terminates_its_options() {
    let root = test_root("quoted-ssh");
    let ssh_tools = root.join("ssh tools '\"quoted");
    fs::create_dir(&ssh_tools).unwrap();
    let ssh = write_tool(&ssh_tools, "ssh");
    let captured = root.join("ssh-argv");
    fs::write(
        &ssh,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > {:?}\nexit 42\n",
            captured.to_string_lossy()
        ),
    )
    .unwrap();

    let rsync = env::split_paths(&env::var_os("PATH").unwrap())
        .map(|directory| directory.join("rsync"))
        .find(|candidate| candidate.is_file())
        .expect("rsync must be present for the remote-shell probe")
        .canonicalize()
        .unwrap();
    fs::write(
        root.join("seal.toml"),
        format!(
            "local_mailbox = \"mailbox\"\n\n[peer]\npath = \"/peer\"\nssh = \"agent.example\"\n\n[tools]\nrsync = {:?}\nssh = {:?}\n",
            rsync.to_string_lossy(),
            ssh.to_string_lossy()
        ),
    )
    .unwrap();
    fs::create_dir(root.join("mailbox")).unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_seal"))
        .arg("pull")
        .current_dir(&root)
        .output()
        .unwrap();
    assert!(!output.status.success());
    let argv = fs::read_to_string(captured).unwrap_or_else(|error| {
        panic!(
            "fake SSH was not invoked: {error}; rsync stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        )
    });
    assert!(
        argv.starts_with("--\nagent.example\nrsync\n--server\n"),
        "{argv}"
    );
}

#[test]
fn real_local_pull_preserves_symlink() {
    let root = test_root("real-pull");
    let source = root.join("peer");
    let destination = root.join("mailbox");
    fs::create_dir(&source).unwrap();
    fs::create_dir(&destination).unwrap();
    fs::write(source.join("target.txt"), "opaque mailbox bytes\n").unwrap();
    std::os::unix::fs::symlink("target.txt", source.join("link.txt")).unwrap();

    let rsync = env::split_paths(&env::var_os("PATH").unwrap())
        .map(|directory| directory.join("rsync"))
        .find(|candidate| candidate.is_file())
        .expect("rsync must be present for the real transfer fixture")
        .canonicalize()
        .unwrap();
    fs::write(
        root.join("seal.toml"),
        format!(
            "local_mailbox = \"mailbox\"\n\n[peer]\npath = \"peer\"\n\n[tools]\nrsync = {:?}\n",
            rsync.to_string_lossy()
        ),
    )
    .unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_seal"))
        .arg("pull")
        .current_dir(&root)
        .output()
        .unwrap();
    assert_success(&output);
    assert_eq!(
        fs::read_to_string(destination.join("target.txt")).unwrap(),
        "opaque mailbox bytes\n"
    );
    assert!(
        fs::symlink_metadata(destination.join("link.txt"))
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert_eq!(
        fs::read_link(destination.join("link.txt")).unwrap(),
        PathBuf::from("target.txt")
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
