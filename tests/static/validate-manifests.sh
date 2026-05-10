#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MARKETPLACE="$ROOT/.claude-plugin/marketplace.json"
PLUGIN="$ROOT/plugin/.claude-plugin/plugin.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# 1. JSON validity
jq empty "$MARKETPLACE" || fail "marketplace.json is invalid JSON"
pass "marketplace.json is valid JSON"
jq empty "$PLUGIN" || fail "plugin.json is invalid JSON"
pass "plugin.json is valid JSON"

# 2. Required marketplace fields
for field in name owner.name plugins; do
  jq -e ".${field}" "$MARKETPLACE" >/dev/null \
    || fail "marketplace.json missing field: $field"
done
pass "marketplace.json has required fields"

# 3. Required plugin fields
for field in name version description license; do
  jq -e ".${field}" "$PLUGIN" >/dev/null \
    || fail "plugin.json missing field: $field"
done
pass "plugin.json has required fields"

# 4. Marketplace plugins[].source resolves
SOURCE=$(jq -r '.plugins[0].source' "$MARKETPLACE")
[ -d "$ROOT/$SOURCE" ] || fail "plugins[0].source '$SOURCE' does not point to an existing directory"
pass "marketplace source path resolves to $SOURCE"

# 5. Name consistency
M_NAME=$(jq -r '.plugins[0].name' "$MARKETPLACE")
P_NAME=$(jq -r '.name' "$PLUGIN")
[ "$M_NAME" = "$P_NAME" ] \
  || fail "marketplace plugins[0].name ($M_NAME) != plugin.json name ($P_NAME)"
pass "marketplace and plugin names match"

# 6. CHANGELOG consistency (only check if CHANGELOG.md exists)
if [ -f "$ROOT/CHANGELOG.md" ]; then
  P_VER=$(jq -r '.version' "$PLUGIN")
  grep -q "## \[$P_VER\]" "$ROOT/CHANGELOG.md" \
    || fail "plugin.json version $P_VER not found in CHANGELOG.md"
  pass "CHANGELOG.md has entry for version $P_VER"
fi

echo "All manifest checks passed."
