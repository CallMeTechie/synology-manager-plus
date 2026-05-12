---
description: Start a stopped Compose stack. Mutating. Requires explicit project argument; if multiple stopped projects exist, the command lists them and exits with usage.
argument-hint: "[project]"
allowed-tools: Bash, Read
---

# Compose Up

Compose-Stack starten (`docker compose up -d`).

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
for arg in ${ARGUMENTS:-}; do
  case "$arg" in
    "") ;;
    -*) echo "Unknown flag: $arg" >&2; exit 1 ;;
    *)  if [ -z "$project" ]; then
          project="$arg"
        else
          echo "Multiple positional args not allowed" >&2
          exit 1
        fi ;;
  esac
done

if [ -n "$project" ]; then
  [[ "$project" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "Invalid project name" >&2; exit 1; }
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

if [ -z "$project" ]; then
  STOPPED=$(echo "$PROJECTS" | jq -r '.[] | select(.Status | startswith("exited") or startswith("created")) | .Name')
  if [ -z "$STOPPED" ]; then
    echo "All discovered projects are already running."
    exit 0
  fi
  echo "Stopped projects:"
  echo "$STOPPED" | sed 's/^/  /'
  echo ""
  echo "ERROR: please re-run with explicit project name." >&2
  echo "Usage: /compose-up <project>" >&2
  exit 1
fi

ENTRY=$(echo "$PROJECTS" | jq -r --arg p "$project" '.[] | select(.Name == $p) | {Status, ConfigFiles} | @json')
if [ -z "$ENTRY" ] || [ "$ENTRY" = "null" ]; then
  echo "ERROR: project '$project' not found." >&2
  echo "Run /compose-list to see available projects." >&2
  exit 1
fi
STATUS=$(echo "$ENTRY" | jq -r '.Status')
CONFIG_FILE=$(echo "$ENTRY" | jq -r '.ConfigFiles' | head -1)

if echo "$STATUS" | grep -q "^running"; then
  echo "Project '$project' is already running ($STATUS) — nothing to do."
  exit 0
fi
```

## .env validation + up

```bash
ENV_DIR=$("${SSH[@]}" "dirname '$CONFIG_FILE'")
ENV_PATH="$ENV_DIR/.env"
ENV_FLAG=""
ENV_EXISTS=$("${SSH[@]}" "test -e '$ENV_PATH' && echo yes || echo no")
if [ "$ENV_EXISTS" = "yes" ]; then
  ENV_READABLE=$("${SSH[@]}" "test -r '$ENV_PATH' && echo yes || echo no")
  if [ "$ENV_READABLE" = "no" ]; then
    echo "ERROR: .env exists at $ENV_PATH but is unreadable by '$NAS_USER'." >&2
    echo "  Compose would silently substitute \${VAR} to empty strings." >&2
    echo "  Fix: sudo chmod 0640 '$ENV_PATH' && sudo chown :docker '$ENV_PATH'" >&2
    exit 1
  fi
  ENV_FLAG="--env-file $ENV_PATH"
fi

# Capture exit code without `set -e` aborting. A bare SSH call would
# abort the script before we could format a useful error message.
# shellcheck disable=SC2029
if "${SSH[@]}" "sudo -n /usr/local/bin/docker compose -f '$CONFIG_FILE' $ENV_FLAG up -d 2>&1"; then
  UP_EXIT=0
else
  UP_EXIT=$?
fi

if [ $UP_EXIT -ne 0 ]; then
  echo "ERROR: 'docker compose up -d' failed (exit $UP_EXIT)." >&2
  exit $UP_EXIT
fi

sleep 2
PS=$("${SSH[@]}" "sudo -n /usr/local/bin/docker compose -f '$CONFIG_FILE' ps --format json")
echo ""
echo "Post-Up Status:"
# ps --format json returns a JSON-Array (Compose v2.20.1) — iterate via jq
echo "$PS" | jq -r '.[] | [.Name, .Service, .Status, (.Health // "-" | if . == "" then "-" else . end)] | @tsv' | \
while IFS=$'\t' read -r name service status health; do
  printf "  %-30s %-15s %-25s %s\n" "$name" "$service" "$status" "$health"
done

UNHEALTHY=$(echo "$PS" | jq '[.[] | select(.Health == "unhealthy")] | length')
PENDING=$(echo "$PS" | jq '[.[] | select(.Health == "starting")] | length')
if [ "$UNHEALTHY" -gt 0 ]; then
  echo ""
  echo "Verdict: started, $UNHEALTHY service(s) unhealthy — investigate logs."
  exit 1
elif [ "$PENDING" -gt 0 ]; then
  echo ""
  echo "Verdict: started, $PENDING service(s) health pending — re-check in 1-2 min."
else
  echo ""
  echo "Verdict: started, all services healthy."
fi
```
