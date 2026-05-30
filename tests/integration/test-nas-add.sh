#!/usr/bin/env bash
TEST_NAME="nas-add"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
trap cleanup_test_home EXIT
setup_test_home
echo "=== test-nas-add ==="
CMD_DIR="$SCRIPT_DIR/../../plugin/commands"

# Drift guard: render_claude_md must be byte-identical in nas-add.md and nas-use.md.
extract_fn() { awk '/^render_claude_md\(\) \{/{c=1} c{print} /^\}/{if(c){exit}}' "$1"; }
if ! diff <(extract_fn "$CMD_DIR/nas-use.md") <(extract_fn "$CMD_DIR/nas-add.md") >/dev/null; then
  echo "FAIL: render_claude_md differs between nas-use.md and nas-add.md (drift)"; exit 1; fi
echo "PASS: render_claude_md identical across nas-use/nas-add"

# Core discovery + per-NAS write against the mock.
cd "$TMP_HOME"
SLUG="probe"; KEY="$HOME/.ssh/synology-manager-plus_${SLUG}_ed25519"
ssh-keygen -t ed25519 -N "" -f "$KEY" -C "smp@$SLUG" >/dev/null
SSHPASS="$NAS_TEST_PASSWORD" sshpass -e ssh-copy-id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "${KEY}.pub" -p "$MOCK_PORT" "$MOCK_USER@$MOCK_HOST" >/dev/null 2>&1
mkdir -p "context/nas/$SLUG/volumes" "context/nas/$SLUG/mounts"
SSH=( ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p "$MOCK_PORT" "$MOCK_USER@$MOCK_HOST" )
HOSTNAME_VAL=$("${SSH[@]}" "cat /proc/sys/kernel/hostname")
[ -n "$HOSTNAME_VAL" ] || { echo "FAIL: discovery returned empty hostname"; exit 1; }
cat > "context/nas/$SLUG/profile.md" <<EOF
## Connection
- host: $MOCK_HOST
- port: $MOCK_PORT
- user: $MOCK_USER
- key_path: ~/.ssh/synology-manager-plus_${SLUG}_ed25519
EOF
assert_contains "context/nas/$SLUG/profile.md" "synology-manager-plus_${SLUG}_ed25519"
echo "=== test-nas-add: ALL PASS ==="
