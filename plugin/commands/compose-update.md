---
description: Pull new images and restart a Compose stack atomically (best-effort). Mutating. Best-effort && chain — pull failure aborts before up -d.
argument-hint: "<project>"
allowed-tools: Bash, Read
---

# Compose Update

`docker compose pull && up -d` in einem SSH-Roundtrip, JSON-Diff-Verdict.

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

## Argument parsing — project REQUIRED

```bash
project=""
for arg in ${ARGUMENTS:-}; do
  case "$arg" in
    "") ;;
    -*) echo "Unknown flag: $arg" >&2; exit 1 ;;
    *) if [ -z "$project" ]; then project="$arg"
       else echo "Multiple positional args not allowed" >&2; exit 1
       fi ;;
  esac
done

if [ -z "$project" ]; then
  echo "ERROR: <project> is required." >&2
  echo "Usage: /compose-update <project>" >&2
  exit 1
fi
[[ "$project" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "Invalid project name" >&2; exit 1; }
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
  exit 1
fi
```

## .env validation

```bash
ENV_DIR=$("${SSH[@]}" "dirname '$CONFIG_FILE'")
ENV_PATH="$ENV_DIR/.env"
ENV_FLAG=""
ENV_EXISTS=$("${SSH[@]}" "test -e '$ENV_PATH' && echo yes || echo no")
if [ "$ENV_EXISTS" = "yes" ]; then
  ENV_READABLE=$("${SSH[@]}" "test -r '$ENV_PATH' && echo yes || echo no")
  if [ "$ENV_READABLE" = "no" ]; then
    echo "ERROR: .env exists at $ENV_PATH but is unreadable. Stack would start with empty env vars." >&2
    echo "  Fix: sudo chmod 0640 '$ENV_PATH' && sudo chown :docker '$ENV_PATH'" >&2
    exit 1
  fi
  ENV_FLAG="--env-file $ENV_PATH"
fi
```

## Before-state, pull && up, after-state

```bash
echo "Update: $project"
echo ""

BEFORE=$("${SSH[@]}" "sudo -n /usr/local/bin/docker compose -f '$CONFIG_FILE' ps --format json" || echo "")

# shellcheck disable=SC2029
PULL_UP_OUT=$("${SSH[@]}" "sudo -n /usr/local/bin/docker compose -f '$CONFIG_FILE' $ENV_FLAG pull && sudo -n /usr/local/bin/docker compose -f '$CONFIG_FILE' $ENV_FLAG up -d 2>&1" || true)
PULL_UP_EXIT=$?

echo "--- raw compose pull + up -d output ---"
echo "$PULL_UP_OUT"
echo "--- end raw output ---"
echo ""

AFTER=$("${SSH[@]}" "sudo -n /usr/local/bin/docker compose -f '$CONFIG_FILE' ps --format json" || echo "")

if [ $PULL_UP_EXIT -ne 0 ]; then
  echo "Verdict: update FAILED (pull or up-d returned exit $PULL_UP_EXIT)."
  echo "Stack state may be partial — review the raw output above."
  exit $PULL_UP_EXIT
fi

UPDATED=0
TOTAL=0
echo "Service Image Change Summary:"
# AFTER + BEFORE are JSON-Arrays (Compose v2.20.1). Iterate via jq.
while IFS=$'\t' read -r svc new_img; do
  [ -z "$svc" ] && continue
  old_img=$(echo "$BEFORE" | jq -r --arg s "$svc" '.[] | select(.Service == $s) | .Image' | head -1)
  TOTAL=$((TOTAL + 1))
  if [ "$old_img" != "$new_img" ] && [ -n "$old_img" ]; then
    printf "  %-25s %s -> %s  (UPDATED)\n" "$svc" "$old_img" "$new_img"
    UPDATED=$((UPDATED + 1))
  else
    printf "  %-25s %s  (unchanged)\n" "$svc" "$new_img"
  fi
done < <(echo "$AFTER" | jq -r '.[] | [.Service, .Image] | @tsv')

echo ""
echo "Final Status:"
echo "$AFTER" | jq -r '.[] | [.Service, .Status, (.Health // "-" | if . == "" then "-" else . end)] | @tsv' | \
while IFS=$'\t' read -r svc status health; do
  printf "  %-25s %-25s %s\n" "$svc" "$status" "$health"
done

UNHEALTHY=$(echo "$AFTER" | jq '[.[] | select(.Health == "unhealthy")] | length')
echo ""
if [ "$UNHEALTHY" -gt 0 ]; then
  echo "Verdict: $UPDATED of $TOTAL services updated, $UNHEALTHY unhealthy — investigate."
  exit 1
else
  echo "Verdict: $UPDATED of $TOTAL services updated, all healthy."
fi
```
