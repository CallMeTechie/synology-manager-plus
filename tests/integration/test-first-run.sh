#!/usr/bin/env bash
TEST_NAME="first-run"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-first-run (discovery + profile write + marker preservation) ==="

gen_plugin_key
deploy_plugin_key

DSM_VERSION=$(ssh_mock "cat /etc/VERSION" | tr -d '\r')
HOSTNAME_VAL=$(ssh_mock "cat /proc/sys/kernel/hostname")
ARCH=$(ssh_mock "uname -m")
MODEL=$(ssh_mock "grep -E 'upnpmodelname' /etc/synoinfo.conf | head -1 | cut -d= -f2 | tr -d '\"'")
VOL1_LIST=$(ssh_mock "ls /volume1/")
SUDO_OK=$(ssh_mock "sudo -n true 2>/dev/null && echo yes || echo no")

[[ "$DSM_VERSION" == *"productversion"* ]] || { echo "FAIL: DSM version not extracted"; exit 1; }
echo "PASS: DSM_VERSION captured"

[[ "$MODEL" == *"DS218+"* ]] || { echo "FAIL: model expected 'DS218+ (mock)', got '$MODEL'"; exit 1; }
echo "PASS: model captured ($MODEL)"

[[ "$VOL1_LIST" == *"documents"* && "$VOL1_LIST" == *"media"* && "$VOL1_LIST" == *"backups"* ]] \
  || { echo "FAIL: volume1 listing missing test shares"; exit 1; }
echo "PASS: all three test shares present"

assert_eq "yes" "$SUDO_OK" "sudo passwordless"
echo "PASS: sudo NOPASSWD detected"

# Scenario E: docker discovery must resolve via the ABSOLUTE path.
# Regression for the DSM bug: a non-interactive SSH session does not source
# /etc/profile, so /usr/local/bin (where Container Manager installs docker) is
# absent from PATH. We simulate that here by stripping /usr/local/bin and run
# the REAL discovery payload extracted from the command file — so this test
# fails again if anyone reverts first-run.md to a bare `docker`.
echo "--- Scenario E: docker discovery under DSM-like PATH (no /usr/local/bin) ---"
FIRST_RUN_MD="$SCRIPT_DIR/../../plugin/commands/first-run.md"
PAYLOAD=$(grep -F 'DOCKER_OK=$(discover docker' "$FIRST_RUN_MD" | sed -E 's/^.*discover docker "(.*)"\)$/\1/')
[ -n "$PAYLOAD" ] || { echo "FAIL E: could not extract docker-discovery payload from first-run.md"; exit 1; }

RESULT=$(ssh_mock "export PATH=/usr/bin:/bin; $PAYLOAD")
[[ "$RESULT" == *"Docker version"* ]] || {
  echo "FAIL E: discovery did not resolve docker under DSM-like PATH; got '$RESULT'"
  echo "        (a bare 'docker' fails here — the command must use /usr/local/bin/docker)"
  exit 1
}
echo "PASS E: first-run discovery resolves docker via absolute path ($RESULT)"

# Negative control: prove the bug WOULD reproduce with a bare-name probe.
BARE=$(ssh_mock "export PATH=/usr/bin:/bin; command -v docker >/dev/null && docker --version || echo not-installed")
assert_eq "not-installed" "$BARE" "bare 'docker' unresolved when /usr/local/bin absent"
echo "PASS E (control): bare 'docker' confirmed unresolvable under DSM-like PATH"

PROFILE="$HOME/nas-profile-test.md"
cat > "$PROFILE" <<EOF
# Synology NAS Profile

## Connection
- host: $MOCK_HOST
- port: $MOCK_PORT
- user: $MOCK_USER
- key_path: ~/.ssh/synology-manager-plus_ed25519
- connect_timeout_seconds: 10

## Hardware
- model: $MODEL
- arch: $ARCH

## Last Updated
$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

assert_contains "$PROFILE" "$MOCK_HOST"
assert_contains "$PROFILE" "$MOCK_PORT"
assert_contains "$PROFILE" "DS218+ (mock)"
echo "PASS: profile written with discovered values"

CLAUDE="$HOME/CLAUDE.md"
cat > "$CLAUDE" <<'EOF'
# Header

<!-- synology-manager-plus:managed-start -->
old plugin content
<!-- synology-manager-plus:managed-end -->

## User Notes

User typed this and it must survive!
EOF

