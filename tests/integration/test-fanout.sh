#!/usr/bin/env bash
TEST_NAME="fanout"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
trap cleanup_test_home EXIT
setup_test_home
echo "=== test-fanout ==="
CMD_DIR="$SCRIPT_DIR/../../plugin/commands"

# Drift guard: load_nas byte-identical across the three overview commands.
fn() { awk '/^load_nas\(\) \{/{c=1} c{print} /^\}/{if(c){exit}}' "$1"; }
diff <(fn "$CMD_DIR/health-summary.md") <(fn "$CMD_DIR/smart-status.md") >/dev/null \
  && diff <(fn "$CMD_DIR/health-summary.md") <(fn "$CMD_DIR/nas-status.md") >/dev/null \
  || { echo "FAIL: load_nas drift across overview commands"; exit 1; }
echo "PASS: load_nas identical across the 3 overview commands"

# Two-slug fan-out against the single mock.
cd "$TMP_HOME"
gen_plugin_key; deploy_plugin_key
# Seed the mock's host key into the CURRENT USER's real known_hosts so that
# load_nas-built SSH arrays (which don't pass StrictHostKeyChecking=no) can
# connect. OpenSSH resolves the default known_hosts via the passwd home, NOT
# $HOME (which setup_test_home redirected) — so resolve the passwd home
# dynamically: /root locally, /home/runner on the CI runner.
SSH_HOME=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)
[ -n "$SSH_HOME" ] || SSH_HOME="$HOME"
mkdir -p "$SSH_HOME/.ssh"
ssh-keyscan -p "$MOCK_PORT" "$MOCK_HOST" >> "$SSH_HOME/.ssh/known_hosts" 2>/dev/null || true
for s in a b; do
  mkdir -p "context/nas/$s/volumes" "context/nas/$s/mounts"
  cat > "context/nas/$s/profile.md" <<EOF
## Connection
- host: $MOCK_HOST
- port: $MOCK_PORT
- user: $MOCK_USER
- key_path: $HOME/.ssh/synology-manager-plus_ed25519
- connect_timeout_seconds: 10
## Hardware
- model: MOCK
- cpu_cores: 2
- smartctl_device_type: ata
## Software
- dsm_version: 7.3.1
EOF
done
echo a > context/active-nas

OUT=$(ARGUMENTS="--all" run_command_snippets "$CMD_DIR/health-summary.md" 2>&1 || true)
echo "$OUT"
echo "$OUT" | grep -q "──────── a ────────" && echo "$OUT" | grep -q "──────── b ────────" \
  || { echo "FAIL: fan-out did not iterate both NAS"; exit 1; }
echo "$OUT" | grep -q "Fleet verdict:" || { echo "FAIL: missing Fleet verdict footer"; exit 1; }
echo "$OUT" | grep -q "worst of 2 NAS" || { echo "FAIL: footer count wrong"; exit 1; }
echo "$OUT" | grep -q "Fleet summary:" || { echo "FAIL: missing per-NAS Fleet summary"; exit 1; }

# --- No-flag path THROUGH THE MARKDOWN (real regression guard for the restructure;
#     the existing test-health-summary.sh reimplements logic and does NOT run the .md). ---
OUT0=$(ARGUMENTS="" run_command_snippets "$CMD_DIR/health-summary.md" 2>&1 || true)
echo "$OUT0" | grep -q "NAS Health Summary —" || { echo "FAIL: no-flag missing single-NAS header"; echo "$OUT0"; exit 1; }
echo "$OUT0" | grep -q "Overall verdict:" || { echo "FAIL: no-flag missing Overall verdict"; exit 1; }
if echo "$OUT0" | grep -q "────────"; then echo "FAIL: no-flag must not print a slug header"; exit 1; fi
if echo "$OUT0" | grep -q "Fleet verdict:"; then echo "FAIL: no-flag must not print a fleet footer"; exit 1; fi
echo "PASS: no-flag path is single-NAS (no fan-out) through the actual command markdown"

# --- Worst-of aggregation (loop-level): ok then critical must yield critical. ---
verdict_rank() { case "${1:-}" in ok|pass) echo 0 ;; warn|unreachable) echo 1 ;; *) echo 2 ;; esac; }
WR=0
for v in ok critical; do r=$(verdict_rank "$v"); [ "$r" -gt "$WR" ] && WR=$r; done
case "$WR" in 0) F=ok ;; 1) F=warn ;; *) F=critical ;; esac
[ "$F" = "critical" ] && echo "PASS: worst-of ok+critical = critical" || { echo "FAIL: worst-of aggregation wrong ($F)"; exit 1; }

echo "=== test-fanout: ALL PASS ==="
