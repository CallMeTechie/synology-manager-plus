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

# --- smp_render_sudoers_script ---
SCRIPT="$(smp_render_sudoers_script 'svc' '/usr/local/bin/docker' '/var/services/homes/svc')"
contains() { case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac; }
check_eq "render: username interpolated"   "$(contains 'USER_NAME="svc"' "$SCRIPT")" "yes"
check_eq "render: docker path interpolated" "$(contains 'DOCKER_BIN="/usr/local/bin/docker"' "$SCRIPT")" "yes"
check_eq "render: marker absolute path"    "$(contains 'MARKER="/var/services/homes/svc/smp-sudo-setup.result"' "$SCRIPT")" "yes"
check_eq "render: no tilde in marker"      "$(contains 'MARKER="~' "$SCRIPT")" "no"
check_eq "render: dropin name no dot"      "$(contains 'DROPIN="/etc/sudoers.d/synology-manager-plus-docker"' "$SCRIPT")" "yes"
check_eq "render: temp in sudoers.d"       "$(contains 'mktemp /etc/sudoers.d/.smp-XXXXXX' "$SCRIPT")" "yes"
check_eq "render: conditional visudo"      "$(contains 'command -v visudo' "$SCRIPT")" "yes"
check_eq "render: mode 0440"               "$(contains 'chmod 0440' "$SCRIPT")" "yes"
check_eq "render: includedir check"        "$(contains 'includedir' "$SCRIPT")" "yes"
check_eq "render: includedir allows quote" "$(contains 'includedir[[:space:]]+"?/etc/sudoers' "$SCRIPT")" "yes"
check_eq "render: username sanitize"       "$(contains 'username unsafe for sudoers' "$SCRIPT")" "yes"
check_eq "render: success marker rc=0"     "$(contains 'rc=0 stage=done' "$SCRIPT")" "yes"

# --- smp_user_is_admin_probe ---
check_eq "admin probe snippet" "$(smp_user_is_admin_probe)" \
  "id -Gn 2>/dev/null | grep -qw administrators && echo admin || echo standard"

echo ""
echo "=== test-sudo-lib: $pass_count pass, $fail_count fail ==="
[ "$fail_count" -eq 0 ]
