#!/usr/bin/env bash
# Generated from SEAL.org; edit the literate source instead.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly PROJECT_ROOT
readonly SCRIPT="$PROJECT_ROOT/seal-exec.sh"
REAL_RSYNC="$(command -v rsync)"
readonly REAL_RSYNC
TEST_ROOT="$(mktemp -d)"
readonly TEST_ROOT
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local expected="$2"
  grep -F -- "$expected" "$file" >/dev/null ||
    fail "$file does not contain: $expected"
}

make_fake_tools() {
  local directory="$1"
  mkdir -p "$directory"

  cat >"$directory/seal" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$SEAL_TEST_LOG"
SH

  cat >"$directory/bwrap" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" >"$BWRAP_TEST_LOG"
cwd=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bind|--ro-bind|--dev-bind)
      shift 3
      ;;
    --proc|--dev)
      shift 2
      ;;
    --chdir)
      cwd="$2"
      shift 2
      ;;
    --setenv)
      export "$2=$3"
      shift 3
      ;;
    --die-with-parent|--new-session|--unshare-pid)
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      printf 'unexpected fake bwrap argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done
[[ -z "$cwd" ]] || cd "$cwd"
exec "$@"
SH

  cat >"$directory/vi" <<'SH'
#!/usr/bin/env bash
cat >"$1" <<'COMMAND'
argv = ["argv-probe", "edited command"]
COMMAND
SH

cat >"$directory/argv-probe" <<'SH'
#!/usr/bin/env bash
printf 'ambient=<%s>\n' "$AMBIENT_TEST_VALUE"
printf 'cwd=<%s>\n' "$(pwd)"
index=0
for argument in "$@"; do
  printf 'arg[%s]=<%s>\n' "$index" "$argument"
  ((index += 1))
done
printf 'command stderr\n' >&2
printf 'artifact\n' > artifact.txt
printf 'operator-runtime=<%s>\n' "$SEAL_OPERATOR_RUNTIME"
printf 'session state\n' >"$SEAL_OPERATOR_RUNTIME/probe-session"
SH

  chmod +x \
    "$directory/seal" \
    "$directory/bwrap" \
    "$directory/vi" \
    "$directory/argv-probe"
}

write_local_config() {
  local workspace="$1"
  local peer="$2"
  local rsync="${3:-$REAL_RSYNC}"
  cat >"$workspace/seal.toml" <<EOF
local_mailbox = "mailbox"

[peer]
path = "$peer"

[tools]
rsync = "$rsync"
EOF
}

run_spike() {
  local workspace="$1"
  local tools="$2"
  local input="$3"
  local transcript="$4"
  local mode="${5:-}"
  local -a arguments=(run)
  if [[ -n "$mode" ]]; then
    arguments=("$mode" run)
  fi
  (
    cd "$workspace"
    PATH="$tools:$PATH" \
      SEAL_TEST_LOG="$workspace/seal.log" \
      BWRAP_TEST_LOG="$workspace/bwrap.log" \
      AMBIENT_TEST_VALUE="ambient value" \
      "$SCRIPT" "${arguments[@]}" <<<"$input"
  ) >"$transcript" 2>&1
}

tools="$TEST_ROOT/tools"
make_fake_tools "$tools"

workspace="$TEST_ROOT/run"
peer="$TEST_ROOT/run-peer"
mkdir -p \
  "$workspace/mailbox/ready/20260716-001" \
  "$workspace/mailbox/world/nested/work" \
  "$peer"
write_local_config "$workspace" "$peer"
cat >"$workspace/mailbox/ready/20260716-001/command.toml" <<'TOML'
cwd = "nested/work"
argv = [
  "argv-probe",
  "two words",
  "*",
  "$(printf injected)",
  "",
]
TOML

