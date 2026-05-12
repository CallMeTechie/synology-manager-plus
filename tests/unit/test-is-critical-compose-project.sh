#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="is-critical-compose-project"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT/plugin/commands/_compose-lib.sh"

pass_count=0
fail_count=0

run_case() {
  local label="$1" project="$2" list="$3" expected="$4"
  local actual
  if is_critical_compose_project "$project" "$list"; then
    actual="critical"
  else
    actual="not-critical"
  fi
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $label"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $label — expected '$expected', got '$actual'"
    fail_count=$((fail_count + 1))
  fi
}

run_case "empty list"                  "mailpilot" ""                              "not-critical"
run_case "single match"                "mailpilot" "mailpilot"                     "critical"
run_case "multi-list with match"       "mailpilot" "mailpilot,gatecontrol"         "critical"
run_case "multi-list no match"         "watchtower" "mailpilot,gatecontrol"        "not-critical"
run_case "leading whitespace match"    "mailpilot" "  mailpilot,gatecontrol"       "critical"
run_case "trailing whitespace match"   "mailpilot" "mailpilot  ,gatecontrol"       "critical"
run_case "substring not full match"    "mailpilot-x" "mailpilot"                   "not-critical"
run_case "trailing comma harmless"     "watchtower" "mailpilot,gatecontrol,"       "not-critical"
run_case "empty entry between commas"  "watchtower" "mailpilot,,gatecontrol"       "not-critical"
run_case "case sensitive"              "Mailpilot" "mailpilot"                     "not-critical"

echo ""
echo "=== test-is-critical-compose-project: $pass_count pass, $fail_count fail ==="
[ "$fail_count" -eq 0 ]
