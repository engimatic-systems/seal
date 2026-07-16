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
readonly LINE_WARNING=40
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
  local script="$1"

  if [[ -f "$script" && ! -L "$script" ]]; then
    sha256sum -- "$script" | awk '{ print $1 }'
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
      digest="$(command_digest "$superseded_dir/command.sh")"
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
    LAST_COMMAND_STATUS=1
    return 0
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
