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

# smp_render_sudoers_script <username> <docker_path> <home_path>
# Echoes the root setup script for the DSM Task Scheduler. The script:
#  - fails early (with a result marker) if /etc/sudoers does not include sudoers.d
#  - creates the temp file INSIDE /etc/sudoers.d (dot-prefixed -> ignored) so the
#    final `mv` is an atomic same-fs rename (no half-written-line lockout window)
#  - validates with visudo if present, recording validated=yes/no in the marker
#  - writes a plugin-readable result marker (rc/stage/validated) to <home>/...
smp_render_sudoers_script() {
  local user="$1" docker="$2" home="$3"
  cat <<EOF
#!/bin/sh
# synology-manager-plus: NOPASSWD only for the docker binary (effective root).
USER_NAME="$user"
DOCKER_BIN="$docker"
DROPIN="/etc/sudoers.d/synology-manager-plus-docker"
MARKER="$home/smp-sudo-setup.result"
LINE="\$USER_NAME ALL=(ALL) NOPASSWD: \$DOCKER_BIN"

fail() { echo "rc=1 stage=\$1 msg=\$2" > "\$MARKER"; chmod 0644 "\$MARKER" 2>/dev/null; exit 1; }

# Defense-in-depth for the no-visudo case: reject a username that would produce a
# syntactically invalid sudoers line (an invalid drop-in can break sudo system-wide).
printf '%s' "\$USER_NAME" | grep -qE '^[A-Za-z0-9_.@-]+\$' \\
  || fail validate "username unsafe for sudoers"

# Accept both modern @includedir and legacy #includedir, quoted or unquoted path.
grep -Eq '^[@#]includedir[[:space:]]+"?/etc/sudoers\.d' /etc/sudoers \\
  || fail includedir "/etc/sudoers includes no /etc/sudoers.d"

TMP="\$(mktemp /etc/sudoers.d/.smp-XXXXXX)" || fail mktemp "mktemp unavailable"
printf '%s\n' "\$LINE" > "\$TMP"

if command -v visudo >/dev/null 2>&1; then
  visudo -cf "\$TMP" || { rm -f "\$TMP"; fail visudo "syntax check failed"; }
  VALIDATED=yes
else
  VALIDATED=no
fi

chown root:root "\$TMP" && chmod 0440 "\$TMP" || { rm -f "\$TMP"; fail perms "chown/chmod failed"; }
mv -f "\$TMP" "\$DROPIN" || { rm -f "\$TMP"; fail install "rename to sudoers.d failed"; }

echo "rc=0 stage=done validated=\$VALIDATED user=\$USER_NAME bin=\$DOCKER_BIN" > "\$MARKER"
chmod 0644 "\$MARKER" 2>/dev/null
echo "OK: NOPASSWD for \$USER_NAME -> \$DOCKER_BIN active."
EOF
}
