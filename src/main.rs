// Generated from SEAL.org; edit that file instead.

mod config;

use config::{Config, Peer, SSH_TRANSFER_FLAGS, Selection, TRANSFER_FLAGS};
use std::{
    env,
    ffi::OsString,
    fs::{self, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
    process::ExitCode,
};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const HELP: &str = "\
Opaque mailbox transport

Usage:
  seal [OPTIONS] cfg
  seal [OPTIONS] init <PEER_PATH> [--ssh <DEST> --peer-rsync <PATH>]

Commands:
  init <PEER_PATH>  Create local mailbox and configuration
  cfg               Inspect effective configuration without contacting the peer

Init options:
      --ssh <DEST>         Use one opaque SSH destination
      --peer-rsync <PATH>  Pin absolute peer-side rsync path; requires --ssh

Options:
      --config <PATH>  Read PATH instead of ./seal.toml
      --debug          Report selected paths and planned behavior
  -h, --help           Print help
  -V, --version        Print version";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CommandKind {
    Help,
    Version,
    Cfg,
    Init,
}

#[derive(Debug, Eq, PartialEq)]
struct InitArgs {
    peer_path: PathBuf,
    ssh: Option<String>,
    peer_rsync: Option<PathBuf>,
}

#[derive(Debug, Eq, PartialEq)]
enum Action {
    Help,
    Version,
    Cfg,
    Init(InitArgs),
}

#[derive(Debug, Eq, PartialEq)]
struct Cli {
    debug: bool,
    config: Option<PathBuf>,
    action: Action,
}

mod report {
    #[derive(Clone, Copy)]
    enum Level {
        Info,
        Warn,
        Error,
        Debug,
    }

    impl Level {
        const fn label(self) -> &'static str {
            match self {
                Self::Info => "info",
                Self::Warn => "warn",
                Self::Error => "error",
                Self::Debug => "debug",
            }
        }
    }

    fn format(level: Level, message: &str) -> String {
        let mut escaped = String::with_capacity(message.len());
        for character in message.chars() {
            if character.is_control() {
                escaped.extend(character.escape_default());
            } else {
                escaped.push(character);
            }
        }
        format!("[{}] :: {escaped}", level.label())
    }

    fn emit(level: Level, message: &str) {
        eprintln!("{}", format(level, message));
    }

    #[allow(dead_code)]
    pub fn info(message: &str) {
        emit(Level::Info, message);
    }

    #[allow(dead_code)]
    pub fn warn(message: &str) {
        emit(Level::Warn, message);
    }

    pub fn error(message: &str) {
        emit(Level::Error, message);
    }

    pub fn debug(message: &str) {
        emit(Level::Debug, message);
    }

    #[cfg(test)]
    mod tests {
        use super::{Level, format};

        #[test]
        fn formats_each_contract_level() {
            assert_eq!(format(Level::Info, "message"), "[info] :: message");
            assert_eq!(format(Level::Warn, "message"), "[warn] :: message");
            assert_eq!(format(Level::Error, "message"), "[error] :: message");
            assert_eq!(format(Level::Debug, "message"), "[debug] :: message");
        }
    }
}

