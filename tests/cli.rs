// Generated from SEAL.org; edit that file instead.

use std::process::{Command, Output};

fn seal() -> Command {
    Command::new(env!("CARGO_BIN_EXE_seal"))
}

fn stdout(output: &Output) -> &str {
    std::str::from_utf8(&output.stdout).expect("stdout should be UTF-8")
}

fn stderr(output: &Output) -> &str {
    std::str::from_utf8(&output.stderr).expect("stderr should be UTF-8")
}

#[test]
fn help_names_only_seed_behavior() {
    let output = seal().arg("--help").output().expect("seal should run");

    assert!(output.status.success());
    assert_eq!(
        stdout(&output),
        concat!(
            "Seal executable seed\n",
            "\n",
            "Usage: seal [OPTIONS]\n",
            "\n",
            "Options:\n",
            "      --debug    Report process working directory and Seal version\n",
            "  -h, --help     Print help\n",
            "  -V, --version  Print version\n",
        )
    );
    assert_eq!(stderr(&output), "");
}

#[test]
fn version_names_package_and_build_version() {
    let output = seal().arg("--version").output().expect("seal should run");

    assert!(output.status.success());
    assert_eq!(
        stdout(&output),
        format!("seal {}\n", env!("CARGO_PKG_VERSION"))
    );
    assert_eq!(stderr(&output), "");
}

#[test]
fn debug_reports_seed_facts_on_standard_error() {
    let working_directory = std::env::temp_dir();
    let output = seal()
        .current_dir(&working_directory)
        .args(["--debug", "--version"])
        .output()
        .expect("seal should run");

    assert!(output.status.success());
    assert_eq!(
        stdout(&output),
        format!("seal {}\n", env!("CARGO_PKG_VERSION"))
    );
    assert_eq!(
        stderr(&output),
        format!(
            "[debug] :: process working directory: {}\n\
             [debug] :: Seal version: {}\n",
            working_directory.display(),
            env!("CARGO_PKG_VERSION")
        )
    );
}

#[test]
fn invalid_argument_is_an_error_record() {
    let output = seal().arg("--unknown").output().expect("seal should run");

    assert_eq!(output.status.code(), Some(2));
    assert_eq!(stdout(&output), "");
    assert_eq!(
        stderr(&output),
        "[error] :: unrecognized argument: --unknown\n"
    );
}

#[test]
fn control_characters_cannot_forge_diagnostic_records() {
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