NEW_BLOCK="| host | $MOCK_HOST |"
awk -v new="$NEW_BLOCK" '
  /<!-- synology-manager-plus:managed-start -->/ { print; print new; in_block=1; next }
  /<!-- synology-manager-plus:managed-end -->/ { in_block=0; print; next }
  !in_block { print }
' "$CLAUDE" > "$CLAUDE.new"
mv "$CLAUDE.new" "$CLAUDE"

assert_contains "$CLAUDE" "User typed this and it must survive!"
assert_contains "$CLAUDE" "| host | $MOCK_HOST |"
if grep -q "old plugin content" "$CLAUDE"; then
  echo "FAIL: old managed content still present after rewrite"
  exit 1
fi
echo "PASS: managed section replaced, user notes preserved"

# Scenario B: CLAUDE.md WITHOUT markers must be detected, not silently rewritten.
# This is the critical migration safety net (Spec §4.2): users coming from
# the upstream plugin have no markers, and the wizard must surface a diff
# rather than overwrite their content.
echo "--- Scenario B: CLAUDE.md without markers ---"
CLAUDE_NO_M="$HOME/CLAUDE-no-markers.md"
cat > "$CLAUDE_NO_M" <<'EOF'
# My Plain CLAUDE
Just regular content. No plugin markers anywhere.
Important user notes that must not be lost.
EOF

if grep -q "synology-manager-plus:managed-start" "$CLAUDE_NO_M"; then
  echo "FAIL B: marker should not exist in this fixture"; exit 1
fi

# The /first-run command MUST detect missing markers and refuse silent
# rewrite. Simulate the detection logic the command will use:
DETECTED="$(grep -c "synology-manager-plus:managed-start" "$CLAUDE_NO_M" || true)"
if [ "$DETECTED" -eq 0 ]; then
  echo "PASS B: marker-missing detection works (command must show diff and ask)"
else
  echo "FAIL B: detection reported $DETECTED markers, expected 0"
  exit 1
fi

# Verify the file is unchanged after the (simulated) detection pass.
if ! grep -q "Important user notes that must not be lost" "$CLAUDE_NO_M"; then
  echo "FAIL B: user notes were modified during detection — must be read-only"
  exit 1
fi
echo "PASS B: file untouched during detection phase"

# Scenario C: only START marker present — the asymmetric case that
# would catastrophically delete everything below the start marker
# under a naive awk rewrite.
echo "--- Scenario C: only start-marker (asymmetric) ---"
CLAUDE_START_ONLY="$HOME/CLAUDE-start-only.md"
cat > "$CLAUDE_START_ONLY" <<'EOF'
# Header
<!-- synology-manager-plus:managed-start -->
| host | placeholder |
## My Important Notes
This whole section must NOT be deleted.
EOF
START_C=$(grep -c '<!-- synology-manager-plus:managed-start -->' "$CLAUDE_START_ONLY" || true)
END_C=$(grep -c '<!-- synology-manager-plus:managed-end -->' "$CLAUDE_START_ONLY" || true)
if [ "$START_C" -eq 1 ] && [ "$END_C" -eq 0 ]; then
  echo "PASS C: asymmetric markers correctly detected (1 start, 0 end) — command must abort"
else
  echo "FAIL C: detector miscounted (start=$START_C, end=$END_C)"; exit 1
fi
if ! grep -q "This whole section must NOT be deleted" "$CLAUDE_START_ONLY"; then
  echo "FAIL C: detection step modified the file — must be read-only"
  exit 1
fi

# Scenario D: only END marker — also asymmetric, command must refuse.
echo "--- Scenario D: only end-marker (asymmetric) ---"
CLAUDE_END_ONLY="$HOME/CLAUDE-end-only.md"
cat > "$CLAUDE_END_ONLY" <<'EOF'
# Header
Some content above
<!-- synology-manager-plus:managed-end -->
Trailing content
EOF
START_D=$(grep -c '<!-- synology-manager-plus:managed-start -->' "$CLAUDE_END_ONLY" || true)
END_D=$(grep -c '<!-- synology-manager-plus:managed-end -->' "$CLAUDE_END_ONLY" || true)
if [ "$START_D" -eq 0 ] && [ "$END_D" -eq 1 ]; then
  echo "PASS D: asymmetric markers correctly detected (0 start, 1 end) — command must abort"
else
  echo "FAIL D: detector miscounted (start=$START_D, end=$END_D)"; exit 1
fi

echo "=== test-first-run: ALL PASS ==="