run_spike "$workspace" "$tools" yes "$workspace/transcript"
[[ ! -e "$workspace/mailbox/ready/20260716-001" ]] || fail "ready command survived claim"
[[ -f "$workspace/mailbox/claimed/20260716-001/command.toml" ]] || fail "command was not claimed"
[[ -f "$workspace/.seal-exec/attempts/20260716-001/command.toml" ]] || fail "approved snapshot missing"
assert_file_contains "$workspace/transcript" "parsed argv:"
assert_file_contains "$workspace/mailbox/output/20260716-001.out" "ambient=<ambient value>"
assert_file_contains \
  "$workspace/mailbox/output/20260716-001.out" \
  "cwd=<$workspace/mailbox/world/nested/work>"
assert_file_contains "$workspace/mailbox/output/20260716-001.out" "arg[0]=<two words>"
assert_file_contains "$workspace/mailbox/output/20260716-001.out" "arg[1]=<*>"
assert_file_contains "$workspace/mailbox/output/20260716-001.out" "arg[2]=<\$(printf injected)>"
assert_file_contains "$workspace/mailbox/output/20260716-001.out" "arg[3]=<>"
assert_file_contains "$workspace/mailbox/output/20260716-001.err" "command stderr"
assert_file_contains "$workspace/mailbox/claimed/20260716-001/result.toml" 'status = "completed"'
assert_file_contains "$workspace/mailbox/claimed/20260716-001/result.toml" 'execution_mode = "direct"'
assert_file_contains "$workspace/mailbox/claimed/20260716-001/result.toml" 'exit_code = 0'
approved_digest="$(sha256sum "$workspace/.seal-exec/attempts/20260716-001/command.toml")"
approved_digest="${approved_digest%% *}"
assert_file_contains \
  "$workspace/mailbox/claimed/20260716-001/result.toml" \
  "command_sha256 = \"$approved_digest\""
assert_file_contains "$workspace/mailbox/world/nested/work/artifact.txt" "artifact"
assert_file_contains "$workspace/.seal-exec/runtime/probe-session" "session state"
[[ ! -e "$peer/runtime" ]] || fail "operator runtime was transported to peer"
[[ "$(printf 'pull\npush\n')" == "$(cat "$workspace/seal.log")" ]] || fail "unexpected seal calls"
[[ ! -e "$workspace/bwrap.log" ]] || fail "default execution invoked bwrap"

workspace="$TEST_ROOT/bwrap"
peer="$TEST_ROOT/bwrap-peer"
mkdir -p "$workspace/mailbox/ready/20260716-bwrap" "$peer"
write_local_config "$workspace" "$peer"
printf 'argv = ["argv-probe", "sandboxed"]\n' \
  >"$workspace/mailbox/ready/20260716-bwrap/command.toml"
run_spike "$workspace" "$tools" yes "$workspace/transcript" --bwrap
assert_file_contains "$workspace/mailbox/output/20260716-bwrap.out" "arg[0]=<sandboxed>"
assert_file_contains \
  "$workspace/mailbox/claimed/20260716-bwrap/result.toml" \
  'execution_mode = "bwrap"'
[[ -s "$workspace/bwrap.log" ]] || fail "--bwrap execution did not invoke bwrap"
assert_file_contains "$workspace/.seal-exec/runtime/probe-session" "session state"
grep -aF -- "$workspace/.seal-exec/runtime" "$workspace/bwrap.log" >/dev/null ||
  fail "bwrap did not receive operator runtime bind"

workspace="$TEST_ROOT/edit"
peer="$TEST_ROOT/edit-peer"
mkdir -p "$workspace/mailbox/ready/20260716-002" "$peer"
write_local_config "$workspace" "$peer"
printf 'argv = ["argv-probe", "original command"]\n' \
  >"$workspace/mailbox/ready/20260716-002/command.toml"
run_spike "$workspace" "$tools" $'edit\nyes' "$workspace/transcript"
assert_file_contains "$workspace/mailbox/output/20260716-002.out" "arg[0]=<edited command>"
assert_file_contains "$workspace/mailbox/claimed/20260716-002/result.toml" 'edited = true'
assert_file_contains "$workspace/mailbox/world/artifact.txt" "artifact"