fn parse_args(args: impl IntoIterator<Item = OsString>) -> Result<Cli, String> {
    let mut arguments = args.into_iter();
    let mut debug = false;
    let mut config = None;
    let mut command = None;
    let mut peer_path = None;
    let mut ssh = None;
    let mut peer_rsync = None;

    while let Some(argument) = arguments.next() {
        match argument.to_str() {
            Some("--debug") => debug = true,
            Some("--config") => {
                if config.is_some() {
                    return Err("--config may be supplied only once".to_owned());
                }
                config = Some(PathBuf::from(
                    arguments
                        .next()
                        .ok_or_else(|| "--config requires a path".to_owned())?,
                ));
            }
            Some("--ssh") if command == Some(CommandKind::Init) => {
                if ssh.is_some() {
                    return Err("--ssh may be supplied only once".to_owned());
                }
                let destination = arguments
                    .next()
                    .ok_or_else(|| "--ssh requires a destination".to_owned())?;
                let destination = destination
                    .into_string()
                    .map_err(|_| "--ssh destination is not valid UTF-8".to_owned())?;
                if destination.is_empty() {
                    return Err("--ssh destination must not be empty".to_owned());
                }
                ssh = Some(destination);
            }
            Some("--peer-rsync") if command == Some(CommandKind::Init) => {
                if peer_rsync.is_some() {
                    return Err("--peer-rsync may be supplied only once".to_owned());
                }
                let path = PathBuf::from(
                    arguments
                        .next()
                        .ok_or_else(|| "--peer-rsync requires a path".to_owned())?,
                );
                if path.as_os_str().is_empty() {
                    return Err("--peer-rsync path must not be empty".to_owned());
                }
                peer_rsync = Some(path);
            }
            Some("-h" | "--help") => select_command(&mut command, CommandKind::Help)?,
            Some("-V" | "--version") => select_command(&mut command, CommandKind::Version)?,
            Some(value) if command == Some(CommandKind::Init) => {
                if peer_path.is_some() {
                    return Err(format!("unexpected init argument: {value}"));
                }
                if value.is_empty() {
                    return Err("PEER_PATH must not be empty".to_owned());
                }
                peer_path = Some(PathBuf::from(value));
            }
            Some("cfg") => select_command(&mut command, CommandKind::Cfg)?,
            Some("init") => select_command(&mut command, CommandKind::Init)?,
            Some(value) if value == "--ssh" || value == "--peer-rsync" => {
                return Err(format!("{value} is valid only after init"));
            }
            Some(value) => return Err(format!("unrecognized argument: {value}")),
            None => return Err("argument is not valid UTF-8".to_owned()),
        }
    }

    let action = match command.unwrap_or(CommandKind::Help) {
        CommandKind::Help => Action::Help,
        CommandKind::Version => Action::Version,
        CommandKind::Cfg => Action::Cfg,
        CommandKind::Init => {
            let peer_path = peer_path.ok_or_else(|| "init requires PEER_PATH".to_owned())?;
            match (ssh.is_some(), peer_rsync.is_some()) {
                (true, false) => {
                    return Err("--peer-rsync is required with --ssh".to_owned());
                }
                (false, true) => {
                    return Err("--peer-rsync is invalid without --ssh".to_owned());
                }
                _ => {}
            }
            Action::Init(InitArgs {
                peer_path,
                ssh,
                peer_rsync,
            })
        }
    };

    Ok(Cli {
        debug,
        config,
        action,
    })
}

fn select_command(
    selected: &mut Option<CommandKind>,
    candidate: CommandKind,
) -> Result<(), String> {
    match selected {
        Some(previous) if *previous != candidate => {
            Err("only one command, --help, or --version may be selected".to_owned())
        }
        Some(_) => Err("command may be supplied only once".to_owned()),
        None => {
            *selected = Some(candidate);
            Ok(())
        }
    }
}

fn format_flags(flags: &[String]) -> String {
    format!("{flags:?}")
}

fn format_fixed_flags(flags: &[&str]) -> String {
    format!("{flags:?}")
}

fn format_path(path: &Path) -> String {
    format!("{path:?}")
}

fn cfg_lines(selection: &Selection, config: &Config) -> Vec<String> {
    let mut lines = vec![
        format!("seal.version = {VERSION}"),
        format!("config.path = {}", format_path(&selection.path)),
        format!("config.selection = {}", selection.reason.description()),
        format!(
            "local_mailbox.configured = {}",
            format_path(&config.local_mailbox.configured)
        ),
        format!(
            "local_mailbox.resolved = {}",
            format_path(&config.local_mailbox.resolved)
        ),
    ];

    match &config.peer {
        Peer::Local { path } => {
            lines.push("peer.kind = local".to_owned());
            lines.push(format!(
                "peer.path.configured = {}",
                format_path(&path.configured)
            ));
            lines.push(format!(
                "peer.path.resolved = {}",
                format_path(&path.resolved)
            ));
        }
        Peer::Ssh {
            path,
            destination,
            rsync,
        } => {
            lines.push("peer.kind = ssh".to_owned());
            lines.push(format!("peer.path = {}", format_path(path)));
            lines.push(format!("peer.ssh = {destination:?}"));
            lines.push(format!("peer.rsync = {}", format_path(rsync)));
        }
    }

    lines.push(format!(
        "tools.rsync = {}",
        format_path(&config.tools.rsync)
    ));
    if let Some(ssh) = &config.tools.ssh {
        lines.push(format!("tools.ssh = {}", format_path(ssh)));
    }
    lines.push(format!(
        "debug.rsync_debug_flags = {}",
        format_flags(&config.debug.rsync)
    ));
    if let Some(ssh) = &config.debug.ssh {
        lines.push(format!("debug.ssh_debug_flags = {}", format_flags(ssh)));
    }
    lines.push("transfer.profile = seal-v0-fixed".to_owned());
    lines.push(format!(
        "transfer.flags = {}",
        format_fixed_flags(TRANSFER_FLAGS)
    ));
    lines.push(format!(
        "transfer.ssh_flags = {}",
        format_fixed_flags(SSH_TRANSFER_FLAGS)
    ));
    lines
}

