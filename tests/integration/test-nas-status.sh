#!/usr/bin/env bash
TEST_NAME="nas-status"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-nas-status ==="

gen_plugin_key
deploy_plugin_key
PROFILE="$HOME/nas-profile.md"
write_test_profile "$PROFILE"

REPORT="$HOME/storage-report.md"

DF=$(ssh_mock "df -h")
RAID=$(ssh_mock "cat /proc/mdstat 2>/dev/null || echo 'mdstat not available'")
LOAD=$(ssh_mock "uptime && free -h")

[[ -n "$DF" ]] || { echo "FAIL: df returned empty"; exit 1; }
echo "PASS: df captured"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  echo "# Storage Report"
  echo ""
  echo "_Last refresh: ${TS}_"
  echo ""
  echo "## Disk Usage"
  echo ""
  echo '```'
  echo "$DF"
  echo '```'
  echo ""
  echo "## RAID"
  echo ""
  echo '```'
  echo "$RAID"
  echo '```'
  echo ""
  echo "## Load and Memory"
  echo ""
  echo '```'
  echo "$LOAD"
  echo '```'
} > "$REPORT"

assert_contains "$REPORT" "Last refresh"
assert_contains "$REPORT" "Disk Usage"
assert_contains "$REPORT" "Filesystem"
echo "PASS: storage-report.md populated correctly"

echo "=== test-nas-status: ALL PASS ==="
