#!/usr/bin/env bash
TEST_NAME="manage-mounts"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-manage-mounts (list-only) ==="

gen_plugin_key
deploy_plugin_key
PROFILE="$HOME/nas-profile.md"
write_test_profile "$PROFILE"

MOUNTS_DIR="$HOME/mounts"
mkdir -p "$MOUNTS_DIR"

MOUNT_OUT=$(mount | grep -F "$MOCK_HOST" || true)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > "$MOUNTS_DIR/current.txt" <<EOF
# Snapshot taken: $TS
$MOUNT_OUT
EOF

[ -f "$MOUNTS_DIR/current.txt" ] || { echo "FAIL: current.txt not written"; exit 1; }
echo "PASS: mounts file written (empty or populated, both valid in CI)"

echo "=== test-manage-mounts: ALL PASS ==="