fn debug_config(selection: &Selection, config: &Config) {
    for line in cfg_lines(selection, config).into_iter().skip(3) {
        report::debug(&line);
    }
}

struct InitPlan {
    config_path: PathBuf,
    mailbox_path: PathBuf,
    source: String,
}

fn require_absent(path: &Path, label: &str) -> Result<(), String> {
    match fs::symlink_metadata(path) {
        Ok(_) => Err(format!("{label} already exists: {}", path.display())),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!(
            "cannot inspect {label} {}: {error}",
            path.display()
        )),
    }
}

fn preflight_targets(selection: &Selection) -> Result<PathBuf, String> {
    let parent = selection
        .path
        .parent()
        .expect("absolute configuration selection has a parent");
    let mailbox = parent.join("mailbox");
    if selection.path == mailbox {
        return Err(format!(
            "configuration target aliases mailbox target: {}",
            selection.path.display()
        ));
    }

    require_absent(&selection.path, "configuration target")?;
    let metadata = fs::metadata(parent).map_err(|error| {
        format!(
            "cannot inspect configuration parent {}: {error}",
            parent.display()
        )
    })?;
    if !metadata.is_dir() {
        return Err(format!(
            "configuration parent is not a directory: {}",
            parent.display()
        ));
    }
    require_absent(&mailbox, "mailbox target")?;
    Ok(mailbox)
}

fn find_tool(name: &str, current_dir: &Path) -> Result<PathBuf, String> {
    let path = env::var_os("PATH").ok_or_else(|| format!("cannot find {name}: PATH is not set"))?;
    for entry in env::split_paths(&path) {
        let directory = if entry.as_os_str().is_empty() {
            current_dir.to_path_buf()
        } else if entry.is_absolute() {
            entry
        } else {
            current_dir.join(entry)
        };
        let candidate = directory.join(name);
        let Ok(metadata) = fs::metadata(&candidate) else {
            continue;
        };
        if metadata.is_file() && executable_access(&candidate) {
            return Ok(candidate);
        }
    }
    Err(format!("cannot find executable {name} in PATH"))
}

#[cfg(unix)]
fn executable_access(path: &Path) -> bool {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};

    let Ok(path) = CString::new(path.as_os_str().as_bytes()) else {
        return false;
    };
    // SAFETY: CString keeps a valid NUL-terminated pointer for this call.
    unsafe { libc::faccessat(libc::AT_FDCWD, path.as_ptr(), libc::X_OK, libc::AT_EACCESS) == 0 }
}

#[cfg(not(unix))]
fn executable_access(_path: &Path) -> bool {
    true
}

fn mailbox_residue(message: String, plan: &InitPlan) -> String {
    format!(
        "{message}; partial state may remain: mailbox {}",
        plan.mailbox_path.display()
    )
}

fn config_residue(message: String, plan: &InitPlan) -> String {
    format!(
        "{message}; partial state may remain: mailbox {}, configuration {}",
        plan.mailbox_path.display(),
        plan.config_path.display()
    )
}

fn create_workspace_with<M, C>(
    plan: &InitPlan,
    after_mailbox: M,
    after_config: C,
) -> Result<(), String>
where
    M: FnOnce() -> io::Result<()>,
    C: FnOnce() -> io::Result<()>,
{
    fs::create_dir(&plan.mailbox_path).map_err(|error| {
        format!(
            "cannot create mailbox {}: {error}",
            plan.mailbox_path.display()
        )
    })?;

    if let Err(error) = after_mailbox() {
        return Err(mailbox_residue(
            format!("initialization stopped after mailbox creation: {error}"),
            plan,
        ));
    }

    let mut config = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&plan.config_path)
        .map_err(|error| {
            mailbox_residue(
                format!(
                    "cannot create configuration {}: {error}",
                    plan.config_path.display()
                ),
                plan,
            )
        })?;

    if let Err(error) = config.write_all(plan.source.as_bytes()) {
        drop(config);
        return Err(config_residue(
            format!(
                "cannot write configuration {}: {error}",
                plan.config_path.display()
            ),
            plan,
        ));
    }
    drop(config);

    if let Err(error) = after_config() {
        return Err(config_residue(
            format!("initialization stopped after configuration creation: {error}"),
            plan,
        ));
    }
    Ok(())
}