workspace="$TEST_ROOT/invalid"
peer="$TEST_ROOT/invalid-peer"
mkdir -p "$workspace/mailbox/ready/20260716-003" "$peer"
write_local_config "$workspace" "$peer"
cat >"$workspace/mailbox/ready/20260716-003/command.toml" <<'TOML'
argv = ["argv-probe"]
environment = { EXAMPLE = "value" }
TOML
set +e
run_spike "$workspace" "$tools" no "$workspace/transcript"
invalid_status=$?
set -e
[[ "$invalid_status" -eq 1 ]] || fail "invalid command did not fail run"
assert_file_contains "$workspace/transcript" "must contain argv and may contain only cwd"
assert_file_contains \
  "$workspace/mailbox/claimed/20260716-003/result.toml" \
  'status = "invalid"'
[[ ! -e "$workspace/.seal-exec/attempts/20260716-003" ]] ||
  fail "invalid command created an attempt"

workspace="$TEST_ROOT/cwd-missing"
peer="$TEST_ROOT/cwd-missing-peer"
mkdir -p "$workspace/mailbox/ready/20260716-004" "$peer"
write_local_config "$workspace" "$peer"
cat >"$workspace/mailbox/ready/20260716-004/command.toml" <<'TOML'
cwd = "missing"
argv = ["argv-probe"]
TOML
set +e
run_spike "$workspace" "$tools" no "$workspace/transcript"
missing_cwd_status=$?
set -e
[[ "$missing_cwd_status" -eq 1 ]] || fail "missing cwd did not fail run"
assert_file_contains "$workspace/transcript" "cwd does not name an existing path"
assert_file_contains \
  "$workspace/mailbox/claimed/20260716-004/result.toml" \
  'status = "invalid"'

workspace="$TEST_ROOT/cwd-escape"
peer="$TEST_ROOT/cwd-escape-peer"
mkdir -p "$workspace/mailbox/ready/20260716-005" "$workspace/mailbox/world" "$peer"
ln -s "$peer" "$workspace/mailbox/world/outside"
write_local_config "$workspace" "$peer"
cat >"$workspace/mailbox/ready/20260716-005/command.toml" <<'TOML'
cwd = "outside"
argv = ["argv-probe"]
TOML
set +e
run_spike "$workspace" "$tools" no "$workspace/transcript"
escaping_cwd_status=$?
set -e
[[ "$escaping_cwd_status" -eq 1 ]] || fail "escaping cwd did not fail run"
assert_file_contains "$workspace/transcript" "cwd resolves outside mailbox/world"
assert_file_contains \
  "$workspace/mailbox/claimed/20260716-005/result.toml" \
  'status = "invalid"'

workspace="$TEST_ROOT/supersede"
peer="$TEST_ROOT/supersede-peer"
mkdir -p \
  "$workspace/mailbox/ready/20260716-010" \
  "$workspace/mailbox/ready/20260716-011" \
  "$peer"
write_local_config "$workspace" "$peer"
printf 'argv = ["argv-probe", "old command"]\n' \
  >"$workspace/mailbox/ready/20260716-010/command.toml"
printf 'argv = ["argv-probe", "new command"]\n' \
  >"$workspace/mailbox/ready/20260716-011/command.toml"
touch -d @100 "$workspace/mailbox/ready/20260716-010"
touch -d @200 "$workspace/mailbox/ready/20260716-011"
run_spike "$workspace" "$tools" yes "$workspace/transcript"
assert_file_contains "$workspace/transcript" "multiple unclaimed proposals"
assert_file_contains "$workspace/mailbox/output/20260716-011.out" "arg[0]=<new command>"
[[ ! -e "$workspace/mailbox/output/20260716-010.out" ]] ||
  fail "superseded command produced output"
