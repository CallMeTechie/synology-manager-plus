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
