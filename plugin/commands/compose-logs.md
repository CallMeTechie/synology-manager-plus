---
description: View logs from a Compose project (aggregated or per-service). Read-only. Supports tail, since, and per-service filters.
argument-hint: "<project> [--tail=N] [--since=Nh|Nd] [--service=NAME]"
allowed-tools: Bash, Read
---

# Compose Logs

Logs eines Compose-Projekts (aggregiert oder per Service).

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
