---
description: One-page NAS health summary — RAID, capacity, disk temperatures, memory, load, last 24h critical log entries. Read-only.
allowed-tools: Bash, Read, Write, Edit
---

# Health Summary

Aggregierte "vor dem Wegfahren"-Übersicht. SSH-only, kein State-Update außer optional Lazy Profile-Migration.

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
command -v awk >/dev/null || { echo "ERROR: awk required" >&2; exit 1; }

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
  echo "ERROR: passwordless sudo required (see /smart-status for the sudoers.d/ one-liner)" >&2
  exit 1
}
```

## Lazy Profile-Migration

```bash
update_profile_field() {
  local key="$1" value="$2" tmp
  tmp=$(mktemp) || return 1
  if grep -q "^- ${key}:" "$PROFILE"; then
    awk -v k="$key" -v v="$value" '
      $0 ~ "^- " k ":" { print "- " k ": " v; next }
      { print }
    ' "$PROFILE" > "$tmp"
  else
    awk -v k="$key" -v v="$value" '
      { print }
      /^## Hardware/ && !inserted { print "- " k ": " v; inserted=1 }
    ' "$PROFILE" > "$tmp"
  fi
  mv "$tmp" "$PROFILE"
}

CPU_CORES=$(awk '/^- cpu_cores:/ {print $3; exit}' "$PROFILE")
if ! [[ "$CPU_CORES" =~ ^[1-9][0-9]*$ ]]; then
  NPROC=$("${SSH[@]}" "nproc" 2>/dev/null || echo "")
  if [[ "$NPROC" =~ ^[1-9][0-9]*$ ]]; then
    update_profile_field "cpu_cores" "$NPROC"
    CPU_CORES="$NPROC"
    echo "[migration] cpu_cores=$NPROC written to nas-profile.md"
  else
    CPU_CORES=2
  fi
fi

DISK_WARN_TEMP=$(awk '/^- disk_warn_temp_c:/ {print $3; exit}' "$PROFILE")
[[ "$DISK_WARN_TEMP" =~ ^[0-9]+$ ]] || DISK_WARN_TEMP=45
DISK_CRITICAL_TEMP=$(awk '/^- disk_critical_temp_c:/ {print $3; exit}' "$PROFILE")
[[ "$DISK_CRITICAL_TEMP" =~ ^[0-9]+$ ]] || DISK_CRITICAL_TEMP=55
```

## Queries

```bash
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DSM_VERSION=$("${SSH[@]}" "awk -F'\"' '/^productversion=/{print \$2; exit}' /etc/VERSION" 2>/dev/null)
HOSTNAME_VAL=$("${SSH[@]}" "cat /proc/sys/kernel/hostname" 2>/dev/null)

DF_OUT=$("${SSH[@]}" "df -h" 2>/dev/null || echo "(query failed)")
RAID_OUT=$("${SSH[@]}" "cat /proc/mdstat 2>/dev/null | head -20" 2>/dev/null || echo "(query failed)")
MEM_OUT=$("${SSH[@]}" "free -h | awk '/^Mem:/'" 2>/dev/null || echo "(query failed)")
LOAD_OUT=$("${SSH[@]}" "uptime" 2>/dev/null || echo "(query failed)")
LOG_OUT=$("${SSH[@]}" "tail -n 200 /var/log/messages /var/log/synolog/synolog.cur 2>/dev/null | grep -iE 'error|critical|fail' | tail -10" 2>/dev/null || echo "")

DISK_TEMP_OUT=""
DISKS=$("${SSH[@]}" "sudo -n /usr/bin/smartctl --scan 2>&1" | awk '/^\/dev\/sd[a-z]/ {print $1}')
for DEV in $DISKS; do
  RAW=$("${SSH[@]}" "sudo -n /usr/bin/smartctl -d $DEV_TYPE -a $DEV 2>&1" | awk '$1==194 {print $NF; exit}')
  DISK_TEMP_OUT+="${DEV} ${RAW:-?}C  "
done
```

## Verdict + Output

```bash
OVERALL="ok"

DF_PERCENT=$(echo "$DF_OUT" | awk '/\/volume1$/ {gsub(/%/,"",$5); print $5; exit}')
[ -n "$DF_PERCENT" ] || DF_PERCENT=0
STORAGE_MARK="ok"
if [ "$DF_PERCENT" -gt 90 ] 2>/dev/null; then STORAGE_MARK="critical"; OVERALL="critical"
elif [ "$DF_PERCENT" -gt 80 ] 2>/dev/null; then STORAGE_MARK="warn"; [ "$OVERALL" = "ok" ] && OVERALL="warn"
fi

DISK_MARK="ok"
for t in $(echo "$DISK_TEMP_OUT" | grep -oE "[0-9]+C" | grep -oE "[0-9]+"); do
  if [ "$t" -gt "$DISK_CRITICAL_TEMP" ] 2>/dev/null; then DISK_MARK="critical"; OVERALL="critical"
  elif [ "$t" -gt "$DISK_WARN_TEMP" ] 2>/dev/null; then [ "$DISK_MARK" = "ok" ] && DISK_MARK="warn"; [ "$OVERALL" = "ok" ] && OVERALL="warn"
  fi
done

LOAD_MARK="ok"
LOAD5=$(echo "$LOAD_OUT" | grep -oE "load average: [0-9.]+, [0-9.]+" | awk '{print $4}' | tr -d ',')
if [ -n "$LOAD5" ]; then
  LOAD_INT=${LOAD5%.*}
  LIMIT=$((CPU_CORES * 2))
  [ "$LOAD_INT" -gt "$LIMIT" ] 2>/dev/null && { LOAD_MARK="warn"; [ "$OVERALL" = "ok" ] && OVERALL="warn"; }
fi

echo "NAS Health Summary — ${TS}  (${HOSTNAME_VAL:-?}, DSM ${DSM_VERSION:-?})"
echo "===================================================================="
echo ""
echo "Storage:    volume1 ${DF_PERCENT}% used  [${STORAGE_MARK}]"
echo "RAID:       $(echo "$RAID_OUT" | grep -E "^md" | head -3 | tr '\n' ' ')"
echo "Disks:      ${DISK_TEMP_OUT}[${DISK_MARK}]"
echo "Memory:     ${MEM_OUT}"
echo "Load:       $(echo "$LOAD_OUT" | grep -oE "load average:.*") [${LOAD_MARK}]"
echo ""
echo "Recent critical events:"
if [ -n "$LOG_OUT" ]; then
  echo "$LOG_OUT" | sed 's/^/  /'
else
  echo "  (none)"
fi
echo ""
echo "Overall verdict: ${OVERALL}"
```
