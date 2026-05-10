---
description: List all shared folders on the NAS and refresh the volume snapshot in context.
allowed-tools: Bash, Read, Write
---

# List Shared Folders

## Profile extraction (do this first)

Markdown commands cannot share helper code, and `shellcheck-commands.sh` only inspects fenced bash blocks. So this block must be duplicated literally — referencing it as prose would leave the validation logic out of CI and out of the LLM agent's reading frame.

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

## Query

```bash
SSH=(
  ssh
  -i "$HOME/.ssh/synology-manager-plus_ed25519"
  -o ConnectTimeout="$CONNECT_TIMEOUT"
  -p "$PORT"
  "$NAS_USER@$HOST"
)

# 1. Top-level shared folders on volume1
"${SSH[@]}" "ls -la /volume1/"

# 2. Detect additional volumes
"${SSH[@]}" "df -h | awk '/\\/volume[0-9]+/ {print \$NF}'"
```

For each detected volume (volume1, volume2, …), run `ls -la /<volume>/` and save the output with a timestamp header to `context/volumes/<volume>-snapshot.txt`:

```text
# Snapshot taken: <ISO 8601 UTC>
<output>
```

Display the volume listings to the user.
