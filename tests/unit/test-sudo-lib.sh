#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="sudo-lib"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT/plugin/commands/_sudo-lib.sh"

pass_count=0
fail_count=0

check_eq() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $label"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $label — expected '$expected', got '$actual'"
    fail_count=$((fail_count + 1))
  fi
}

# --- smp_classify_docker_info ---
check_eq "classify ok"            "$(smp_classify_docker_info '24.0.2')"                                  "ok"
check_eq "classify pwd"           "$(smp_classify_docker_info 'sudo: a password is required')"            "password-required"
check_eq "classify daemon-down"   "$(smp_classify_docker_info 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock')" "daemon-down"
check_eq "classify not-found"     "$(smp_classify_docker_info 'sudo: /usr/local/bin/docker: command not found')" "not-found"
check_eq "classify unknown"       "$(smp_classify_docker_info 'some weird output')"                       "unknown"

echo ""
echo "=== test-sudo-lib: $pass_count pass, $fail_count fail ==="
[ "$fail_count" -eq 0 ]
