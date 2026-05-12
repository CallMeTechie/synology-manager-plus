---
description: Check whether a DSM update is available. Read-only — never installs. Reports installed version and DSM status-code mapping.
allowed-tools: Bash, Read
---

# DSM Update Check

DSM-Update read-only Status-Check. DSM gibt Status-Code-Konstanten zurück.

## Profile extraction

```bash
set -euo pipefail

PROFILE="context/nas-profile.md"
[ -f "$PROFILE" ] || { echo "Profile missing — run /first-run first" >&2; exit 1; }

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

for var in HOST PORT NAS_USER; do
  [ -z "${!var}" ] && { echo "Profile field $var malformed" >&2; exit 1; }
done

[[ "$HOST" =~ ^[a-zA-Z0-9.-]+$ ]] || exit 1
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || exit 1
[[ "$NAS_USER" =~ ^[a-zA-Z0-9_.-]+$ ]] || exit 1
```

## Sudo pre-check + installed version

```bash
SSH=( ssh -i "$HOME/.ssh/synology-manager-plus_ed25519" -o ConnectTimeout="$CONNECT_TIMEOUT" -p "$PORT" "$NAS_USER@$HOST" )

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
  UPGRADE_HAS_NEW_DSM|UPGRADE_CHECKNEWDSM)
    STATE="update-available"
    ;;
  UPGRADE_HAS_NO_NEW_DSM|UPGRADE_UP_TO_DATE)
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
