#!/usr/bin/env bash
TEST_NAME="nas-use"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
trap cleanup_test_home EXIT
setup_test_home
echo "=== test-nas-use ==="
cd "$TMP_HOME"
mkdir -p context/nas/main context/nas/backup
for s in main backup; do
  printf '## Connection\n- host: 10.0.0.1\n- port: 22\n- user: admin\n- connect_timeout_seconds: 10\n## Hardware\n- model: DS\n## Software\n- dsm_version: 7\n- critical_compose_projects:\n' > "context/nas/$s/profile.md"
done
echo main > context/active-nas
cat > CLAUDE.md <<'EOF'
# Workspace
<!-- synology-manager-plus:managed-start -->
old quick reference
## Scoped Operations
- [x] Volume management
<!-- synology-manager-plus:managed-end -->
keep-this-user-note
EOF
ARGUMENTS="backup" run_command_snippets "$SCRIPT_DIR/../../plugin/commands/nas-use.md" >/dev/null 2>&1 \
  || { echo "FAIL: nas-use errored"; exit 1; }
assert_eq "backup" "$(cat context/active-nas)" "active-nas switched"
grep -q "Active NAS:.*backup" CLAUDE.md || { echo "FAIL: CLAUDE.md missing new active"; cat CLAUDE.md; exit 1; }
grep -q "Volume management" CLAUDE.md || { echo "FAIL: Scoped Operations not preserved"; exit 1; }
grep -q "keep-this-user-note" CLAUDE.md || { echo "FAIL: user note after end-marker lost"; exit 1; }
echo "=== test-nas-use: ALL PASS ==="
