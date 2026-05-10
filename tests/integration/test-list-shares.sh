#!/usr/bin/env bash
TEST_NAME="list-shares"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-list-shares ==="

gen_plugin_key
deploy_plugin_key
PROFILE="$HOME/nas-profile.md"
write_test_profile "$PROFILE"

VOLUMES_DIR="$HOME/volumes"
mkdir -p "$VOLUMES_DIR"

VOL1=$(ssh_mock "ls -la /volume1/")
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > "$VOLUMES_DIR/volume1-snapshot.txt" <<EOF
# Snapshot taken: $TS
$VOL1
EOF

assert_contains "$VOLUMES_DIR/volume1-snapshot.txt" "documents"
assert_contains "$VOLUMES_DIR/volume1-snapshot.txt" "media"
assert_contains "$VOLUMES_DIR/volume1-snapshot.txt" "backups"
echo "PASS: all three test shares listed in snapshot"

echo "=== test-list-shares: ALL PASS ==="