assert_file_contains \
  "$workspace/mailbox/claimed/20260716-010/result.toml" \
  'status = "superseded"'
assert_file_contains \
  "$workspace/mailbox/claimed/20260716-010/result.toml" \
  'superseded_by = "20260716-011"'

workspace="$TEST_ROOT/watch"
peer="$TEST_ROOT/watch-peer"
watch_tools="$TEST_ROOT/watch-tools"
mkdir -p "$workspace/mailbox/ready/20260716-020" "$peer" "$watch_tools"
cp -a "$tools/." "$watch_tools/"
cat >"$watch_tools/sleep" <<'SH'
#!/usr/bin/env bash
count=0
[[ ! -f "$SLEEP_TEST_LOG" ]] || read -r count <"$SLEEP_TEST_LOG"
((count += 1))
printf '%s\n' "$count" >"$SLEEP_TEST_LOG"
if (( count >= 2 )); then
  exit 77
fi
mkdir -p "$WATCH_READY/20260716-021"
printf 'argv = ["argv-probe", "second command"]\n' \
  >"$WATCH_READY/20260716-021/command.toml"
exit 0
SH
chmod +x "$watch_tools/sleep"
write_local_config "$workspace" "$peer"
printf 'argv = ["argv-probe", "first command"]\n' \
  >"$workspace/mailbox/ready/20260716-020/command.toml"
set +e
(
  cd "$workspace"
  PATH="$watch_tools:$PATH" \
    SEAL_TEST_LOG="$workspace/seal.log" \
    BWRAP_TEST_LOG="$workspace/bwrap.log" \
    SLEEP_TEST_LOG="$workspace/sleep.log" \
    WATCH_READY="$workspace/mailbox/ready" \
    AMBIENT_TEST_VALUE="watch ambient" \
    "$SCRIPT" watch <<'ANSWERS'
yes
yes
ANSWERS
) >"$workspace/transcript" 2>&1
watch_status=$?
set -e
[[ "$watch_status" -eq 77 ]] || fail "watch did not complete two polling waits"
assert_file_contains "$workspace/transcript" "watching for one proposal at a time"
assert_file_contains "$workspace/mailbox/output/20260716-020.out" "arg[0]=<first command>"
assert_file_contains "$workspace/mailbox/output/20260716-021.out" "arg[0]=<second command>"
assert_file_contains \
  "$workspace/mailbox/claimed/20260716-020/result.toml" \
  'status = "completed"'
assert_file_contains \
  "$workspace/mailbox/claimed/20260716-021/result.toml" \
  'status = "completed"'
[[ "$(printf 'pull\npush\npull\npush\n')" == "$(cat "$workspace/seal.log")" ]] ||
  fail "watch did not alternate pull/result publication"

workspace="$TEST_ROOT/purge-failure"
peer="$TEST_ROOT/purge-failure-peer"
mkdir -p "$workspace/mailbox/world" "$peer/world"
printf 'local survives\n' >"$workspace/mailbox/world/old.txt"
printf 'peer survives\n' >"$peer/world/old.txt"
write_local_config "$workspace" "$peer" /bin/false
set +e
(
  cd "$workspace"
  PATH="$tools:$PATH" "$SCRIPT" purge <<<'purge'
) >"$workspace/transcript" 2>&1
purge_status=$?
set -e
[[ "$purge_status" -ne 0 ]] || fail "failed peer purge reported success"
assert_file_contains "$workspace/mailbox/world/old.txt" "local survives"
assert_file_contains "$peer/world/old.txt" "peer survives"
assert_file_contains "$workspace/transcript" "staged mailbox retained"
[[ -n "$(find "$workspace/.seal-exec" -path '*/mailbox/contract.org' -print -quit)" ]] ||
  fail "failed purge did not retain staged mailbox"