fn run_init(debug: bool, explicit_config: Option<PathBuf>, args: InitArgs) -> ExitCode {
    let current_dir = match env::current_dir() {
        Ok(path) => path,
        Err(error) => {
            report::error(&format!(
                "cannot resolve process working directory: {error}"
            ));
            return ExitCode::FAILURE;
        }
    };
    let selection = Selection::new(&current_dir, explicit_config.as_deref());
    let config_dir = selection
        .path
        .parent()
        .expect("absolute configuration selection has a parent");

    if debug {
        report::debug(&format!(
            "process working directory: {}",
            current_dir.display()
        ));
        report::debug(&format!("Seal version: {VERSION}"));
        report::debug(&format!("config.path = {}", format_path(&selection.path)));
        report::debug(&format!(
            "config.selection = {}",
            selection.reason.description()
        ));
        report::debug(&format!(
            "local_mailbox.intended = {}",
            format_path(&config_dir.join("mailbox"))
        ));
        report::debug(&format!("peer.path = {}", format_path(&args.peer_path)));
        report::debug(&format!(
            "peer.kind = {}",
            if args.ssh.is_some() { "ssh" } else { "local" }
        ));
        if let Some(destination) = &args.ssh {
            report::debug(&format!("peer.ssh = {destination:?}"));
        }
        if let Some(peer_rsync) = &args.peer_rsync {
            report::debug(&format!("peer.rsync = {}", format_path(peer_rsync)));
        }
    }

    if let Some(peer_rsync) = &args.peer_rsync
        && let Err(error) = config::validate_restricted_executable_path(peer_rsync, "peer.rsync")
    {
        report::error(&error);
        return ExitCode::FAILURE;
    }

    let mailbox_path = match preflight_targets(&selection) {
        Ok(path) => path,
        Err(error) => {
            report::error(&error);
            return ExitCode::FAILURE;
        }
    };
    let local_rsync = match find_tool("rsync", &current_dir) {
        Ok(path) => path,
        Err(error) => {
            report::error(&error);
            return ExitCode::FAILURE;
        }
    };
    let local_ssh = if args.ssh.is_some() {
        match find_tool("ssh", &current_dir) {
            Ok(path) => Some(path),
            Err(error) => {
                report::error(&error);
                return ExitCode::FAILURE;
            }
        }
    } else {
        None
    };
    if let Some(path) = &local_ssh
        && let Err(error) = config::validate_restricted_executable_path(path, "tools.ssh")
    {
        report::error(&error);
        return ExitCode::FAILURE;
    }

    if debug {
        report::debug(&format!("tools.rsync = {}", format_path(&local_rsync)));
        if let Some(path) = &local_ssh {
            report::debug(&format!("tools.ssh = {}", format_path(path)));
        }
    }

    let source = match config::render_initial(
        &args.peer_path,
        args.ssh.as_deref(),
        args.peer_rsync.as_deref(),
        &local_rsync,
        local_ssh.as_deref(),
        config_dir,
    ) {
        Ok(source) => source,
        Err(errors) => {
            for error in errors {
                report::error(&error);
            }
            return ExitCode::FAILURE;
        }
    };
    let plan = InitPlan {
        config_path: selection.path,
        mailbox_path,
        source,
    };
    if let Err(error) = create_workspace_with(&plan, || Ok(()), || Ok(())) {
        report::error(&error);
        return ExitCode::FAILURE;
    }

    report::info(&format!(
        "created configuration {}",
        plan.config_path.display()
    ));
    report::info(&format!("created mailbox {}", plan.mailbox_path.display()));
    ExitCode::SUCCESS
}

