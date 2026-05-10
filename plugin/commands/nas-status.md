---
description: Query the NAS for current disk usage, RAID status, services, and load. Refreshes context/storage-report.md.
allowed-tools: Bash, Read, Write, Edit
---

# NAS Status

## Profile extraction (do this first)

Read `context/nas-profile.md` and extract values. Variable name `NAS_USER` (not `USER`) — `$USER` is the local login user on every Linux system and would silently shadow.

The placeholder check uses a positive grep against the template string (`_not configured_`) instead of fishing out word-3 ("`_not`") with awk. The grep approach survives template changes (e.g. switching to `<unset>`); the awk-word approach is fragile by accident.

`set -euo pipefail` at the top is critical: without `-o pipefail`, a piped expression like `discover ... | tr -d '\r'` would swallow `discover()`'s `exit 1` and continue with empty output. Every command starts with this guard for the same reason.

```bash
set -euo pipefail

PROFILE="context/nas-profile.md"
[ -f "$PROFILE" ] || { echo "Profile missing — run /first-run first" >&2; exit 1; }

# Reject any profile that still has placeholder values for core fields.
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

# Empty extraction is its own failure mode (malformed profile, multi-word value).
# Surface which line is bad rather than the generic "Invalid".
for var in HOST PORT NAS_USER; do
  if [ -z "${!var}" ]; then
    echo "Profile field $var is empty or malformed in $PROFILE — re-run /first-run" >&2
    exit 1
  fi
done

[[ "$HOST" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo "Invalid host: $HOST" >&2; exit 1; }
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || { echo "Invalid port: $PORT" >&2; exit 1; }
[[ "$NAS_USER" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "Invalid user: $NAS_USER" >&2; exit 1; }
```

## Run queries

Use an SSH argument array — never a string-interpolated `SSH_BASE` — so hostnames with hyphens, dots, or spaces never word-split:

```bash
SSH=(
  ssh
  -i "$HOME/.ssh/synology-manager-plus_ed25519"
  -o ConnectTimeout="$CONNECT_TIMEOUT"
  -p "$PORT"
  "$NAS_USER@$HOST"
)

# 1. Disk usage
"${SSH[@]}" "df -h"

# 2. RAID status
"${SSH[@]}" "cat /proc/mdstat 2>/dev/null || echo 'mdstat not available'"

# 3. Running Synology services (top 40)
"${SSH[@]}" "synoservice --list 2>/dev/null | head -40 || echo 'synoservice not available'"

# 4. System load and memory
"${SSH[@]}" "uptime && free -h"
```

Display the results clearly to the user. Then update `context/storage-report.md` with:

- A header timestamp (`_Last refresh: <ISO 8601 UTC>_`).
- The `df -h` output in a fenced code block.
- The RAID summary (one line if healthy, otherwise the full mdstat).
- The load and memory snapshot.
