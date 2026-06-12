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

# --- smp_docker_sudo_probe (SSH array via nameref; stubbed) ---
# The probe runs "${SSH[@]}" "<cmd>". A bash function as the array element
# receives the command string as $1 and ignores it, returning canned output.
stub_ok()  { echo "24.0.2"; }
stub_pwd() { echo "sudo: a password is required"; }
SSH_OK=( stub_ok );  check_eq "probe ok"  "$(smp_docker_sudo_probe SSH_OK)"  "ok"
SSH_PW=( stub_pwd ); check_eq "probe pwd" "$(smp_docker_sudo_probe SSH_PW)"  "password-required"

# set -e safety: a failing SSH (non-zero) must not abort the caller.
stub_fail() { echo "boom"; return 1; }
SSH_FAIL=( stub_fail ); check_eq "probe unknown on fail" "$(smp_docker_sudo_probe SSH_FAIL)" "unknown"

echo ""
echo "=== test-sudo-lib: $pass_count pass, $fail_count fail ==="
[ "$fail_count" -eq 0 ]
