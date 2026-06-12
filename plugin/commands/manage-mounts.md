---
description: View, add, or remove NFS/SAMBA mounts between this machine and the NAS.
argument-hint: "[list | mount <share> <local-path> | unmount <local-path>]"
allowed-tools: Bash, Read, Write, AskUserQuestion
---

# Manage NAS Mounts

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

Dispatch by `$ARGUMENTS`:

## list

```bash
mount | grep -F "$HOST" || echo "No mounts to/from $HOST"
```

```bash
mkdir -p "context/nas/$SLUG/mounts"
```

Update `context/nas/$SLUG/mounts/current.txt` with the output and a timestamp header.

## mount

Parse `$ARGUMENTS` into `$SHARE` and `$LOCAL_PATH` (the second and third tokens after the `mount` keyword). Validate `$SHARE` against `^[a-zA-Z0-9_.-]+$` and `$LOCAL_PATH` against `^/[^[:space:]]+$`. Reject and abort on failure.

Ask the user (via `AskUserQuestion`) which protocol to use: NFS or SMB/CIFS.

```bash
[[ "$SHARE" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "Invalid share name: $SHARE" >&2; exit 1; }
[[ "$LOCAL_PATH" =~ ^/[^[:space:]]+$ ]] || { echo "Invalid local path: $LOCAL_PATH" >&2; exit 1; }

mkdir -p "$LOCAL_PATH"

# NFS variant:
sudo mount -t nfs "$HOST:/volume1/$SHARE" "$LOCAL_PATH"

# SMB/CIFS variant:
sudo mount -t cifs "//$HOST/$SHARE" "$LOCAL_PATH" -o "username=$NAS_USER"
```

After mounting, verify with `mount | grep -F "$HOST"` and append the new mount to `context/nas/$SLUG/mounts/current.txt`.

## unmount

Parse `$LOCAL_PATH` from `$ARGUMENTS` (the second token after the `unmount` keyword). Validate as above.

```bash
[[ "$LOCAL_PATH" =~ ^/[^[:space:]]+$ ]] || { echo "Invalid local path: $LOCAL_PATH" >&2; exit 1; }

sudo umount "$LOCAL_PATH"
```

Update `context/nas/$SLUG/mounts/current.txt`.

---

If no argument is provided, run the `list` action and ask the user what they would like to do next.
