---
description: List Docker Compose projects on the NAS with status, container counts, and config-file paths. Read-only. Uses docker compose ls --format json.
allowed-tools: Bash, Read
---

# Compose List

Übersicht aller Compose-Projekte (running + stopped).

## Resolve active NAS (do this first)

```bash
set -euo pipefail

# === synology-manager-plus: resolve active NAS profile (multi-NAS layout) ===
# Mirrors plugin/commands/_profile-lib.sh (canonical, unit-tested). Commands
# cannot source libs, so this block is embedded inline. Keep in sync with the lib.
SMP_SLUG_RE='^[a-z0-9][a-z0-9-]{0,31}$'

ACTIVE=$(cat context/active-nas 2>/dev/null | head -1 || true)
ACTIVE="${ACTIVE%%[[:space:]]*}"
if ! [[ "$ACTIVE" =~ $SMP_SLUG_RE ]] || [ ! -f "context/nas/$ACTIVE/profile.md" ]; then
  smp_found=()
  if [ -d context/nas ]; then
    for smp_d in context/nas/*/; do
      [ -f "${smp_d}profile.md" ] && smp_found+=("$(basename "$smp_d")")
    done
  fi
  if [ "${#smp_found[@]}" -eq 1 ]; then
    ACTIVE="${smp_found[0]}"; printf '%s\n' "$ACTIVE" > context/active-nas
  elif [ "${#smp_found[@]}" -eq 0 ]; then
    if [ -f context/nas-profile.md ]; then
      echo "Legacy single-NAS layout detected — run /first-run to upgrade to the multi-NAS layout." >&2
    else
      echo "No NAS configured. Run /first-run." >&2
    fi
    exit 1
  else
    echo "No active NAS selected. Run /nas-use <slug> (see /nas-list)." >&2; exit 1
  fi
fi
PROFILE="context/nas/$ACTIVE/profile.md"
SLUG="$ACTIVE"

for smp_field in host port user; do
  if grep -qE "^- ${smp_field}: _not configured_" "$PROFILE"; then
    echo "Profile not yet configured (field '${smp_field}') — run /first-run" >&2; exit 1
  fi
done
HOST=$(awk '/^- host:/ {print $3; exit}' "$PROFILE")
PORT=$(awk '/^- port:/ {print $3; exit}' "$PROFILE")
NAS_USER=$(awk '/^- user:/ {print $3; exit}' "$PROFILE")
CONNECT_TIMEOUT=$(awk '/^- connect_timeout_seconds:/ {print $3; exit}' "$PROFILE")
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
KEY_PATH=$(awk '/^- key_path:/ {print $3; exit}' "$PROFILE")
KEY_PATH="${KEY_PATH:-$HOME/.ssh/synology-manager-plus_ed25519}"
KEY_PATH="${KEY_PATH/#\~/$HOME}"

for smp_var in HOST PORT NAS_USER; do
  [ -n "${!smp_var}" ] || { echo "Profile field $smp_var malformed in $PROFILE — re-run /first-run" >&2; exit 1; }
done
[[ "$HOST" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo "Invalid host: $HOST" >&2; exit 1; }
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || { echo "Invalid port: $PORT" >&2; exit 1; }
[[ "$NAS_USER" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "Invalid user: $NAS_USER" >&2; exit 1; }
[[ "$KEY_PATH" =~ ^[A-Za-z0-9_./~-]+$ ]] || { echo "Invalid key_path: $KEY_PATH" >&2; exit 1; }
[ -f "$KEY_PATH" ] || { echo "SSH key not found: $KEY_PATH" >&2; exit 1; }

SSH=( ssh -i "$KEY_PATH" -o ConnectTimeout="$CONNECT_TIMEOUT" -p "$PORT" "$NAS_USER@$HOST" )
# === end resolver block ===
```

## SSH + daemon precheck

```bash
DOCKER_INFO=$("${SSH[@]}" "sudo -n /usr/local/bin/docker info --format '{{.ServerVersion}}' 2>&1" || true)
if ! echo "$DOCKER_INFO" | grep -q '^[0-9][0-9]*\.[0-9]'; then
  if echo "$DOCKER_INFO" | grep -qi "a password is required"; then
    echo "ERROR: passwordless sudo for /usr/local/bin/docker is not configured on the NAS." >&2
    echo "  Fix: run /setup-docker-sudo (guided Task Scheduler setup + verification)." >&2
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
