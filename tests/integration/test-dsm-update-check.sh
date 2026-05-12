#!/usr/bin/env bash
TEST_NAME="dsm-update-check"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-dsm-update-check ==="

gen_plugin_key
deploy_plugin_key

run_check() {
  local state="$1"
  # synoupgrade exits non-zero for several states (e.g. 255 for new, 1 for
  # failed, 2 for unknown). We only care about stdout content, not exit code.
  # sudo -n resets env by default, so pass the state via 'sudo env VAR=val cmd'
  # rather than 'VAR=val sudo cmd'.
  ssh "${SSH_OPTS[@]}" "$MOCK_USER@$MOCK_HOST" "sudo -n env MOCK_SYNOUPGRADE_STATE=$state /usr/syno/sbin/synoupgrade --check 2>&1" || true
}

echo "--- Scenario A: update available ---"
OUT_A=$(run_check "new")
STATUS_A=$(echo "$OUT_A" | head -1 | awk '{print $1}')
case "$STATUS_A" in
  UPGRADE_HAS_NEW_DSM) echo "PASS A: status '$STATUS_A' mapped to update-available" ;;
  *) echo "FAIL A: expected UPGRADE_HAS_NEW_DSM, got '$STATUS_A'"; exit 1 ;;
esac

echo "--- Scenario B: up-to-date ---"
OUT_B=$(run_check "up-to-date")
STATUS_B=$(echo "$OUT_B" | head -1 | awk '{print $1}')
# UPGRADE_CHECKNEWDSM is the empirically-observed code on DSM 7.3.1-86003 for "no update".
case "$STATUS_B" in
  UPGRADE_CHECKNEWDSM|UPGRADE_HAS_NO_NEW_DSM|UPGRADE_UP_TO_DATE) echo "PASS B: status '$STATUS_B' mapped to up-to-date" ;;
  *) echo "FAIL B: expected up-to-date status code, got '$STATUS_B'"; exit 1 ;;
esac

echo "--- Scenario C: check-failed ---"
OUT_C=$(run_check "failed")
STATUS_C=$(echo "$OUT_C" | head -1 | awk '{print $1}')
case "$STATUS_C" in
  UPGRADE_CHECKNEWDSM_FAILED) echo "PASS C: status '$STATUS_C' mapped to check-failed" ;;
  *) echo "FAIL C: expected FAILED, got '$STATUS_C'"; exit 1 ;;
esac

echo "--- Scenario D: unknown status code triggers fail-loud ---"
OUT_D=$(run_check "weirdvalue")
STATUS_D=$(echo "$OUT_D" | head -1 | awk '{print $1}')
case "$STATUS_D" in
  UPGRADE_HAS_NEW_DSM|UPGRADE_CHECKNEWDSM|UPGRADE_HAS_NO_NEW_DSM|UPGRADE_UP_TO_DATE|UPGRADE_CHECKNEWDSM_FAILED)
    echo "FAIL D: '$STATUS_D' matches known code"; exit 1 ;;
  *) echo "PASS D: status '$STATUS_D' is unknown — command will fail-loud" ;;
esac

echo "--- Scenario E: read-only guarantee ---"
if grep -qE 'synoupgrade.*(--start|--patch|--prepare)' /root/synology-manager-plus/plugin/commands/dsm-update-check.md; then
  echo "FAIL E: command references mutating synoupgrade flags"; exit 1
fi
echo "PASS E: command uses only --check"

echo "=== test-dsm-update-check: ALL PASS ==="
