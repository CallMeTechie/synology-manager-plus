#!/usr/bin/env bash
TEST_NAME="compose-down"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-compose-down ==="

gen_plugin_key
deploy_plugin_key

OUT=$(ssh_mock "MOCK_DOCKER_DAEMON_STATE=up sudo -n /usr/local/bin/docker compose -f /srv/compose/healthy/docker-compose.yml stop 2>&1")
case "$OUT" in
  *"compose stop ok"*) echo "PASS: default stop returned mock-ok" ;;
  *) echo "FAIL: missing mock-ok in '$OUT'"; exit 1 ;;
esac

OUT2=$(ssh_mock "MOCK_DOCKER_DAEMON_STATE=up sudo -n /usr/local/bin/docker compose -f /srv/compose/healthy/docker-compose.yml stop 2>&1")
case "$OUT2" in
  *"compose stop ok"*) echo "PASS: idempotent stop" ;;
  *) echo "FAIL: idempotent stop broke"; exit 1 ;;
esac

OUT3=$(ssh_mock "MOCK_DOCKER_DAEMON_STATE=up sudo -n /usr/local/bin/docker compose -f /srv/compose/healthy/docker-compose.yml down 2>&1")
case "$OUT3" in
  *"compose down ok"*) echo "PASS: --remove path uses compose down" ;;
  *) echo "FAIL: missing mock-ok in '$OUT3'"; exit 1 ;;
esac

echo "=== test-compose-down: ALL PASS ==="
