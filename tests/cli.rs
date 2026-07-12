// Generated from SEAL.org; edit the literate source instead.
use std::process::Command;

#[test]
fn visible_seed_behavior() {
    let binary = env!("CARGO_BIN_EXE_seal");

    let help = Command::new(binary).arg("--help").output().unwrap();
    assert!(help.status.success());
    assert!(String::from_utf8_lossy(&help.stdout).contains("Usage: seal [OPTIONS]"));

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
