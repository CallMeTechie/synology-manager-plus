---
description: View logs from a Compose project (aggregated or per-service). Read-only. Supports tail, since, and per-service filters.
argument-hint: "<project> [--tail=N] [--since=Nh|Nd] [--service=NAME]"
allowed-tools: Bash, Read
---

# Compose Logs

Logs eines Compose-Projekts (aggregiert oder per Service).

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
project=""
tail="200"
since="1h"
service=""

for arg in ${ARGUMENTS:-}; do
  case "$arg" in
    --tail=*)    tail="${arg#*=}" ;;
    --since=*)   since="${arg#*=}" ;;
    --service=*) service="${arg#*=}" ;;
    "") ;;
    -*) echo "Unknown flag: $arg" >&2
        echo "Usage: /compose-logs <project> [--tail=N] [--since=Nh|Nd] [--service=NAME]" >&2
        exit 1 ;;
    *) if [ -z "$project" ]; then
         project="$arg"
       else
         echo "Multiple positional arguments not allowed: '$project' and '$arg'" >&2
         exit 1
       fi ;;
  esac
done

if [ -z "$project" ]; then
  echo "ERROR: <project> is required." >&2
  echo "Usage: /compose-logs <project> [--tail=N] [--since=Nh|Nd] [--service=NAME]" >&2
  exit 1
fi

[[ "$tail" =~ ^[0-9]+$ ]] || { echo "Invalid --tail: $tail" >&2; exit 1; }
if [ "$tail" -lt 1 ] || [ "$tail" -gt 5000 ]; then
  echo "Invalid --tail: $tail (must be 1..5000)" >&2; exit 1
fi
[[ "$since" =~ ^[0-9]+[hd]$ ]] || { echo "Invalid --since: $since (use Nh or Nd)" >&2; exit 1; }
[[ "$project" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "Invalid project name" >&2; exit 1; }
if [ -n "$service" ]; then
  [[ "$service" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "Invalid --service" >&2; exit 1; }
fi
```

## SSH + daemon precheck + discovery

```bash
SSH=( ssh -i "$HOME/.ssh/synology-manager-plus_ed25519" -o ConnectTimeout="$CONNECT_TIMEOUT" -p "$PORT" "$NAS_USER@$HOST" )

DOCKER_INFO=$("${SSH[@]}" "sudo -n /usr/local/bin/docker info --format '{{.ServerVersion}}' 2>&1" || true)
if ! echo "$DOCKER_INFO" | grep -q '^[0-9][0-9]*\.[0-9]'; then
  echo "ERROR: docker daemon unreachable. Run /compose-list for diagnostics." >&2
  exit 1
fi

PROJECTS=$("${SSH[@]}" "sudo -n /usr/local/bin/docker compose ls --all --format json")
CONFIG_FILE=$(echo "$PROJECTS" | jq -r --arg p "$project" '.[] | select(.Name == $p) | .ConfigFiles' | head -1)
if [ -z "$CONFIG_FILE" ] || [ "$CONFIG_FILE" = "null" ]; then
  echo "ERROR: project '$project' not found." >&2
  echo "Run /compose-list to see available projects." >&2
  exit 1
fi
```

## Run logs

```bash
SERVICE_ARG=""
if [ -n "$service" ]; then SERVICE_ARG="$service"; fi

# shellcheck disable=SC2029
RAW=$("${SSH[@]}" "sudo -n /usr/local/bin/docker compose -f '$CONFIG_FILE' logs --no-color --tail=$tail --since=$since $SERVICE_ARG 2>&1" || true)

if [ -z "$RAW" ]; then
  echo "(no log lines in last $since for $project)"
  exit 0
fi

TOTAL=$(echo "$RAW" | wc -l)
echo "$RAW" | head -200
if [ "$TOTAL" -gt 200 ]; then
  echo ""
  echo "... ($((TOTAL - 200)) more lines truncated; use --service=NAME to narrow)"
fi
```
