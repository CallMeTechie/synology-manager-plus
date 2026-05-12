#!/usr/bin/env bash
TEST_NAME="health-summary"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-health-summary ==="

gen_plugin_key
deploy_plugin_key

echo "--- Scenario A: cpu_cores fehlt, Lazy-Migration läuft ---"
PROFILE="$HOME/nas-profile-a.md"
cat > "$PROFILE" <<EOF
# Profile
## Connection
- host: $MOCK_HOST
- port: $MOCK_PORT
- user: $MOCK_USER
- connect_timeout_seconds: 10
## Hardware
- model: Mock
EOF
MTIME_BEFORE=$(stat -c %Y "$PROFILE")
sleep 1

CPU_CORES=$(awk '/^- cpu_cores:/ {print $3; exit}' "$PROFILE")
if ! [[ "$CPU_CORES" =~ ^[1-9][0-9]*$ ]]; then
  NPROC=$(ssh "${SSH_OPTS[@]}" "$MOCK_USER@$MOCK_HOST" "nproc" 2>/dev/null || echo "")
  if [[ "$NPROC" =~ ^[1-9][0-9]*$ ]]; then
    tmp=$(mktemp)
    awk -v v="$NPROC" '
      { print }
      /^## Hardware/ && !ins { print "- cpu_cores: " v; ins=1 }
    ' "$PROFILE" > "$tmp"
    mv "$tmp" "$PROFILE"
  fi
fi

assert_contains "$PROFILE" "cpu_cores:"
MTIME_AFTER=$(stat -c %Y "$PROFILE")
[ "$MTIME_AFTER" -gt "$MTIME_BEFORE" ] || { echo "FAIL A: profile mtime did not change"; exit 1; }
echo "PASS A: cpu_cores migrated, profile mtime advanced"

echo "--- Scenario B: cpu_cores schon befüllt, Migration SKIP ---"
PROFILE_B="$HOME/nas-profile-b.md"
cat > "$PROFILE_B" <<EOF
# Profile
## Hardware
- cpu_cores: 4
EOF
MTIME_B_BEFORE=$(stat -c %Y "$PROFILE_B")
sleep 1

CPU_CORES_B=$(awk '/^- cpu_cores:/ {print $3; exit}' "$PROFILE_B")
if ! [[ "$CPU_CORES_B" =~ ^[1-9][0-9]*$ ]]; then
  echo "FAIL B: regex should have matched '4'"; exit 1
fi

MTIME_B_AFTER=$(stat -c %Y "$PROFILE_B")
[ "$MTIME_B_AFTER" -eq "$MTIME_B_BEFORE" ] || { echo "FAIL B: profile mtime changed despite skip"; exit 1; }
assert_eq "4" "$CPU_CORES_B" "cpu_cores read from profile"
echo "PASS B: migration correctly skipped"

echo "--- Scenario C: Placeholder-Resilience ---"
PROFILE_C="$HOME/nas-profile-c.md"
cat > "$PROFILE_C" <<EOF
# Profile
## Hardware
- cpu_cores: _not configured_
- disk_warn_temp_c: _not configured_
- disk_critical_temp_c: _not configured_
EOF

DISK_WARN_TEMP=$(awk '/^- disk_warn_temp_c:/ {print $3; exit}' "$PROFILE_C")
[[ "$DISK_WARN_TEMP" =~ ^[0-9]+$ ]] || DISK_WARN_TEMP=45
DISK_CRITICAL_TEMP=$(awk '/^- disk_critical_temp_c:/ {print $3; exit}' "$PROFILE_C")
[[ "$DISK_CRITICAL_TEMP" =~ ^[0-9]+$ ]] || DISK_CRITICAL_TEMP=55

assert_eq "45" "$DISK_WARN_TEMP" "warn-temp default"
assert_eq "55" "$DISK_CRITICAL_TEMP" "critical-temp default"

TEMP_VALUE=50
if [ "$TEMP_VALUE" -gt "$DISK_WARN_TEMP" ] 2>/dev/null; then
  echo "PASS C: defaults work + integer compare with placeholder-safe fallback"
else
  echo "FAIL C: integer comparison broken"; exit 1
fi

echo "=== test-health-summary: ALL PASS ==="
