// Generated from SEAL.org; edit the literate source instead.
use std::process::Command;

#[test]
fn visible_seed_behavior() {
    let binary = env!("CARGO_BIN_EXE_seal");

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
