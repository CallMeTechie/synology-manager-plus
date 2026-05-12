#!/usr/bin/env bash
TEST_NAME="compose-up"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-compose-up ==="

gen_plugin_key
deploy_plugin_key

OUT=$(ssh_mock "MOCK_DOCKER_DAEMON_STATE=up sudo -n /usr/local/bin/docker compose -f /srv/compose/stopped/docker-compose.yml up -d 2>&1")
case "$OUT" in
  *"compose up -d ok"*) echo "PASS: up returned mock-ok signal" ;;
  *) echo "FAIL: missing mock-ok in '$OUT'"; exit 1 ;;
esac

PS=$(ssh_mock "MOCK_DOCKER_DAEMON_STATE=up MOCK_COMPOSE_PS_PROJECT=healthy sudo -n /usr/local/bin/docker compose ps --format json")
COUNT=$(echo "$PS" | jq 'length')
assert_eq "3" "$COUNT" "healthy fixture service count"
echo "PASS: post-up ps JSON-array yields 3 services"

echo "=== test-compose-up: ALL PASS ==="