workspace="$TEST_ROOT/purge"
peer="$TEST_ROOT/purge-peer"
mkdir -p \
  "$workspace/mailbox/ready/local" \
  "$workspace/mailbox/world" \
  "$workspace/.seal-exec/attempts/evidence" \
  "$peer/ready/one" \
  "$peer/ready/two" \
  "$peer/claimed/old" \
  "$peer/output" \
  "$peer/world"
printf 'local old world\n' >"$workspace/mailbox/world/old.txt"
printf 'peer old world\n' >"$peer/world/old.txt"
printf 'old result\n' >"$peer/claimed/old/result.toml"
printf 'old output\n' >"$peer/output/old.out"
printf 'evidence\n' >"$workspace/.seal-exec/attempts/evidence/result.toml"
printf 'argv = ["true"]\n' >"$peer/ready/one/command.toml"
printf 'argv = ["true"]\n' >"$peer/ready/two/command.toml"
write_local_config "$workspace" "$peer"
(
  cd "$workspace"
  PATH="$tools:$PATH" SEAL_TEST_LOG="$workspace/seal.log" "$SCRIPT" purge <<<'purge'
) >"$workspace/transcript" 2>&1
for fresh in "$workspace/mailbox" "$peer"; do
  [[ -f "$fresh/contract.org" ]] || fail "fresh contract missing from $fresh"
  cmp "$PROJECT_ROOT/contract.org" "$fresh/contract.org" ||
    fail "fresh contract differs in $fresh"
  for directory in ready claimed output world; do
    [[ -d "$fresh/$directory" ]] || fail "fresh $directory missing from $fresh"
    [[ -z "$(find "$fresh/$directory" -mindepth 1 -print -quit)" ]] ||
      fail "fresh $directory is not empty in $fresh"
  done
done
assert_file_contains \
  "$workspace/.seal-exec/attempts/evidence/result.toml" \
  "evidence"
assert_file_contains "$workspace/transcript" "purged and reinitialized"

if [[ -n "${SEAL_E2E_BIN:-}" ]]; then
  workspace="$TEST_ROOT/real"
  peer="$TEST_ROOT/real-peer"
  mkdir -p \
    "$workspace/mailbox" \
    "$peer/ready/20260716-real" \
    "$peer/world/nested"
  write_local_config "$workspace" "$peer"
  cat >"$peer/ready/20260716-real/command.toml" <<'TOML'
cwd = "nested"
argv = [
  "sh",
  "-c",
  '''
printf 'real stdout\n'
printf 'real stderr\n' >&2
printf 'real artifact\n' > real-artifact.txt
printf '%s\n' "$SEAL_E2E_AMBIENT" > ambient.txt
printf 'real session\n' > "$SEAL_OPERATOR_RUNTIME/real-session.txt"
''',
]
TOML
  if ! (
    cd "$workspace"
    SEAL_BIN="$SEAL_E2E_BIN" \
      SEAL_E2E_AMBIENT="real ambient" \
      "$SCRIPT" --bwrap run <<<'yes'
  ) >"$workspace/transcript" 2>&1; then
    cat "$workspace/transcript" >&2
    fail "real Seal/bwrap spike failed"
  fi
  assert_file_contains "$workspace/mailbox/output/20260716-real.out" "real stdout"
  assert_file_contains "$workspace/mailbox/output/20260716-real.err" "real stderr"
  assert_file_contains "$workspace/mailbox/world/nested/real-artifact.txt" "real artifact"
  assert_file_contains "$workspace/mailbox/world/nested/ambient.txt" "real ambient"
  assert_file_contains "$workspace/.seal-exec/runtime/real-session.txt" "real session"
  assert_file_contains "$peer/claimed/20260716-real/result.toml" 'status = "completed"'
  assert_file_contains "$peer/output/20260716-real.out" "real stdout"
  assert_file_contains "$peer/world/nested/real-artifact.txt" "real artifact"
fi

printf 'seal-exec spike tests passed\n'
