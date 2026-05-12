#!/usr/bin/env bash
TEST_NAME="daemon-noperm"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-daemon-noperm ==="

gen_plugin_key
deploy_plugin_key

set +e
OUT=$(ssh_mock "MOCK_DOCKER_DAEMON_STATE=noperm sudo -n /usr/local/bin/docker info --format '{{.ServerVersion}}'" 2>&1)
EXIT=$?
set -e

[ "$EXIT" -ne 0 ] || { echo "FAIL: expected non-zero exit"; exit 1; }
case "$OUT" in
  *"a password is required"*) echo "PASS: noperm stderr matches" ;;
  *) echo "FAIL: stderr was '$OUT'"; exit 1 ;;
esac

echo "=== test-daemon-noperm: ALL PASS ==="
