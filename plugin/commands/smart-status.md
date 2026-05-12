---
description: Show SMART health for both NAS disks (temperature, reallocated/pending sectors, power-on hours) with a pass/warn/critical verdict.
allowed-tools: Bash, Read
---

# Smart Status

SMART-Health pro Disk mit Verdict. Verifiziert gegen DSM 7.3.1 mit smartctl 6.5 (Text-Format).

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

## Tool pre-check + device-type

```bash
command -v awk >/dev/null || { echo "ERROR: /smart-status needs 'awk'" >&2; exit 1; }

DEV_TYPE=$(awk '/^- smartctl_device_type:/ {print $3; exit}' "$PROFILE")
case "$DEV_TYPE" in
  ata|sat|nvme|scsi|auto) ;;
  *) DEV_TYPE=ata ;;
esac
```

## Sudo pre-check

```bash
SSH=( ssh -i "$HOME/.ssh/synology-manager-plus_ed25519" -o ConnectTimeout="$CONNECT_TIMEOUT" -p "$PORT" "$NAS_USER@$HOST" )

"${SSH[@]}" "sudo -n true 2>/dev/null" || {
  echo "ERROR: /smart-status needs passwordless sudo for smartctl." >&2
  echo "Fix (DSM has no visudo, use sudoers.d drop-in):" >&2
  echo "  echo '$NAS_USER ALL=(ALL) NOPASSWD: /usr/bin/smartctl, /usr/syno/sbin/synoupgrade' | sudo tee /etc/sudoers.d/synology-manager-plus" >&2
  echo "  sudo chmod 0440 /etc/sudoers.d/synology-manager-plus" >&2
  exit 1
}
```

## Per-disk SMART read + verdict

```bash
DISKS=$("${SSH[@]}" "sudo -n /usr/bin/smartctl --scan 2>&1" | awk '/^\/dev\/sd[a-z]/ {print $1}')
[ -z "$DISKS" ] && { echo "ERROR: smartctl --scan returned no disks" >&2; exit 1; }

WORST_VERDICT="pass"
echo "SMART Status ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
echo "==============================================="

for DEV in $DISKS; do
  OUT=$("${SSH[@]}" "sudo -n /usr/bin/smartctl -d $DEV_TYPE -a $DEV 2>&1")
  if [ -z "$OUT" ]; then
    echo ""
    echo "Disk $DEV — ERROR: smartctl returned no output"
    WORST_VERDICT="critical"
    continue
  fi

  MODEL=$(echo "$OUT" | awk -F: '/^Device Model:/ {sub(/^ +/,"",$2); print $2; exit}')
  SERIAL=$(echo "$OUT" | awk -F: '/^Serial Number:/ {sub(/^ +/,"",$2); print $2; exit}')

  if echo "$OUT" | grep -q "SMART overall-health self-assessment test result: PASSED"; then
    PASSED=true
  elif echo "$OUT" | grep -q "SMART overall-health self-assessment test result: FAILED"; then
    PASSED=false
  else
    PASSED=unknown
  fi

  attr_raw() {
    echo "$OUT" | awk -v id="$1" '$1==id {print $NF; exit}'
  }
  REALLOC=$(attr_raw 5)
  PENDING=$(attr_raw 197)
  TEMP=$(attr_raw 194)
  HOURS=$(attr_raw 9)

  if [ "$PASSED" = "unknown" ] && [ -z "$REALLOC" ] && [ -z "$TEMP" ]; then
    echo ""
    echo "Disk $DEV — ERROR: smartctl output unexpected"
    echo "  Hint: try 'smartctl_device_type: sat' in nas-profile.md (current: $DEV_TYPE)"
    WORST_VERDICT="critical"
    continue
  fi

  REALLOC="${REALLOC:-0}"
  PENDING="${PENDING:-0}"
  TEMP="${TEMP:-0}"
  HOURS="${HOURS:-0}"

  VERDICT="pass"
  REASON=""
  if [ "$PASSED" = "false" ]; then
    VERDICT="critical"; REASON="SMART overall-health FAILED"
  elif [ "$REALLOC" -gt 100 ] 2>/dev/null; then
    VERDICT="critical"; REASON="Reallocated sectors $REALLOC > 100"
  elif [ "$PENDING" -gt 0 ] 2>/dev/null; then
    VERDICT="critical"; REASON="Pending sectors $PENDING > 0"
  elif [ "$TEMP" -gt 55 ] 2>/dev/null; then
    VERDICT="critical"; REASON="Temperature ${TEMP}C > 55"
  elif [ "$PASSED" = "unknown" ]; then
    VERDICT="warn"; REASON="SMART health-statement absent"
  elif [ "$REALLOC" -gt 0 ] 2>/dev/null && [ "$REALLOC" -le 100 ] 2>/dev/null; then
    VERDICT="warn"; REASON="${REALLOC} reallocated sectors — monitor"
  elif [ "$TEMP" -gt 45 ] 2>/dev/null; then
    VERDICT="warn"; REASON="Temperature ${TEMP}C > 45"
  fi

  echo ""
  echo "Disk $DEV — ${MODEL:-unknown} (${SERIAL:-unknown})"
  echo "  Health:      ${PASSED}"
  echo "  Temperature: ${TEMP}C"
  echo "  Power-On:    ${HOURS}h"
  echo "  Reallocated: ${REALLOC}"
  echo "  Pending:     ${PENDING}"
  if [ -n "$REASON" ]; then
    echo "  Verdict:     ${VERDICT}  ($REASON)"
  else
    echo "  Verdict:     ${VERDICT}"
  fi

  case "$VERDICT" in
    critical) WORST_VERDICT="critical" ;;
    warn) [ "$WORST_VERDICT" = "pass" ] && WORST_VERDICT="warn" ;;
  esac
done

echo ""
echo "Overall: ${WORST_VERDICT}"
```
