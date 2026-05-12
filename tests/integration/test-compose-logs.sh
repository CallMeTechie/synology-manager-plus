#!/usr/bin/env bash
TEST_NAME="compose-logs"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-compose-logs ==="

gen_plugin_key
deploy_plugin_key

OUT=$(ssh_mock "MOCK_DOCKER_DAEMON_STATE=up sudo -n /usr/local/bin/docker compose -f /srv/compose/healthy/docker-compose.yml logs --tail=200 --since=1h")
LINES=$(echo "$OUT" | wc -l)
[ "$LINES" -ge 3 ] || { echo "FAIL: expected >=3 log lines"; exit 1; }
echo "PASS: logs returned $LINES lines"

OUT2=$(ssh_mock "MOCK_DOCKER_DAEMON_STATE=up sudo -n /usr/local/bin/docker compose -f /srv/compose/healthy/docker-compose.yml logs --tail=200 --since=1h web")
[ -n "$OUT2" ] || { echo "FAIL: per-service logs empty"; exit 1; }
echo "PASS: per-service log call accepted"

echo "=== test-compose-logs: ALL PASS ==="
