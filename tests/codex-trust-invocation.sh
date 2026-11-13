#!/usr/bin/env bash
set -euo pipefail

if [[ ${0##*/} == codex ]]; then
  if [[ ${1:-} == exec && ${2:-} == --help ]]; then
    printf '%s\n' "${MOCK_CODEX_HELP:-Run Codex non-interactively}"
    exit "${MOCK_CODEX_HELP_STATUS:-0}"
  fi
  printf '%s\n' "$@" > "$CODEX_INVOCATION_LOG"
  exit 0
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_SCRIPT="$SCRIPT_DIR/tests/codex-trust-invocation.sh"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
MOCK_BIN="$TEMP_DIR/bin"
mkdir -p "$MOCK_BIN"
ln -s "$TEST_SCRIPT" "$MOCK_BIN/codex"

setup_project() {
  local project_dir=$1
  mkdir -p "$project_dir/agent-colony"
  printf '# Invocation test\n' > "$project_dir/goal.md"
  printf '{"goalFile":"goal.md","tasks":[{"id":"T-1","status":"open"}],"metadata":{"iterationLog":[]}}\n' > "$project_dir/agent-colony/plan.json"
}

assert_has_flag() {
  local args_file=$1
  local flag=$2
  grep -Fxq -- "$flag" "$args_file"
}

assert_lacks_flag() {
  local args_file=$1
  local flag=$2
  if grep -Fxq -- "$flag" "$args_file"; then
    echo "Unexpected argument: $flag" >&2
    exit 1
  fi
}

run_case() {
  local case_name=$1
  local help=$2
  local expect_trust=$3
  local project_dir="$TEMP_DIR/$case_name"
  local invocation_log="$TEMP_DIR/$case_name.args"
  local output="$TEMP_DIR/$case_name.output"
  setup_project "$project_dir"

  (
    cd "$project_dir"
    env -i \
      PATH="$MOCK_BIN:/usr/bin:/bin" \
      HOME="${HOME:-/root}" \
      MOCK_CODEX_HELP="$help" \
      CODEX_INVOCATION_LOG="$invocation_log" \
      "$SCRIPT_DIR/colony-build.sh" --agent codex 1 > "$output"
  )

  if [[ $expect_trust == yes ]]; then
    assert_has_flag "$invocation_log" --trust
  else
    assert_lacks_flag "$invocation_log" --trust
  fi
  assert_has_flag "$invocation_log" --dangerously-bypass-approvals-and-sandbox
  grep -Fq 'contains your complete assignment' "$invocation_log"
}

run_case legacy-0166 $'Run Codex non-interactively\n\n      --dangerously-bypass-hook-trust\n          Run enabled hooks without requiring persisted hook trust for this invocation' no
run_case supported-0169 $'Run Codex non-interactively\n\n      --trust\n          Save trust for this project and future chats, including MCP commands outside the sandbox.\n          Persists even with --ephemeral. Does not override an explicitly untrusted project' yes

failure_project="$TEMP_DIR/help-failure"
failure_log="$TEMP_DIR/help-failure.args"
setup_project "$failure_project"
cp "$failure_project/agent-colony/plan.json" "$TEMP_DIR/help-failure.plan.before"
if (
  cd "$failure_project"
  env -i \
    PATH="$MOCK_BIN:/usr/bin:/bin" \
    HOME="${HOME:-/root}" \
    MOCK_CODEX_HELP_STATUS=9 \
    CODEX_INVOCATION_LOG="$failure_log" \
    "$SCRIPT_DIR/colony-build.sh" --agent codex 1 > "$TEMP_DIR/help-failure.output" 2>&1
); then
  echo "Expected failed help inspection to stop the launcher" >&2
  exit 1
fi
[[ ! -e $failure_log ]]
cmp -s "$TEMP_DIR/help-failure.plan.before" "$failure_project/agent-colony/plan.json"
grep -Fq "could not inspect 'codex exec --help'" "$TEMP_DIR/help-failure.output"

echo "Codex trust invocation checks passed (legacy, supported, help failure)."
