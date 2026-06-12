#!/usr/bin/env bash
# Shared helpers for passwordless docker-sudo setup. Canonical, unit-tested.
# Commands CANNOT source libs at runtime — first-run.md and setup-docker-sudo.md
# embed inline mirrors of these functions. Keep them in sync.
# Run shellcheck directly: `shellcheck _sudo-lib.sh`.

# smp_classify_docker_info <raw-output>
# Pure: maps the output of `sudo -n /usr/local/bin/docker info --format '{{.ServerVersion}}'`
# (or its stderr on failure) to exactly one status token on stdout:
#   ok | password-required | daemon-down | not-found | unknown
smp_classify_docker_info() {
  local out="$1"
  if printf '%s' "$out" | grep -q '^[0-9][0-9]*\.[0-9]'; then
    echo ok
  elif printf '%s' "$out" | grep -qi 'a password is required'; then
    echo password-required
  elif printf '%s' "$out" | grep -qi 'cannot connect to the .* daemon'; then
    echo daemon-down
  elif printf '%s' "$out" | grep -qiE 'command not found|no such file'; then
    echo not-found
  else
    echo unknown
  fi
}

# smp_docker_sudo_probe <ssh-array-name>
# Runs 'sudo -n /usr/local/bin/docker info' over the named SSH array and echoes
# one status token (see smp_classify_docker_info). The docker path is the literal
# /usr/local/bin/docker — the abspath regression guard forbids a path variable,
# and the entire codebase hardcodes this path; a non-standard path surfaces as
# 'not-found'. set -e safe: never returns non-zero, never aborts the caller.
smp_docker_sudo_probe() {
  local ssh_var="$1"
  # shellcheck disable=SC2178
  local -n ssh_ref="$ssh_var"
  local out
  out=$("${ssh_ref[@]}" "sudo -n /usr/local/bin/docker info --format '{{.ServerVersion}}' 2>&1" || true)
  smp_classify_docker_info "$out"
}