fn run(args: impl IntoIterator<Item = OsString>) -> ExitCode {
    let cli = match parse_args(args) {
        Ok(cli) => cli,
        Err(message) => {
            report::error(&message);
            return ExitCode::from(2);
        }
    };

    if cli.debug && matches!(&cli.action, Action::Help | Action::Version) {
        let current_dir = match env::current_dir() {
            Ok(path) => path,
            Err(error) => {
                report::error(&format!(
                    "cannot resolve process working directory: {error}"
                ));
                return ExitCode::FAILURE;
            }
        };
        report::debug(&format!(
            "process working directory: {}",
            current_dir.display()
        ));
        report::debug(&format!("Seal version: {VERSION}"));
    }

    match cli.action {
        Action::Help => {
            println!("{HELP}");
            ExitCode::SUCCESS
        }
        Action::Version => {
            println!("seal {VERSION}");
            ExitCode::SUCCESS
        }
        Action::Cfg => run_cfg(cli.debug, cli.config),
        Action::Init(args) => run_init(cli.debug, cli.config, args),
    }
}

fn run_cfg(debug: bool, explicit_config: Option<PathBuf>) -> ExitCode {
    let current_dir = match env::current_dir() {
        Ok(path) => path,
        Err(error) => {
            report::error(&format!(
                "cannot resolve process working directory: {error}"
            ));
            return ExitCode::FAILURE;
        }
    };
    let selection = Selection::new(&current_dir, explicit_config.as_deref());

    if debug {
        report::debug(&format!(
            "process working directory: {}",
            current_dir.display()
        ));
        report::debug(&format!("Seal version: {VERSION}"));
        report::debug(&format!("config.path = {}", format_path(&selection.path)));
        report::debug(&format!(
            "config.selection = {}",
            selection.reason.description()
        ));
    }

    let config = match config::load(&selection) {
        Ok(config) => config,
        Err(errors) => {
            for error in errors {
                report::error(&error);
            }
            return ExitCode::FAILURE;
        }
    };

    if debug {
        debug_config(&selection, &config);
    }
    for line in cfg_lines(&selection, &config) {
        println!("{line}");
    }
    ExitCode::SUCCESS
}

fn main() -> ExitCode {
    run(env::args_os().skip(1))
}

#[cfg(test)]
mod tests {
    use super::{Action, Cli, InitArgs, InitPlan, create_workspace_with, parse_args};
    use std::{fs, path::PathBuf};

    #[cfg(unix)]
    use std::io;

    #[test]
    fn config_and_debug_are_global_around_cfg() {
        let arguments = ["cfg", "--config", "other.toml", "--debug"].map(Into::into);
        assert_eq!(
            parse_args(arguments),
            Ok(Cli {
                debug: true,
                config: Some("other.toml".into()),
                action: Action::Cfg,
            })
        );
    }

    #[test]
    fn help_and_version_still_conflict() {
        let arguments = ["--help", "--version"].map(Into::into);
        assert_eq!(
            parse_args(arguments),
            Err("only one command, --help, or --version may be selected".to_owned())
        );
    }

    #[test]
    fn init_parses_closed_local_and_ssh_shapes() {
        assert_eq!(
            parse_args(["init", "../peer"].map(Into::into)),
            Ok(Cli {
                debug: false,
                config: None,
                action: Action::Init(InitArgs {
                    peer_path: PathBuf::from("../peer"),
                    ssh: None,
                    peer_rsync: None,
                }),
            })
        );
        assert_eq!(
            parse_args(
                [
                    "init",
                    "/srv/mailbox",
                    "--ssh",
                    "agent.alias",
                    "--peer-rsync",
                    "/usr/bin/rsync",
                ]
                .map(Into::into)
            ),
            Ok(Cli {
                debug: false,
                config: None,
                action: Action::Init(InitArgs {
                    peer_path: PathBuf::from("/srv/mailbox"),
                    ssh: Some("agent.alias".to_owned()),
                    peer_rsync: Some(PathBuf::from("/usr/bin/rsync")),
                }),
            })
        );
    }

