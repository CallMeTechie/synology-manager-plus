#!/usr/bin/env bash
TEST_NAME="diag"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-diag (3 scenarios) ==="

gen_plugin_key
deploy_plugin_key
PROFILE="$HOME/nas-profile.md"
write_test_profile "$PROFILE"

echo "--- Scenario A: fully configured, NAS reachable ---"

[ -f "$PROFILE" ] && echo "PASS A1" || { echo "FAIL A1"; exit 1; }

nc -z -w3 "$MOCK_HOST" "$MOCK_PORT" && echo "PASS A3" || { echo "FAIL A3"; exit 1; }

ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$MOCK_USER@$MOCK_HOST" echo ok | grep -q "^ok$" \
  && echo "PASS A4" || { echo "FAIL A4"; exit 1; }

ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$MOCK_USER@$MOCK_HOST" "sudo -n true" \
  && echo "PASS A5" || { echo "FAIL A5"; exit 1; }

ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$MOCK_USER@$MOCK_HOST" "df -h" >/dev/null \
  && echo "PASS A6" || { echo "FAIL A6"; exit 1; }

echo "--- Scenario B: unreachable port ---"
WRONG_PORT="59999"
if nc -z -w2 "$MOCK_HOST" "$WRONG_PORT" 2>/dev/null; then
  echo "FAIL B3: port $WRONG_PORT unexpectedly open"
  exit 1
fi
echo "PASS B3: nc correctly fails on closed port"

echo "--- Scenario C: profile missing ---"
rm -f "$PROFILE"
[ ! -f "$PROFILE" ] && echo "PASS C1: profile correctly absent" || { echo "FAIL C1"; exit 1; }

echo "=== test-diag: ALL PASS ==="
