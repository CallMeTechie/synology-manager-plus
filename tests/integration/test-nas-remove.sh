#!/usr/bin/env bash
TEST_NAME="nas-remove"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
trap cleanup_test_home EXIT
setup_test_home
echo "=== test-nas-remove ==="
cd "$TMP_HOME"
mkdir -p context/nas/main; echo x > context/nas/main/profile.md; echo main > context/active-nas
if ARGUMENTS="" run_command_snippets "$SCRIPT_DIR/../../plugin/commands/nas-remove.md" >/dev/null 2>&1; then
  echo "FAIL: missing slug should error"; exit 1; fi
echo "PASS: missing slug errors"
if ARGUMENTS="ghost" run_command_snippets "$SCRIPT_DIR/../../plugin/commands/nas-remove.md" >/dev/null 2>&1; then
  echo "FAIL: unknown slug should error"; exit 1; fi
echo "PASS: unknown slug errors"
echo "=== test-nas-remove: ALL PASS ==="
