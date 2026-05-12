---
description: List all Docker containers on the NAS (compose-tagged + standalone). Read-only. Optional --all flag includes stopped containers.
argument-hint: "[--all]"
allowed-tools: Bash, Read
---

# Docker List

Flache Container-Liste, getaggte und standalone.

## Profile extraction

```bash
set -euo pipefail

PROFILE="context/nas-profile.md"
[ -f "$PROFILE" ] || { echo "Profile missing — run /first-run first" >&2; exit 1; }

for field in host port user; do
  if grep -qE "^- ${field}: _not configured_" "$PROFILE"; then
    echo "Profile not yet configured — run /first-run" >&2
    exit 1
  fi
done

HOST=$(awk '/^- host:/ {print $3; exit}' "$PROFILE")
PORT=$(awk '/^- port:/ {print $3; exit}' "$PROFILE")
NAS_USER=$(awk '/^- user:/ {print $3; exit}' "$PROFILE")
CONNECT_TIMEOUT=$(awk '/^- connect_timeout_seconds:/ {print $3; exit}' "$PROFILE")
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"

[[ "$HOST" =~ ^[a-zA-Z0-9.-]+$ ]] || exit 1
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || exit 1
[[ "$NAS_USER" =~ ^[a-zA-Z0-9_.-]+$ ]] || exit 1
```

## Argument parsing

```bash
all_flag=0
for arg in ${ARGUMENTS:-}; do
  case "$arg" in
    --all) all_flag=1 ;;
    "") ;;
    *) echo "Unknown argument: $arg" >&2
       echo "Usage: /docker-list [--all]" >&2
       exit 1 ;;
  esac
done
```

## SSH + daemon precheck

```bash
SSH=( ssh -i "$HOME/.ssh/synology-manager-plus_ed25519" -o ConnectTimeout="$CONNECT_TIMEOUT" -p "$PORT" "$NAS_USER@$HOST" )

DOCKER_INFO=$("${SSH[@]}" "sudo -n /usr/local/bin/docker info --format '{{.ServerVersion}}' 2>&1" || true)
if ! echo "$DOCKER_INFO" | grep -q '^[0-9][0-9]*\.[0-9]'; then
  if echo "$DOCKER_INFO" | grep -qi "a password is required"; then
    echo "ERROR: passwordless sudo for /usr/local/bin/docker is not configured. See /compose-list for fix." >&2
  elif echo "$DOCKER_INFO" | grep -qi "Cannot connect to the Docker daemon"; then
    echo "ERROR: Docker daemon is not running. Check pkgctl-ContainerManager." >&2
  else
    echo "ERROR: docker info: $DOCKER_INFO" >&2
  fi
  exit 1
fi
```

## Query + format

```bash
FMT='{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Label "com.docker.compose.project"}}'
if [ "$all_flag" -eq 1 ]; then
  RAW=$("${SSH[@]}" "sudo -n /usr/local/bin/docker ps --all --format '$FMT'")
else
  RAW=$("${SSH[@]}" "sudo -n /usr/local/bin/docker ps --format '$FMT'")
fi

if [ -z "$RAW" ]; then
  echo "No containers found."
  exit 0
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "Containers on $HOST — $NOW"
echo ""
printf "%-25s %-40s %-15s %s\n" "NAME" "IMAGE" "STATUS" "COMPOSE-PROJECT"

running=0
stopped=0
standalone=0
while IFS=$'\t' read -r name image status project; do
  display_project="${project:-(standalone)}"
  [ -z "$project" ] && standalone=$((standalone + 1))
  if echo "$status" | grep -qi "^Up"; then
    running=$((running + 1))
  else
    stopped=$((stopped + 1))
  fi
  printf "%-25s %-40s %-15s %s\n" "$name" "$image" "$status" "$display_project"
done <<< "$RAW"

echo ""
echo "Verdict: $running running, $stopped stopped, $standalone standalone"
```
