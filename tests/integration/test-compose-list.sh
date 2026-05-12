#!/usr/bin/env bash
TEST_NAME="compose-list"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-compose-list ==="

gen_plugin_key
deploy_plugin_key

OUT=$(ssh_mock "MOCK_DOCKER_DAEMON_STATE=up sudo -n /usr/local/bin/docker compose ls --all --format json")
COUNT=$(echo "$OUT" | jq 'length')
assert_eq "3" "$COUNT" "default fixture project count"
echo "PASS: 3-project fixture returned"

NAMES=$(echo "$OUT" | jq -r '.[].Name' | sort | tr '\n' ',')
case "$NAMES" in
  *healthy-stack*) echo "PASS: healthy-stack present" ;;
  *) echo "FAIL: healthy-stack missing in $NAMES"; exit 1 ;;
esac

PS_OUT=$(ssh_mock "MOCK_DOCKER_DAEMON_STATE=up MOCK_COMPOSE_PS_PROJECT=healthy sudo -n /usr/local/bin/docker compose -p healthy ps --format json")
PS_COUNT=$(echo "$PS_OUT" | jq 'length')
assert_eq "3" "$PS_COUNT" "healthy ps JSON-array length"
echo "PASS: ps JSON-array format mirrored"

echo "=== test-compose-list: ALL PASS ==="
