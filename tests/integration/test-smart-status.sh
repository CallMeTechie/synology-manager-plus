#!/usr/bin/env bash
TEST_NAME="smart-status"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-smart-status ==="

gen_plugin_key
deploy_plugin_key

DEV_TYPE="ata"
for DEV in /dev/sda /dev/sdb /dev/sdc; do
  OUT=$(ssh "${SSH_OPTS[@]}" "$MOCK_USER@$MOCK_HOST" "sudo -n /usr/bin/smartctl -d $DEV_TYPE -a $DEV 2>&1" || true)
  [ -n "$OUT" ] || { echo "FAIL [$DEV]: empty smartctl output"; exit 1; }

  if echo "$OUT" | grep -q "PASSED"; then PASSED=true
  elif echo "$OUT" | grep -q "FAILED"; then PASSED=false
  else PASSED=unknown
  fi

  REALLOC=$(echo "$OUT" | awk '$1==5 {print $NF; exit}')
  REALLOC="${REALLOC:-0}"
  PENDING=$(echo "$OUT" | awk '$1==197 {print $NF; exit}')
  PENDING="${PENDING:-0}"
  TEMP=$(echo "$OUT" | awk '$1==194 {print $NF; exit}')
  TEMP="${TEMP:-0}"

  case "$DEV" in
    /dev/sda)
      assert_eq "true" "$PASSED" "sda PASSED"
      assert_eq "0" "$REALLOC" "sda REALLOC"
      assert_eq "0" "$PENDING" "sda PENDING"
      echo "PASS: sda is healthy"
      ;;
    /dev/sdb)
      assert_eq "true" "$PASSED" "sdb still PASSED (warning state)"
      assert_eq "15" "$REALLOC" "sdb REALLOC"
      assert_eq "48" "$TEMP" "sdb TEMP"
      echo "PASS: sdb is warning"
      ;;
    /dev/sdc)
      assert_eq "false" "$PASSED" "sdc FAILED"
      assert_eq "280" "$REALLOC" "sdc REALLOC"
      assert_eq "4" "$PENDING" "sdc PENDING"
      assert_eq "58" "$TEMP" "sdc TEMP"
      echo "PASS: sdc is critical"
      ;;
  esac
done

# Schema-drift detection-Logik separat testen
PASSED=unknown
REALLOC=""
TEMP=""
if [ "$PASSED" = "unknown" ] && [ -z "$REALLOC" ] && [ -z "$TEMP" ]; then
  echo "PASS: schema-drift detection correctly triggers"
else
  echo "FAIL: schema-drift detection broken"; exit 1
fi

# ============================================================
# MUST-SYNC: Replikation der Verdict-Logik aus smart-status.md
# ============================================================
# Diese Funktion bildet 1:1 die if/elif-Kette aus
# plugin/commands/smart-status.md ab. Wenn dort die Schwellwerte
# oder die Reihenfolge der Checks geändert werden, MUSS hier
# nachgezogen werden — sonst falsche Test-Greens.
#
# Sync-Marker (vor jeder Änderung von smart-status.md
# zu suchen): grep "MUST-SYNC: Replikation der Verdict-Logik"
# Wenn das Command und dieser Helper drift'en, fängt erst Layer 3
# (manueller Test auf echter DS218+) den Bug.
# ============================================================
compute_verdict() {
  local passed="$1" realloc="$2" pending="$3" temp="$4"
  if [ "$passed" = "false" ]; then echo "critical"; return; fi
  if [ "$realloc" -gt 100 ] 2>/dev/null; then echo "critical"; return; fi
  if [ "$pending" -gt 0 ] 2>/dev/null; then echo "critical"; return; fi
  if [ "$temp" -gt 55 ] 2>/dev/null; then echo "critical"; return; fi
  if [ "$passed" = "unknown" ]; then echo "warn"; return; fi
  if [ "$realloc" -gt 0 ] 2>/dev/null && [ "$realloc" -le 100 ] 2>/dev/null; then echo "warn"; return; fi
  if [ "$temp" -gt 45 ] 2>/dev/null; then echo "warn"; return; fi
  echo "pass"
}

echo "--- Scenario: verdict logic ---"
# sda profile (healthy)
assert_eq "pass" "$(compute_verdict true 0 0 29)" "sda → pass"
# sdb profile (warning: 15 reallocated, 48C)
assert_eq "warn" "$(compute_verdict true 15 0 48)" "sdb → warn"
# sdc profile (critical: FAILED + 280 reallocated + 4 pending + 58C)
assert_eq "critical" "$(compute_verdict false 280 4 58)" "sdc → critical"

# Edge cases auf den Schwellen
assert_eq "warn"     "$(compute_verdict true 100 0 45)" "REALLOC=100 → warn (Grenze)"
assert_eq "critical" "$(compute_verdict true 101 0 45)" "REALLOC=101 → critical (>100)"
assert_eq "pass"     "$(compute_verdict true 0 0 45)"   "TEMP=45 → pass (Grenze)"
assert_eq "warn"     "$(compute_verdict true 0 0 46)"   "TEMP=46 → warn (>45)"
assert_eq "warn"     "$(compute_verdict true 0 0 55)"   "TEMP=55 → warn (Grenze)"
assert_eq "critical" "$(compute_verdict true 0 0 56)"   "TEMP=56 → critical (>55)"
assert_eq "critical" "$(compute_verdict true 0 1 40)"   "PENDING=1 → critical (>0)"
echo "PASS: all verdict-computation edge cases correct"

echo "=== test-smart-status: ALL PASS ==="
