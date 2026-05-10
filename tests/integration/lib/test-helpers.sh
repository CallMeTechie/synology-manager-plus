#!/usr/bin/env bash
# Common helpers for synology-manager-plus integration smoke tests.
# All scripts that source this MUST set TEST_NAME beforehand.

set -euo pipefail

MOCK_HOST="${MOCK_HOST:-localhost}"
MOCK_PORT="${MOCK_PORT:-12222}"
MOCK_USER="${MOCK_USER:-nas-test}"
# Mock NAS password is supplied by run-all.sh via NAS_TEST_PASSWORD env var.
# It is generated at build time and never hardcoded anywhere.
MOCK_PASS="${NAS_TEST_PASSWORD:-}"
if [ -z "$MOCK_PASS" ]; then
  echo "FAIL: NAS_TEST_PASSWORD not set — start tests via run-all.sh" >&2
  exit 1
fi

LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/logs"
mkdir -p "$LOG_DIR"

setup_test_home() {
  TMP_HOME=$(mktemp -d -t "synmgr-test-${TEST_NAME}-XXXX")
  mkdir -p "$TMP_HOME/.ssh"
  chmod 700 "$TMP_HOME/.ssh"
  export HOME="$TMP_HOME"
  echo "[$TEST_NAME] HOME=$TMP_HOME"
}

cleanup_test_home() {
  if [ -n "${TMP_HOME:-}" ] && [ -d "$TMP_HOME" ]; then
    rm -rf "$TMP_HOME"
  fi
}

# SSH options as a global array — same pattern the commands in plugin/
# enforce. Tests using `ssh "${SSH_OPTS[@]}" ...` mirror that contract;
# tests using a string-`echo` helper would silently word-split and
# violate the rule the commands shellcheck against.
SSH_OPTS=(
  -i "$HOME/.ssh/synology-manager-plus_ed25519"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -p "$MOCK_PORT"
)

gen_plugin_key() {
  ssh-keygen -t ed25519 -N "" \
    -f "$HOME/.ssh/synology-manager-plus_ed25519" \
    -C "synology-manager-plus@test" >/dev/null
}

deploy_plugin_key() {
  # sshpass -e reads from SSHPASS env var, never from argv (so password
  # never appears in `ps` output, and the literal -p flag does not show
  # up in source — keeps static analysis happy too).
  SSHPASS="$MOCK_PASS" sshpass -e ssh-copy-id \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$HOME/.ssh/synology-manager-plus_ed25519.pub" \
    -p "$MOCK_PORT" "$MOCK_USER@$MOCK_HOST" >/dev/null 2>&1
}

ssh_mock() {
  ssh "${SSH_OPTS[@]}" "$MOCK_USER@$MOCK_HOST" "$@"
}

write_test_profile() {
  local profile_path="$1"
  cat > "$profile_path" <<EOF
# Synology NAS Profile

## Connection
- host: $MOCK_HOST
- port: $MOCK_PORT
- user: $MOCK_USER
- key_path: $HOME/.ssh/synology-manager-plus_ed25519
- connect_timeout_seconds: 10

## Last Updated
2026-05-10T12:00:00Z
EOF
}

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -qF -- "$needle" "$file"; then
    echo "FAIL [$TEST_NAME]: '$needle' not found in $file"
    echo "--- $file ---"
    cat "$file"
    return 1
  fi
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL [$TEST_NAME]: $label expected '$expected', got '$actual'"
    return 1
  fi
}

# Extract every fenced bash/sh block from a Command Markdown file and
# concatenate them into a single shell script. This is the same logic
# as tests/static/shellcheck-commands.sh — they MUST agree, otherwise
# the static check and the smoke check are testing different artifacts.
extract_command_bash() {
  local md="$1"
  awk '
    /^```bash/ { capture=1; next }
    /^```sh/ { capture=1; next }
    /^```/ { capture=0; next }
    capture { print }
  ' "$md"
}

# Run the extracted snippets from a command in a subshell with strict
# error handling forced ON. The subshell exits 0 only if the entire
# concatenated snippet ran cleanly. Without explicit `set -euo pipefail`
# inside the subshell, a snippet containing `set +e` could disable
# error handling and pass spurious test runs.
run_command_snippets() {
  local md="$1"
  local extracted
  extracted=$(extract_command_bash "$md")
  if [ -z "$extracted" ]; then
    echo "FAIL [$TEST_NAME]: no bash snippets found in $md"
    return 1
  fi
  if ! ( set -euo pipefail; eval "$extracted" ); then
    echo "FAIL [$TEST_NAME]: snippet from $md exited non-zero"
    return 1
  fi
}
