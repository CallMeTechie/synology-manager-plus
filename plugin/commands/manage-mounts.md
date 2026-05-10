---
description: View, add, or remove NFS/SAMBA mounts between this machine and the NAS.
argument-hint: "[list | mount <share> <local-path> | unmount <local-path>]"
allowed-tools: Bash, Read, Write, AskUserQuestion
---

# Manage NAS Mounts

## Profile extraction

Same prelude as `/nas-status` — duplicated literally so `shellcheck-commands.sh` actually inspects it. Only `HOST` and `NAS_USER` are strictly used by this command, but the full prelude prevents drift between commands.

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

Dispatch by `$ARGUMENTS`:

## list

```bash
mount | grep -F "$HOST" || echo "No mounts to/from $HOST"
```

Update `context/mounts/current.txt` with the output and a timestamp header.

## mount <share> <local-path>

Validate `<share>` against `^[a-zA-Z0-9_.-]+$` and `<local-path>` is an absolute path matching `^/[^[:space:]]+$`.

Ask the user (via `AskUserQuestion`) which protocol to use: NFS or SMB/CIFS.

```bash
mkdir -p "<local-path>"

# NFS variant:
sudo mount -t nfs "$HOST":/volume1/<share> "<local-path>"

# SMB/CIFS variant:
sudo mount -t cifs "//$HOST/<share>" "<local-path>" -o "username=$NAS_USER"
```

After mounting, verify with `mount | grep -F "$HOST"` and append the new mount to `context/mounts/current.txt`.

## unmount <local-path>

Validate `<local-path>` as above.

```bash
sudo umount "<local-path>"
```

Update `context/mounts/current.txt`.

---

If no argument is provided, run the `list` action and ask the user what they would like to do next.
