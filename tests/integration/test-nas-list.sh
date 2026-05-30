#!/usr/bin/env bash
TEST_NAME="nas-list"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
trap cleanup_test_home EXIT
setup_test_home
echo "=== test-nas-list ==="
cd "$TMP_HOME"
mkdir -p context/nas/main context/nas/backup
printf '## Connection\n- host: 192.168.1.10\n- port: 22\n- user: admin\n## Hardware\n- model: DS218+\n## Software\n- dsm_version: 7.3.1\n' > context/nas/main/profile.md
printf '## Connection\n- host: 192.168.1.11\n- port: 22\n- user: admin\n## Hardware\n- model: DS220j\n## Software\n- dsm_version: 7.2.2\n' > context/nas/backup/profile.md
echo main > context/active-nas
OUT=$(ARGUMENTS="" run_command_snippets "$SCRIPT_DIR/../../plugin/commands/nas-list.md" 2>&1 || true)
echo "$OUT"
echo "$OUT" | grep -q "main" && echo "$OUT" | grep -q "backup" && echo "$OUT" | grep -q "● main" \
  || { echo "FAIL: nas-list missing rows/active marker"; exit 1; }
echo "=== test-nas-list: ALL PASS ==="
