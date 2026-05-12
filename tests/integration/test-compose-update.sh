#!/usr/bin/env bash
TEST_NAME="compose-update"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-compose-update ==="

gen_plugin_key
deploy_plugin_key

OUT_A=$(ssh_mock "MOCK_DOCKER_DAEMON_STATE=up MOCK_COMPOSE_PULL_RESULT=up-to-date sudo -n /usr/local/bin/docker compose -f /srv/compose/healthy/docker-compose.yml pull && MOCK_DOCKER_DAEMON_STATE=up sudo -n /usr/local/bin/docker compose -f /srv/compose/healthy/docker-compose.yml up -d" 2>&1)
case "$OUT_A" in
  *"already up to date"*) echo "PASS A: up-to-date pull" ;;
  *) echo "FAIL A: '$OUT_A'"; exit 1 ;;
esac

OUT_B=$(ssh_mock "MOCK_DOCKER_DAEMON_STATE=up MOCK_COMPOSE_PULL_RESULT=updated sudo -n /usr/local/bin/docker compose -f /srv/compose/healthy/docker-compose.yml pull && MOCK_DOCKER_DAEMON_STATE=up sudo -n /usr/local/bin/docker compose -f /srv/compose/healthy/docker-compose.yml up -d" 2>&1)
case "$OUT_B" in
  *"pulled new images"*) echo "PASS B: updated pull" ;;
  *) echo "FAIL B: '$OUT_B'"; exit 1 ;;
esac

set +e
OUT_C=$(ssh_mock "MOCK_DOCKER_DAEMON_STATE=up MOCK_COMPOSE_PULL_RESULT=fail sudo -n /usr/local/bin/docker compose -f /srv/compose/healthy/docker-compose.yml pull" 2>&1)
EXIT_C=$?
set -e
[ "$EXIT_C" -ne 0 ] || { echo "FAIL C: expected non-zero exit on pull-fail, got $EXIT_C"; exit 1; }
echo "PASS C: pull-fail propagated non-zero exit"

echo "=== test-compose-update: ALL PASS ==="
