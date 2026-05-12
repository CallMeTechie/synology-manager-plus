---
description: List Docker Compose projects on the NAS with status, container counts, and config-file paths. Read-only. Uses docker compose ls --format json.
allowed-tools: Bash, Read
---

# Compose List

Übersicht aller Compose-Projekte (running + stopped).

## Profile extraction

```bash
set -euo pipefail

PROFILE="context/nas-profile.md"
[ -f "$PROFILE" ] || { echo "Profile missing — run /first-run first" >&2; exit 1; }

for field in host port user; do
  if grep -qE "^- ${field}: _not configured_" "$PROFILE"; then
    echo "Profile not yet configured (field '${field}' is placeholder) — run /first-run" >&2
    exit 1
  fi
done

HOST=$(awk '/^- host:/ {print $3; exit}' "$PROFILE")
PORT=$(awk '/^- port:/ {print $3; exit}' "$PROFILE")
NAS_USER=$(awk '/^- user:/ {print $3; exit}' "$PROFILE")
CONNECT_TIMEOUT=$(awk '/^- connect_timeout_seconds:/ {print $3; exit}' "$PROFILE")
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"

for var in HOST PORT NAS_USER; do
  [ -z "${!var}" ] && { echo "Profile field $var malformed" >&2; exit 1; }
done

[[ "$HOST" =~ ^[a-zA-Z0-9.-]+$ ]] || exit 1
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || exit 1
[[ "$NAS_USER" =~ ^[a-zA-Z0-9_.-]+$ ]] || exit 1
```

## SSH + daemon precheck

```bash
SSH=( ssh -i "$HOME/.ssh/synology-manager-plus_ed25519" -o ConnectTimeout="$CONNECT_TIMEOUT" -p "$PORT" "$NAS_USER@$HOST" )

DOCKER_INFO=$("${SSH[@]}" "sudo -n /usr/local/bin/docker info --format '{{.ServerVersion}}' 2>&1" || true)
if ! echo "$DOCKER_INFO" | grep -q '^[0-9][0-9]*\.[0-9]'; then
  if echo "$DOCKER_INFO" | grep -qi "a password is required"; then
    echo "ERROR: passwordless sudo for /usr/local/bin/docker is not configured on the NAS." >&2
    echo "  Fix on the NAS:" >&2
    echo "    echo '$NAS_USER ALL=(ALL) NOPASSWD: /usr/local/bin/docker' \\" >&2
    echo "      | sudo tee /etc/sudoers.d/synology-manager-plus-docker" >&2
    echo "    sudo chmod 0440 /etc/sudoers.d/synology-manager-plus-docker" >&2
  elif echo "$DOCKER_INFO" | grep -qi "Cannot connect to the Docker daemon"; then
    echo "ERROR: Docker daemon is not running on the NAS." >&2
    echo "  Check status: sudo synoservice --status pkgctl-ContainerManager" >&2
  elif echo "$DOCKER_INFO" | grep -qi "command not found"; then
    echo "ERROR: docker binary not at /usr/local/bin/docker." >&2
    echo "  Run 'ssh <nas> which docker' and adjust the sudoers Drop-in path." >&2
  else
    echo "ERROR: docker info returned unexpected output:" >&2
    echo "$DOCKER_INFO" | head -3 >&2
  fi
  exit 1
fi
```

## Query + format

```bash
RAW=$("${SSH[@]}" "sudo -n /usr/local/bin/docker compose ls --all --format json 2>&1" || echo "[]")

COUNT=$(echo "$RAW" | jq 'length' 2>/dev/null || echo "0")
if [ "$COUNT" = "0" ]; then
  echo "No compose projects found on this NAS."
  exit 0
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "Compose Projects on $HOST — $NOW"
echo ""
printf "%-20s %-18s %-11s %s\n" "PROJECT" "STATUS" "CONTAINERS" "CONFIG"

echo "$RAW" | jq -r '.[] | [.Name, .Status, (.Status | capture("running\\((?<n>[0-9]+)\\)") | .n // "0"), .ConfigFiles] | @tsv' 2>/dev/null | \
while IFS=$'\t' read -r name status containers config; do
  printf "%-20s %-18s %-11s %s\n" "$name" "$status" "$containers" "$config"
done

ACTIVE=$(echo "$RAW" | jq '[.[] | select(.Status | startswith("running"))] | length')
STOPPED=$(echo "$RAW" | jq '[.[] | select(.Status | startswith("exited") or startswith("created"))] | length')
echo ""
echo "Verdict: $ACTIVE active, $STOPPED stopped"
```
