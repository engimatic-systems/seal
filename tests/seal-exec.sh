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
#!/usr/bin/env bash
printf 'edited command\n'
COMMAND
SH

  chmod +x "$directory/seal" "$directory/bwrap" "$directory/vi"
}

write_local_config() {
  local workspace="$1"
  local peer="$2"
  cat >"$workspace/seal.toml" <<EOF
local_mailbox = "mailbox"

[peer]
path = "$peer"

[tools]
rsync = "$REAL_RSYNC"
EOF
}

run_spike() {
  local workspace="$1"
  local tools="$2"
  local input="$3"
  local transcript="$4"
  (
    cd "$workspace"
    PATH="$tools:$PATH" \
      SEAL_TEST_LOG="$workspace/seal.log" \
      BWRAP_TEST_LOG="$workspace/bwrap.log" \
      "$SCRIPT" <<<"$input"
  ) >"$transcript" 2>&1
}

tools="$TEST_ROOT/tools"
make_fake_tools "$tools"

workspace="$TEST_ROOT/run"
peer="$TEST_ROOT/run-peer"
mkdir -p "$workspace/mailbox/ready/20260716-001" "$peer"
write_local_config "$workspace" "$peer"
{
  printf '#!/usr/bin/env bash\n'
  for number in $(seq 1 40); do
    printf '# review line %s\n' "$number"
  done
  printf 'printf "command stdout\\n"\n'
  printf 'printf "command stderr\\n" >&2\n'
  printf 'printf "artifact\\n" > artifact.txt\n'
} >"$workspace/mailbox/ready/20260716-001/command.sh"

run_spike "$workspace" "$tools" yes "$workspace/transcript"
[[ ! -e "$workspace/mailbox/ready/20260716-001" ]] || fail "ready command survived claim"
[[ -f "$workspace/mailbox/claimed/20260716-001/command.sh" ]] || fail "command was not claimed"
[[ -f "$workspace/.seal-exec/attempts/20260716-001/command.sh" ]] || fail "approved snapshot missing"
assert_file_contains "$workspace/transcript" "review threshold is 40"
assert_file_contains "$workspace/mailbox/output/20260716-001.out" "command stdout"
assert_file_contains "$workspace/mailbox/output/20260716-001.err" "command stderr"
assert_file_contains "$workspace/mailbox/claimed/20260716-001/result.toml" 'status = "completed"'
assert_file_contains "$workspace/mailbox/claimed/20260716-001/result.toml" 'exit_code = 0'
assert_file_contains "$workspace/mailbox/world/artifact.txt" "artifact"
[[ "$(printf 'pull\npush\n')" == "$(cat "$workspace/seal.log")" ]] || fail "unexpected seal calls"

workspace="$TEST_ROOT/edit"
peer="$TEST_ROOT/edit-peer"
mkdir -p "$workspace/mailbox/ready/20260716-002" "$peer"
write_local_config "$workspace" "$peer"
cat >"$workspace/mailbox/ready/20260716-002/command.sh" <<'SH'
#!/usr/bin/env bash
printf 'original command\n'
SH
run_spike "$workspace" "$tools" $'edit\nyes' "$workspace/transcript"
assert_file_contains "$workspace/mailbox/output/20260716-002.out" "edited command"
assert_file_contains "$workspace/mailbox/claimed/20260716-002/result.toml" 'edited = true'

workspace="$TEST_ROOT/purge"
peer="$TEST_ROOT/purge-peer"
mkdir -p "$workspace/mailbox/ready/local" "$peer/ready/one" "$peer/ready/two" "$peer/world"
printf 'preserve\n' >"$peer/world/preserved.txt"
printf 'one\n' >"$peer/ready/one/command.sh"
printf 'two\n' >"$peer/ready/two/command.sh"
write_local_config "$workspace" "$peer"
(
  cd "$workspace"
  PATH="$tools:$PATH" SEAL_TEST_LOG="$workspace/seal.log" "$SCRIPT" purge <<<'purge'
) >"$workspace/transcript" 2>&1
[[ ! -e "$workspace/mailbox/ready" ]] || fail "local ready directory survived purge"
[[ -d "$peer/ready" ]] || fail "peer ready directory missing after purge"
[[ -z "$(find "$peer/ready" -mindepth 1 -print -quit)" ]] || fail "peer ready is not empty"
assert_file_contains "$peer/world/preserved.txt" "preserve"

if [[ -n "${SEAL_E2E_BIN:-}" ]]; then
  workspace="$TEST_ROOT/real"
  peer="$TEST_ROOT/real-peer"
  mkdir -p "$workspace/mailbox" "$peer/ready/20260716-real"
  write_local_config "$workspace" "$peer"
  cat >"$peer/ready/20260716-real/command.sh" <<'SH'
#!/usr/bin/env bash
printf 'real stdout\n'
printf 'real stderr\n' >&2
printf 'real artifact\n' > real-artifact.txt
SH
  if ! (
    cd "$workspace"
    SEAL_BIN="$SEAL_E2E_BIN" "$SCRIPT" <<<'yes'
  ) >"$workspace/transcript" 2>&1; then
    cat "$workspace/transcript" >&2
    fail "real Seal/bwrap spike failed"
  fi
  assert_file_contains "$workspace/mailbox/output/20260716-real.out" "real stdout"
  assert_file_contains "$workspace/mailbox/output/20260716-real.err" "real stderr"
  assert_file_contains "$workspace/mailbox/world/real-artifact.txt" "real artifact"
  assert_file_contains "$peer/claimed/20260716-real/result.toml" 'status = "completed"'
  assert_file_contains "$peer/output/20260716-real.out" "real stdout"
  assert_file_contains "$peer/world/real-artifact.txt" "real artifact"
fi

printf 'seal-exec spike tests passed\n'
