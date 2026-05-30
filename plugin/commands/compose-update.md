---
description: Pull new images and restart a Compose stack atomically (best-effort). Mutating. Best-effort && chain — pull failure aborts before up -d.
argument-hint: "<project>"
allowed-tools: Bash, Read
---

# Compose Update

`docker compose pull && up -d` in einem SSH-Roundtrip, JSON-Diff-Verdict.

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

# Capture exit code without 'set -e' aborting. The `|| true` trick would
# always yield exit 0, making the failure-branch unreachable; instead
# use an if-let pattern that keeps $? meaningful.
# shellcheck disable=SC2029
if PULL_UP_OUT=$("${SSH[@]}" "sudo -n /usr/local/bin/docker compose -f '$CONFIG_FILE' $ENV_FLAG pull && sudo -n /usr/local/bin/docker compose -f '$CONFIG_FILE' $ENV_FLAG up -d 2>&1"); then
  PULL_UP_EXIT=0
else
  PULL_UP_EXIT=$?
fi

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
