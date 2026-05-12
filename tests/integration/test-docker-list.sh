#!/usr/bin/env bash
TEST_NAME="docker-list"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-docker-list ==="

gen_plugin_key
deploy_plugin_key

FMT='{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Label "com.docker.compose.project"}}'
OUT=$(ssh_mock "MOCK_DOCKER_DAEMON_STATE=up sudo -n /usr/local/bin/docker ps --format '$FMT'")
LINES=$(echo "$OUT" | wc -l)
[ "$LINES" -ge 3 ] || { echo "FAIL: expected >=3 lines, got $LINES"; exit 1; }
echo "PASS: container count >=3"

STANDALONE=$(echo "$OUT" | grep -c 'standalone-redis')
[ "$STANDALONE" -eq 1 ] || { echo "FAIL: standalone-redis missing"; exit 1; }
echo "PASS: standalone container present"

echo "=== test-docker-list: ALL PASS ==="
