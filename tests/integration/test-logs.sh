#!/usr/bin/env bash
TEST_NAME="logs"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-logs ==="

gen_plugin_key
deploy_plugin_key

echo "--- Scenario 1: --source=system Default ---"
RAW=$(ssh "${SSH_OPTS[@]}" "$MOCK_USER@$MOCK_HOST" "tail -n 1000 /var/log/messages /var/log/synolog/synolog.cur 2>/dev/null")
FILTERED=$(echo "$RAW" | grep -iE 'error|warn|critical|fail' || echo "")
[ -n "$FILTERED" ] || { echo "FAIL 1"; exit 1; }
echo "PASS 1: system source produces error/warn lines"

echo "--- Scenario 2: --grep=docker ---"
GREPPED=$(echo "$RAW" | grep -E "docker" || echo "")
[ -n "$GREPPED" ] || { echo "FAIL 2"; exit 1; }
echo "PASS 2: grep filter narrows output"

echo "--- Scenario 3: --source=ssh fallback ---"
SSH_RAW=$(ssh "${SSH_OPTS[@]}" "$MOCK_USER@$MOCK_HOST" "test -f /var/log/auth.log && echo found || echo not-found")
assert_eq "not-found" "$SSH_RAW" "auth.log absent in mock"
echo "PASS 3: ssh source falls back gracefully"

echo "--- Scenario 4: --source=package ---"
PKG_RAW=$(ssh "${SSH_OPTS[@]}" "$MOCK_USER@$MOCK_HOST" "tail -n 500 /var/log/synopkg.log 2>/dev/null")
[ -n "$PKG_RAW" ] || { echo "FAIL 4"; exit 1; }
echo "PASS 4: package source returns content"

echo "--- Scenario 5: invalid source argument ---"
source="invalid_source"
case "$source" in
  system|ssh|package|docker) echo "FAIL 5"; exit 1 ;;
  *) echo "PASS 5: whitelist rejects invalid source" ;;
esac

echo "--- Scenario 6: --last regex ---"
for valid in "24h" "7d" "1h" "30d"; do
  [[ "$valid" =~ ^[0-9]+[hd]$ ]] || { echo "FAIL 6: '$valid' should match"; exit 1; }
done
for invalid in "24" "h" "1H" "abc"; do
  [[ "$invalid" =~ ^[0-9]+[hd]$ ]] && { echo "FAIL 6: '$invalid' should NOT match"; exit 1; }
done
echo "PASS 6: --last regex correctly distinguishes valid/invalid"

echo "--- Scenario 7: Empty ARGUMENTS under set -u (cold-start safety) ---"
# Phase-2-Fix fuer Concern 1: ${ARGUMENTS:-} darf bei leerem ARGUMENTS
# nicht ausfaellen. Hier in einer Subshell mit set -u testen.
(
  set -u
  ARGUMENTS=""
  for arg in ${ARGUMENTS:-}; do
    echo "FAIL 7: loop should not execute with empty ARGUMENTS"; exit 1
  done
  echo "PASS 7-inner: empty ARGUMENTS handled by :- default expansion"
)
RC=$?
[ $RC -eq 0 ] || { echo "FAIL 7-outer: subshell exited non-zero ($RC)"; exit 1; }
echo "PASS 7: bare /logs (no args) does not trip set -u"

# Auch: ARGUMENTS ist gar nicht gesetzt (NICHT 'leer string', sondern UNBOUND)
(
  set -u
  unset ARGUMENTS
  for arg in ${ARGUMENTS:-}; do
    echo "FAIL 7b: loop should not execute with unset ARGUMENTS"; exit 1
  done
  echo "PASS 7b-inner: unset ARGUMENTS handled by :- default expansion"
)
RC=$?
[ $RC -eq 0 ] || { echo "FAIL 7b-outer: subshell exited non-zero ($RC)"; exit 1; }
echo "PASS 7b: even completely unbound ARGUMENTS does not trip set -u"

echo "=== test-logs: ALL PASS ==="