    #[cfg(unix)]
    #[test]
    fn injected_late_failure_preserves_and_reports_both_artifacts() {
        let root = std::env::temp_dir().join(format!("seal-car003-unit-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir(&root).expect("unit root should be created");
        let plan = InitPlan {
            config_path: root.join("seal.toml"),
            mailbox_path: root.join("mailbox"),
            source: "complete = true\n".to_owned(),
        };

        let error = create_workspace_with(
            &plan,
            || Ok(()),
            || Err(io::Error::other("injected late failure")),
        )
        .expect_err("injection should fail");

        assert!(error.contains("injected late failure"));
        assert!(error.contains("partial state may remain: mailbox"));
        assert!(error.contains("configuration"));
        assert!(plan.config_path.is_file());
        assert!(plan.mailbox_path.is_dir());
        assert!(root.exists());
        fs::remove_file(&plan.config_path).unwrap();
        fs::remove_dir(&plan.mailbox_path).unwrap();
        fs::remove_dir(&root).unwrap();
    }

    #[test]
    fn mailbox_race_fails_before_config_and_preserves_foreign_entry() {
        let root =
            std::env::temp_dir().join(format!("seal-car003-race-unit-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir(&root).expect("unit root should be created");
        let plan = InitPlan {
            config_path: root.join("seal.toml"),
            mailbox_path: root.join("mailbox"),
            source: "complete = true\n".to_owned(),
        };
        fs::create_dir(&plan.mailbox_path).unwrap();

        let error = create_workspace_with(&plan, || Ok(()), || Ok(()))
            .expect_err("raced mailbox should make exclusive creation fail");

        assert!(error.contains("cannot create mailbox"));
        assert!(!plan.config_path.exists());
        assert!(plan.mailbox_path.is_dir(), "removed foreign race winner");
        fs::remove_dir(&plan.mailbox_path).unwrap();
        fs::remove_dir(&root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn config_race_preserves_foreign_config_and_created_mailbox() {
        let root =
            std::env::temp_dir().join(format!("seal-car003-config-race-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir(&root).unwrap();
        let plan = InitPlan {
            config_path: root.join("seal.toml"),
            mailbox_path: root.join("mailbox"),
            source: "complete = true\n".to_owned(),
        };

        let error = create_workspace_with(
            &plan,
            || fs::write(&plan.config_path, "foreign config\n"),
            || Ok(()),
        )
        .expect_err("raced config should make exclusive creation fail");

        assert!(error.contains("cannot create configuration"));
        assert_eq!(
            fs::read_to_string(&plan.config_path).unwrap(),
            "foreign config\n"
        );
        assert!(error.contains("partial state may remain: mailbox"));
        assert!(plan.mailbox_path.is_dir());
        fs::remove_file(&plan.config_path).unwrap();
        fs::remove_dir(&plan.mailbox_path).unwrap();
        fs::remove_dir(&root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn late_failure_never_deletes_replacement_config() {
        let root = std::env::temp_dir().join(format!(
            "seal-car003-config-replacement-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir(&root).unwrap();
        let plan = InitPlan {
            config_path: root.join("seal.toml"),
            mailbox_path: root.join("mailbox"),
            source: "complete = true\n".to_owned(),
        };
        let moved = root.join("owned-config");

        let error = create_workspace_with(
            &plan,
            || Ok(()),
            || {
                fs::rename(&plan.config_path, &moved)?;
                fs::write(&plan.config_path, "foreign config\n")?;
                Err(io::Error::other("injected after replacement"))
            },
        )
        .expect_err("replacement injection should fail");

        assert!(error.contains("partial state may remain: mailbox"));
        assert!(error.contains("configuration"));
        assert_eq!(
            fs::read_to_string(&plan.config_path).unwrap(),
            "foreign config\n"
        );
        assert!(moved.is_file());
        assert!(plan.mailbox_path.is_dir());
        fs::remove_file(&plan.config_path).unwrap();
        fs::remove_file(&moved).unwrap();
        fs::remove_dir(&plan.mailbox_path).unwrap();
        fs::remove_dir(&root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn late_failure_never_deletes_replacement_mailbox() {
        let root = std::env::temp_dir().join(format!(
            "seal-car003-mailbox-replacement-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir(&root).unwrap();
        let plan = InitPlan {
            config_path: root.join("seal.toml"),
            mailbox_path: root.join("mailbox"),
            source: "complete = true\n".to_owned(),
        };
        let moved = root.join("owned-mailbox");

        let error = create_workspace_with(
            &plan,
            || Ok(()),
            || {
                fs::rename(&plan.mailbox_path, &moved)?;
                fs::create_dir(&plan.mailbox_path)?;
                Err(io::Error::other("injected after replacement"))
            },
        )
        .expect_err("replacement injection should fail");

        assert!(error.contains("partial state may remain: mailbox"));
        assert!(error.contains("configuration"));
        assert!(plan.config_path.is_file());
        assert!(plan.mailbox_path.is_dir());
        assert!(moved.is_dir());
        fs::remove_file(&plan.config_path).unwrap();
        fs::remove_dir(&plan.mailbox_path).unwrap();
        fs::remove_dir(&moved).unwrap();
        fs::remove_dir(&root).unwrap();
    }
}
