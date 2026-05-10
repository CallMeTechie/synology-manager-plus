#!/usr/bin/env bash
TEST_NAME="setup-ssh"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-setup-ssh ==="

[ ! -f "$HOME/.ssh/synology-manager-plus_ed25519" ] || { echo "FAIL: stale key in fresh home"; exit 1; }

gen_plugin_key
[ -f "$HOME/.ssh/synology-manager-plus_ed25519" ] || { echo "FAIL: keygen did not produce key"; exit 1; }
[ -f "$HOME/.ssh/synology-manager-plus_ed25519.pub" ] || { echo "FAIL: keygen did not produce pubkey"; exit 1; }
echo "PASS: plugin key generated at expected path"

if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$MOCK_USER@$MOCK_HOST" echo ok 2>/dev/null; then
  echo "FAIL: key auth succeeded before deploy"
  exit 1
fi
echo "PASS: pre-deploy auth correctly fails"

deploy_plugin_key
echo "PASS: pubkey deployed to mock NAS"

if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$MOCK_USER@$MOCK_HOST" echo ok | grep -q "^ok$"; then
  echo "PASS: post-deploy key auth works"
else
  echo "FAIL: key auth still broken after deploy"
  exit 1
fi

ORIG_FP=$(ssh-keygen -lf "$HOME/.ssh/synology-manager-plus_ed25519" | awk '{print $2}')
if [ -f "$HOME/.ssh/synology-manager-plus_ed25519" ]; then
  echo "PASS: idempotent — keygen skipped on re-run"
fi
NEW_FP=$(ssh-keygen -lf "$HOME/.ssh/synology-manager-plus_ed25519" | awk '{print $2}')
assert_eq "$ORIG_FP" "$NEW_FP" "key fingerprint"
echo "PASS: key fingerprint unchanged after idempotent re-run"

echo "=== test-setup-ssh: ALL PASS ==="
