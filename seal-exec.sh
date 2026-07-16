#!/usr/bin/env bash
# Generated from SEAL.org; edit the literate source instead.
set -euo pipefail

ROOT="$(pwd)"
readonly ROOT
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
readonly CONFIG="$ROOT/seal.toml"
readonly MAILBOX="$ROOT/mailbox"
readonly READY="$MAILBOX/ready"
readonly CLAIMED="$MAILBOX/claimed"
readonly OUTPUT="$MAILBOX/output"
readonly WORLD="$MAILBOX/world"
readonly STATE="$ROOT/.seal-exec"
readonly SEAL_BIN="${SEAL_BIN:-seal}"
readonly CONTRACT_SOURCE="$SCRIPT_DIR/contract.org"
readonly POLL_SECONDS=2

info() {
  printf '[info] :: %s\n' "$*"
}

warn() {
  printf '[warn] :: %s\n' "$*" >&2
}

die() {
  printf '[error] :: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

sync_pull() {
  "$SEAL_BIN" pull || die "seal pull failed"
}

sync_push() {
  "$SEAL_BIN" push || die "seal push failed"
}

write_result() {
  local destination="$1"
  local status="$2"
  local command_id="$3"
  local digest="$4"
  local edited="$5"
  local started_at="${6:-}"
  local finished_at="${7:-}"
  local exit_code="${8:-}"
  local superseded_by="${9:-}"
  local temporary="${destination}.tmp.$$"

  {
    printf 'status = "%s"\n' "$status"
    printf 'command_id = "%s"\n' "$command_id"
    printf 'command_sha256 = "%s"\n' "$digest"
    printf 'edited = %s\n' "$edited"
    if [[ -n "$started_at" ]]; then
      printf 'started_at = "%s"\n' "$started_at"
    fi
    if [[ -n "$finished_at" ]]; then
      printf 'finished_at = "%s"\n' "$finished_at"
    fi
    if [[ -n "$exit_code" ]]; then
      printf 'exit_code = %s\n' "$exit_code"
    fi
    if [[ -n "$superseded_by" ]]; then
      printf 'superseded_by = "%s"\n' "$superseded_by"
    fi
  } >"$temporary"
  mv -- "$temporary" "$destination"
}

command_digest() {
  local command_file="$1"

  if [[ -f "$command_file" && ! -L "$command_file" ]]; then
    sha256sum -- "$command_file" | awk '{ print $1 }'
  else
    printf 'missing\n'
  fi
}

claim_latest() {
  local candidate id modified digest finished_at superseded_dir
  local candidate_count=0
  local selected=""
  local selected_id=""
  local selected_modified=-1

  CLAIM_FOUND=false
  SUPERSEDED_COUNT=0
  shopt -s nullglob
  for candidate in "$READY"/*; do
    [[ -d "$candidate" && ! -L "$candidate" ]] || continue
    id="${candidate##*/}"
    if [[ ! "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      warn "ignoring ready command with unsupported ID: $id"
      continue
    fi
    [[ ! -e "$CLAIMED/$id" ]] || continue
    ((candidate_count += 1))
    modified="$(stat -c %Y -- "$candidate")"
    if (( modified > selected_modified )) ||
      { (( modified == selected_modified )) && [[ "$id" > "$selected_id" ]]; }; then
      selected="$candidate"
      selected_id="$id"
      selected_modified="$modified"
    fi
  done

  if [[ -z "$selected" ]]; then
    shopt -u nullglob
    return 0
  fi

  if (( candidate_count > 1 )); then
    for candidate in "$READY"/*; do
      [[ -d "$candidate" && ! -L "$candidate" ]] || continue
      id="${candidate##*/}"
      [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
      [[ ! -e "$CLAIMED/$id" ]] || continue
      [[ "$id" != "$selected_id" ]] || continue

      superseded_dir="$CLAIMED/$id"
      mv -- "$candidate" "$superseded_dir"
      digest="$(command_digest "$superseded_dir/command.toml")"
      finished_at="$(timestamp)"
      write_result "$superseded_dir/result.toml" superseded "$id" \
        "$digest" false "" "$finished_at" "" "$selected_id"
      ((SUPERSEDED_COUNT += 1))
    done
    warn "multiple unclaimed proposals; newest $selected_id wins and supersedes $SUPERSEDED_COUNT older proposal(s)"
  fi
  shopt -u nullglob

  CLAIM_ID="$selected_id"
  CLAIM_DIR="$CLAIMED/$selected_id"
  mv -- "$selected" "$CLAIM_DIR"
  CLAIM_FOUND=true
}

parse_command() {
  local command_file="$1"
  local argv_file="$2"

  python3 - "$command_file" >"$argv_file" <<'PY'
import os
from pathlib import Path
import sys
import tomllib

command_path = Path(sys.argv[1])
try:
    with command_path.open("rb") as source:
        command = tomllib.load(source)
except (OSError, tomllib.TOMLDecodeError) as error:
    print(f"cannot parse {command_path.name}: {error}", file=sys.stderr)
    raise SystemExit(1)

allowed_keys = {"argv", "cwd"}
if "argv" not in command or not set(command) <= allowed_keys:
    print(
        f"{command_path.name} must contain argv and may contain only cwd",
        file=sys.stderr,
    )
    raise SystemExit(1)

argv = command["argv"]
if not isinstance(argv, list) or not argv:
    print("argv must be a nonempty array of strings", file=sys.stderr)
    raise SystemExit(1)

for index, value in enumerate(argv):
    if not isinstance(value, str):
        print(f"argv[{index}] must be a string", file=sys.stderr)
        raise SystemExit(1)
    if "\0" in value:
        print(f"argv[{index}] contains a null byte", file=sys.stderr)
        raise SystemExit(1)

if argv[0] == "":
    print("argv[0] must not be empty", file=sys.stderr)
    raise SystemExit(1)

cwd = command.get("cwd", ".")
if not isinstance(cwd, str) or not cwd:
    print("cwd must be a nonempty string", file=sys.stderr)
    raise SystemExit(1)
if "\0" in cwd:
    print("cwd contains a null byte", file=sys.stderr)
    raise SystemExit(1)
if os.path.isabs(cwd):
    print("cwd must be relative to mailbox/world", file=sys.stderr)
    raise SystemExit(1)
if ".." in Path(cwd).parts:
    print("cwd must not contain '..' path components", file=sys.stderr)
    raise SystemExit(1)

sys.stdout.buffer.write(os.fsencode(cwd) + b"\0")
for value in argv:
    sys.stdout.buffer.write(os.fsencode(value) + b"\0")
PY
}

resolve_command_cwd() {
  local requested="$1"
  local world_path resolved

  if [[ ! -d "$WORLD" || -L "$WORLD" ]]; then
    warn "mailbox/world must be a regular directory"
    return 1
  fi
  world_path="$(realpath -e -- "$WORLD")" ||
    { warn "cannot resolve mailbox/world"; return 1; }
  resolved="$(realpath -e -- "$WORLD/$requested")" ||
    { warn "cwd does not name an existing path beneath mailbox/world"; return 1; }
  if [[ ! -d "$resolved" ]]; then
    warn "cwd does not name a directory"
    return 1
  fi
  case "$resolved" in
    "$world_path"|"$world_path"/*)
      ;;
    *)
      warn "cwd resolves outside mailbox/world"
      return 1
      ;;
  esac
  COMMAND_CWD_PATH="$resolved"
}

display_command() {
  local command_file="$1"
  local index

  printf '\ncommand: %s\n' "$CLAIM_ID"
  printf 'sha256:  %s\n\n' "$COMMAND_DIGEST"
  nl -ba -- "$command_file"
  printf '\nrequested cwd: '
  printf '%q' "$COMMAND_CWD"
  printf '\nresolved cwd:  %s\n' "$COMMAND_CWD_PATH"
  printf '\nparsed argv:\n'
  for index in "${!COMMAND_ARGV[@]}"; do
    printf '  [%s] ' "$index"
    printf '%q' "${COMMAND_ARGV[$index]}"
    printf '\n'
  done
  printf '\n'
}

record_mailbox_result() {
  local source="$1"
  cp -- "$source" "$CLAIM_DIR/result.toml"
}

execute_claim() {
  local command_file="$CLAIM_DIR/command.toml"
  local answer edited=false command_valid
  local COMMAND_CWD COMMAND_CWD_PATH
  local review_dir review argv_file
  local attempt snapshot started_at finished_at exit_code
  local stdout_pipe stderr_pipe stdout_pid stderr_pid stdout_status stderr_status
  local -a COMMAND_ARGV=()
  local -a command_records=()

  if [[ ! -f "$command_file" || -L "$command_file" ]]; then
    warn "claimed command must contain a regular, non-symlink command.toml"
    COMMAND_DIGEST="missing"
    finished_at="$(timestamp)"
    write_result "$CLAIM_DIR/result.toml" invalid "$CLAIM_ID" \
      "$COMMAND_DIGEST" "$edited" "" "$finished_at" ""
    sync_push
    LAST_COMMAND_STATUS=1
    return 0
  fi

  mkdir -p "$STATE/reviews"
  review_dir="$(mktemp -d "$STATE/reviews/$CLAIM_ID.XXXXXX")"
  review="$review_dir/command.toml"
  argv_file="$review_dir/argv"

  while true; do
    cp -- "$command_file" "$review"
    COMMAND_DIGEST="$(command_digest "$review")"
    command_valid=true
    if ! parse_command "$review" "$argv_file"; then
      command_valid=false
    else
      command_records=()
      mapfile -d '' -t command_records <"$argv_file"
      COMMAND_CWD="${command_records[0]}"
      COMMAND_ARGV=("${command_records[@]:1}")
      if ! resolve_command_cwd "$COMMAND_CWD"; then
        command_valid=false
      fi
    fi
    if [[ "$command_valid" != true ]]; then
      rm -f -- "$argv_file"
      warn "command.toml is not executable"
      if ! read -r -p "Type 'edit' to open vi, anything else to reject invalid command: " answer; then
        answer=""
      fi
      if [[ "$answer" == edit ]]; then
        vi "$command_file"
        edited=true
        continue
      fi

      finished_at="$(timestamp)"
      write_result "$CLAIM_DIR/result.toml" invalid "$CLAIM_ID" \
        "$COMMAND_DIGEST" "$edited" "" "$finished_at" ""
      rm -rf -- "$review_dir"
      sync_push
      info "rejected invalid command $CLAIM_ID"
      LAST_COMMAND_STATUS=1
      return 0
    fi

    rm -f -- "$argv_file"
    display_command "$review"
    if ! read -r -p "Type 'yes' to execute, 'edit' to open vi, anything else to refuse: " answer; then
      answer=""
    fi
    case "$answer" in
      yes)
        break
        ;;
      edit)
        vi "$command_file"
        edited=true
        ;;
      *)
        finished_at="$(timestamp)"
        write_result "$CLAIM_DIR/result.toml" refused "$CLAIM_ID" \
          "$COMMAND_DIGEST" "$edited" "" "$finished_at" ""
        rm -rf -- "$review_dir"
        sync_push
        info "refused command $CLAIM_ID"
        return 0
        ;;
    esac
  done

  attempt="$STATE/attempts/$CLAIM_ID"
  mkdir -p "$STATE/attempts"
  mkdir "$attempt" || die "attempt already exists: $CLAIM_ID"
  snapshot="$attempt/command.toml"
  mv -- "$review" "$snapshot"
  rmdir -- "$review_dir"
  chmod 0444 "$snapshot"

  started_at="$(timestamp)"
  write_result "$attempt/result.toml" started "$CLAIM_ID" \
    "$COMMAND_DIGEST" "$edited" "$started_at" "" ""
  record_mailbox_result "$attempt/result.toml"

  mkdir -p "$OUTPUT" "$WORLD/.tmp"
  stdout_pipe="$attempt/stdout.pipe"
  stderr_pipe="$attempt/stderr.pipe"
  mkfifo "$stdout_pipe" "$stderr_pipe"
  tee "$attempt/stdout" <"$stdout_pipe" &
  stdout_pid=$!
  tee "$attempt/stderr" <"$stderr_pipe" >&2 &
  stderr_pid=$!

  set +e
  bwrap \
    --die-with-parent \
    --new-session \
    --unshare-pid \
    --ro-bind / / \
    --bind "$MAILBOX" "$MAILBOX" \
    --ro-bind "$snapshot" "$command_file" \
    --dev /dev \
    --proc /proc \
    --chdir "$COMMAND_CWD_PATH" \
    --setenv TMPDIR "$WORLD/.tmp" \
    -- "${COMMAND_ARGV[@]}" \
    >"$stdout_pipe" 2>"$stderr_pipe"
  exit_code=$?
  wait "$stdout_pid"
  stdout_status=$?
  wait "$stderr_pid"
  stderr_status=$?
  set -e
  rm -f "$stdout_pipe" "$stderr_pipe"

  if (( stdout_status != 0 || stderr_status != 0 )); then
    warn "output capture failed: stdout=$stdout_status stderr=$stderr_status"
  fi
  cp -- "$attempt/stdout" "$OUTPUT/$CLAIM_ID.out"
  cp -- "$attempt/stderr" "$OUTPUT/$CLAIM_ID.err"

  finished_at="$(timestamp)"
  write_result "$attempt/result.toml" completed "$CLAIM_ID" \
    "$COMMAND_DIGEST" "$edited" "$started_at" "$finished_at" "$exit_code"
  record_mailbox_result "$attempt/result.toml"
  sync_push
  info "completed command $CLAIM_ID with exit code $exit_code"
  LAST_COMMAND_STATUS="$exit_code"
  return 0
}

run_one() {
  local report_empty="$1"

  LAST_COMMAND_STATUS=0
  require_command "$SEAL_BIN"
  require_command bwrap
  require_command vi
  require_command sha256sum
  require_command python3
  require_command realpath
  [[ -f "$CONFIG" ]] || die "missing configuration: $CONFIG"

  sync_pull
  mkdir -p "$READY" "$CLAIMED" "$OUTPUT" "$WORLD"
  claim_latest
  if [[ "$CLAIM_FOUND" != true ]]; then
    if [[ "$report_empty" == true ]]; then
      info "no unclaimed ready command"
    fi
    return 0
  fi
  info "claimed command $CLAIM_ID"
  execute_claim
}

run_command() {
  run_one true
  return "$LAST_COMMAND_STATUS"
}

watch_mailbox() {
  info "watching for one proposal at a time; press Ctrl-C to stop"
  while true; do
    run_one false
    sleep "$POLL_SECONDS"
  done
}

purge_plan() {
  local fresh_mailbox="$1"
  python3 - "$CONFIG" "$fresh_mailbox" <<'PY'
import os
from pathlib import Path
import sys
import tomllib

config_path = Path(sys.argv[1]).resolve()
fresh_mailbox = Path(sys.argv[2]).resolve()
with config_path.open("rb") as source:
    config = tomllib.load(source)

rsync = config["tools"]["rsync"]
peer = config["peer"]
argv = [
    "--recursive",
    "--links",
    "--perms",
    "--times",
    "--checksum",
    "--delete",
]

if "ssh" in peer:
    ssh = config["tools"]["ssh"]
    quoted_ssh = "'" + ssh.replace("'", "''") + "' --"
    argv.extend(["--secluded-args", "--rsh", quoted_ssh])
    peer_mailbox = peer["path"].rstrip("/") + "/"
    destination = f"{peer['ssh']}:{peer_mailbox}"
else:
    peer_path = Path(peer["path"])
    if not peer_path.is_absolute():
        peer_path = config_path.parent / peer_path
    destination = str(peer_path) + "/"

argv.extend(["--", str(fresh_mailbox) + "/", destination])
for value in [rsync, *argv]:
    sys.stdout.buffer.write(os.fsencode(value) + b"\0")
PY
}

purge_mailbox() {
  local answer temporary fresh_mailbox old_mailbox
  local -a plan

  require_command python3
  [[ -f "$CONFIG" ]] || die "missing configuration: $CONFIG"
  [[ -d "$MAILBOX" && ! -L "$MAILBOX" ]] ||
    die "mailbox must be a regular directory: $MAILBOX"
  [[ -f "$CONTRACT_SOURCE" && ! -L "$CONTRACT_SOURCE" ]] ||
    die "missing regular contract beside broker: $CONTRACT_SOURCE"

  info "purge destroys local and peer mailbox contents, then installs a fresh contract and directory shape"
  info "host-only attempt evidence under $STATE is retained"
  if ! read -r -p "Type 'purge' to continue: " answer || [[ "$answer" != purge ]]; then
    info "purge cancelled"
    return 0
  fi

  mkdir -p "$STATE"
  temporary="$(mktemp -d "$STATE/purge.XXXXXX")"
  fresh_mailbox="$temporary/mailbox"
  old_mailbox="$temporary/old-mailbox"
  mkdir -p \
    "$fresh_mailbox/ready" \
    "$fresh_mailbox/claimed" \
    "$fresh_mailbox/output" \
    "$fresh_mailbox/world"
  cp -- "$CONTRACT_SOURCE" "$fresh_mailbox/contract.org"

  mapfile -d '' -t plan < <(purge_plan "$fresh_mailbox")
  (( ${#plan[@]} > 1 )) || die "cannot construct purge rsync plan"
  if ! "${plan[0]}" "${plan[@]:1}"; then
    die "cannot replace peer mailbox; staged mailbox retained at $fresh_mailbox"
  fi

  mv -- "$MAILBOX" "$old_mailbox" ||
    die "peer reset, but cannot stage old local mailbox at $old_mailbox"
  if ! mv -- "$fresh_mailbox" "$MAILBOX"; then
    mv -- "$old_mailbox" "$MAILBOX" ||
      warn "cannot restore old local mailbox from $old_mailbox"
    die "peer reset, but cannot install fresh local mailbox"
  fi
  rm -rf -- "$old_mailbox" "$temporary"
  info "purged and reinitialized local and peer mailboxes"
}

usage() {
  printf 'Usage: seal-exec.sh [watch|run|purge]\n'
}

main() {
  case "${1:-watch}" in
    watch)
      [[ $# -le 1 ]] || { usage >&2; return 2; }
      watch_mailbox
      ;;
    run)
      [[ $# -le 1 ]] || { usage >&2; return 2; }
      run_command
      ;;
    purge)
      [[ $# -eq 1 ]] || { usage >&2; return 2; }
      purge_mailbox
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
