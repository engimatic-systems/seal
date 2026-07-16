#!/usr/bin/env bash
# Generated from SEAL.org; edit the literate source instead.
set -euo pipefail

ROOT="$(pwd)"
readonly ROOT
readonly CONFIG="$ROOT/seal.toml"
readonly MAILBOX="$ROOT/mailbox"
readonly READY="$MAILBOX/ready"
readonly CLAIMED="$MAILBOX/claimed"
readonly OUTPUT="$MAILBOX/output"
readonly WORLD="$MAILBOX/world"
readonly STATE="$ROOT/.seal-exec"
readonly SEAL_BIN="${SEAL_BIN:-seal}"
readonly LINE_WARNING=40

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
  "$SEAL_BIN" pull
}

sync_push() {
  "$SEAL_BIN" push
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
  } >"$temporary"
  mv -- "$temporary" "$destination"
}

claim_latest() {
  local candidate id modified
  local selected=""
  local selected_id=""
  local selected_modified=-1

  shopt -s nullglob
  for candidate in "$READY"/*; do
    [[ -d "$candidate" && ! -L "$candidate" ]] || continue
    id="${candidate##*/}"
    if [[ ! "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      warn "ignoring ready command with unsupported ID: $id"
      continue
    fi
    [[ ! -e "$CLAIMED/$id" ]] || continue
    modified="$(stat -c %Y -- "$candidate")"
    if (( modified > selected_modified )) ||
      { (( modified == selected_modified )) && [[ "$id" > "$selected_id" ]]; }; then
      selected="$candidate"
      selected_id="$id"
      selected_modified="$modified"
    fi
  done
  shopt -u nullglob

  [[ -n "$selected" ]] || return 1
  CLAIM_ID="$selected_id"
  CLAIM_DIR="$CLAIMED/$selected_id"
  mv -- "$selected" "$CLAIM_DIR"
}

inspect_command() {
  local script="$1"
  COMMAND_LINES="$(awk 'END { print NR }' "$script")"
  COMMAND_DIGEST="$(sha256sum -- "$script")"
  COMMAND_DIGEST="${COMMAND_DIGEST%% *}"

  printf '\ncommand: %s\n' "$CLAIM_ID"
  printf 'sha256:  %s\n' "$COMMAND_DIGEST"
  printf 'lines:   %s\n\n' "$COMMAND_LINES"
  if (( COMMAND_LINES > LINE_WARNING )); then
    warn "command.sh is $COMMAND_LINES lines; review threshold is $LINE_WARNING"
  fi
  nl -ba -- "$script"
  printf '\n'
}

record_mailbox_result() {
  local source="$1"
  cp -- "$source" "$CLAIM_DIR/result.toml"
}

execute_claim() {
  local command_script="$CLAIM_DIR/command.sh"
  local answer edited=false
  local attempt snapshot started_at finished_at exit_code
  local stdout_pipe stderr_pipe stdout_pid stderr_pid stdout_status stderr_status
  local bash_path

  if [[ ! -f "$command_script" || -L "$command_script" ]]; then
    warn "claimed command must contain a regular, non-symlink command.sh"
    COMMAND_DIGEST="missing"
    finished_at="$(timestamp)"
    write_result "$CLAIM_DIR/result.toml" invalid "$CLAIM_ID" \
      "$COMMAND_DIGEST" "$edited" "" "$finished_at" ""
    sync_push
    return 1
  fi

  while true; do
    inspect_command "$command_script"
    if ! read -r -p "Type 'yes' to execute, 'edit' to open vi, anything else to refuse: " answer; then
      answer=""
    fi
    case "$answer" in
      yes)
        break
        ;;
      edit)
        vi "$command_script"
        edited=true
        ;;
      *)
        finished_at="$(timestamp)"
        write_result "$CLAIM_DIR/result.toml" refused "$CLAIM_ID" \
          "$COMMAND_DIGEST" "$edited" "" "$finished_at" ""
        sync_push
        info "refused command $CLAIM_ID"
        return 0
        ;;
    esac
  done

  attempt="$STATE/attempts/$CLAIM_ID"
  mkdir -p "$STATE/attempts"
  mkdir "$attempt" || die "attempt already exists: $CLAIM_ID"
  snapshot="$attempt/command.sh"
  cp -- "$command_script" "$snapshot"
  chmod 0444 "$snapshot"
  COMMAND_DIGEST="$(sha256sum -- "$snapshot")"
  COMMAND_DIGEST="${COMMAND_DIGEST%% *}"

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

  bash_path="$(command -v bash)"
  set +e
  bwrap \
    --die-with-parent \
    --new-session \
    --unshare-pid \
    --ro-bind / / \
    --bind "$MAILBOX" "$MAILBOX" \
    --ro-bind "$snapshot" "$command_script" \
    --dev /dev \
    --proc /proc \
    --chdir "$WORLD" \
    --setenv TMPDIR "$WORLD/.tmp" \
    -- "$bash_path" "$command_script" \
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
  return "$exit_code"
}

run_one() {
  require_command "$SEAL_BIN"
  require_command bwrap
  require_command vi
  require_command sha256sum
  require_command python3
  [[ -f "$CONFIG" ]] || die "missing configuration: $CONFIG"

  sync_pull
  mkdir -p "$READY" "$CLAIMED" "$OUTPUT" "$WORLD"
  if ! claim_latest; then
    info "no unclaimed ready command"
    return 0
  fi
  info "claimed command $CLAIM_ID"
  execute_claim
}

purge_plan() {
  local empty_ready="$1"
  python3 - "$CONFIG" "$empty_ready" <<'PY'
import os
from pathlib import Path
import sys
import tomllib

config_path = Path(sys.argv[1]).resolve()
empty_ready = Path(sys.argv[2]).resolve()
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
    peer_ready = peer["path"].rstrip("/") + "/ready/"
    destination = f"{peer['ssh']}:{peer_ready}"
else:
    peer_path = Path(peer["path"])
    if not peer_path.is_absolute():
        peer_path = config_path.parent / peer_path
    destination = str(peer_path / "ready") + "/"

argv.extend(["--", str(empty_ready) + "/", destination])
for value in [rsync, *argv]:
    sys.stdout.buffer.write(os.fsencode(value) + b"\0")
PY
}

purge_ready() {
  local answer temporary
  local -a plan

  require_command "$SEAL_BIN"
  require_command python3
  [[ -f "$CONFIG" ]] || die "missing configuration: $CONFIG"

  sync_pull
  info "purge removes every command currently under local and peer ready/"
  if ! read -r -p "Type 'purge' to continue: " answer || [[ "$answer" != purge ]]; then
    info "purge cancelled"
    return 0
  fi

  rm -rf -- "$READY"
  mkdir -p "$STATE"
  temporary="$(mktemp -d "$STATE/purge.XXXXXX")"
  mkdir "$temporary/ready"
  mapfile -d '' -t plan < <(purge_plan "$temporary/ready")
  (( ${#plan[@]} > 1 )) || die "cannot construct purge rsync plan"
  "${plan[0]}" "${plan[@]:1}"
  rm -rf -- "$temporary"
  info "purged ready commands"
}

usage() {
  printf 'Usage: seal-exec.sh [run|purge]\n'
}

main() {
  case "${1:-run}" in
    run)
      [[ $# -le 1 ]] || { usage >&2; return 2; }
      run_one
      ;;
    purge)
      [[ $# -eq 1 ]] || { usage >&2; return 2; }
      purge_ready
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
