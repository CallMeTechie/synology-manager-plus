---
description: Check whether a DSM update is available. Read-only — never installs. Reports installed version and DSM status-code mapping.
allowed-tools: Bash, Read
---

# DSM Update Check

DSM-Update read-only Status-Check. DSM gibt Status-Code-Konstanten zurück.

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

## Sudo pre-check + installed version

```bash
"${SSH[@]}" "sudo -n true 2>/dev/null" || {
  echo "ERROR: passwordless sudo required (see /smart-status for the sudoers.d/ one-liner)" >&2
  exit 1
}

INSTALLED=$("${SSH[@]}" "awk -F'\"' '/^productversion=/{print \$2}' /etc/VERSION; awk -F'\"' '/^buildnumber=/{print \$2}' /etc/VERSION; awk -F'\"' '/^smallfixnumber=/{print \$2}' /etc/VERSION" 2>/dev/null)
VERSION=$(echo "$INSTALLED" | sed -n 1p)
BUILD=$(echo "$INSTALLED" | sed -n 2p)
SMALLFIX=$(echo "$INSTALLED" | sed -n 3p)
```

## synoupgrade check

```bash
OUT=$("${SSH[@]}" "sudo -n /usr/syno/sbin/synoupgrade --check 2>&1")
STATUS=$(echo "$OUT" | head -1 | awk '{print $1}')

case "$STATUS" in
  UPGRADE_HAS_NEW_DSM)
    STATE="update-available"
    ;;
  UPGRADE_CHECKNEWDSM|UPGRADE_HAS_NO_NEW_DSM|UPGRADE_UP_TO_DATE)
    # UPGRADE_CHECKNEWDSM was empirically verified against a DSM 7.3.1-86003
    # Update 1 install (latest at the time of writing; DSM Web UI
    # showed no available update). The literal name "check new DSM" is
    # misleading — it actually means "check was performed, no new DSM found".
    STATE="up-to-date"
    ;;
  UPGRADE_CHECKNEWDSM_FAILED)
    STATE="check-failed"
    ;;
  *)
    echo "DSM Update Check — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "Installed:  DSM ${VERSION:-?}-${BUILD:-?} Update ${SMALLFIX:-?}"
    echo "Status:     UNKNOWN — synoupgrade returned '$STATUS' (raw: ${OUT:0:200})"
    echo "Action:     Open DSM Web UI to check manually."
    exit 1
    ;;
esac

echo "DSM Update Check — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""
echo "Installed:  DSM ${VERSION:-?}-${BUILD:-?} Update ${SMALLFIX:-?}"

case "$STATE" in
  update-available)
    echo "Status:     Update available (synoupgrade: $STATUS)"
    echo "Action:     Open DSM Web UI to install."
    ;;
  up-to-date)
    echo "Status:     Up to date (synoupgrade: $STATUS)"
    ;;
  check-failed)
    echo "Status:     Check failed (synoupgrade: $STATUS)"
    echo "Action:     Retry later or check DSM Web UI manually."
    ;;
esac
```
