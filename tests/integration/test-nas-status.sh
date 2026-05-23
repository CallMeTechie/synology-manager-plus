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

echo "--- Scenario: synoservice resolves via absolute path under DSM-like PATH ---"
# synoservice lives in /usr/syno/sbin, absent from a non-interactive SSH PATH.
# Mirror nas-status.md: privileged absolute path first, then unprivileged.
SVC=$(ssh_mock "export PATH=/usr/bin:/bin; sudo -n /usr/syno/sbin/synoservice --list 2>/dev/null || /usr/syno/sbin/synoservice --list 2>/dev/null || echo 'synoservice not available'" | head -40)
echo "$SVC" | grep -q "smbd" \
  || { echo "FAIL: synoservice --list did not return services via absolute path; got '$SVC'"; exit 1; }
echo "PASS: synoservice resolves via /usr/syno/sbin under DSM-like PATH"

# Negative control: bare 'synoservice' yields nothing here (reproduces the bug).
BARE=$(ssh_mock "export PATH=/usr/bin:/bin; synoservice --list 2>/dev/null || echo NOT-FOUND")
assert_eq "NOT-FOUND" "$BARE" "bare 'synoservice' unresolved when /usr/syno/sbin absent"
echo "PASS (control): bare 'synoservice' unresolvable under DSM-like PATH"

echo "=== test-nas-status: ALL PASS ==="
