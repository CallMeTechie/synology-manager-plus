#!/usr/bin/env bash
# Shared helpers for /compose-* commands. Sourced from each Command-Markdown.
# Run shellcheck directly: `shellcheck _compose-lib.sh`.

# is_critical_compose_project <project_name> <comma_separated_whitelist>
# exit 0 = critical (caller should prompt user)
# exit 1 = not critical (caller may proceed directly)
is_critical_compose_project() {
  local project="$1" list="$2"
  [ -z "$list" ] && return 1
  local -a entries
  IFS=',' read -ra entries <<< "$list"
  local entry
  for entry in "${entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ -z "$entry" ] && continue
    [ "$entry" = "$project" ] && return 0
  done
  return 1
}

# docker_daemon_precheck <ssh-array-name>
# Calls 'sudo -n docker info' over SSH and classifies the result.
# Prints diagnostic on stderr and returns non-zero if daemon or sudo
# is not usable.
docker_daemon_precheck() {
  local ssh_var="$1"
  # shellcheck disable=SC2178
  local -n ssh_ref="$ssh_var"
  local out
  out=$("${ssh_ref[@]}" "sudo -n /usr/local/bin/docker info --format '{{.ServerVersion}}' 2>&1" || true)
  if echo "$out" | grep -q '^[0-9][0-9]*\.[0-9]'; then
    return 0
  fi
  if echo "$out" | grep -qi "a password is required"; then
    echo "ERROR: passwordless sudo for /usr/local/bin/docker is not configured on the NAS." >&2
    echo "  Fix:" >&2
    echo "    echo '<user> ALL=(ALL) NOPASSWD: /usr/local/bin/docker' | \\" >&2
    echo "      sudo tee /etc/sudoers.d/synology-manager-plus-docker" >&2
    echo "    sudo chmod 0440 /etc/sudoers.d/synology-manager-plus-docker" >&2
    return 1
  fi
  if echo "$out" | grep -qi "Cannot connect to the Docker daemon"; then
    echo "ERROR: Docker daemon is not running on the NAS." >&2
    echo "  Check status: sudo synoservice --status pkgctl-ContainerManager" >&2
    return 1
  fi
  if echo "$out" | grep -qi "command not found"; then
    echo "ERROR: docker binary not at /usr/local/bin/docker." >&2
    echo "  Run 'which docker' on the NAS and adjust the sudoers Drop-in path." >&2
    return 1
  fi
  echo "ERROR: docker info unexpected output:" >&2
  echo "$out" | head -3 >&2
  return 1
}
