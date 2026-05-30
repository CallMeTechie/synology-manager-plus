---
description: One-page NAS health summary — RAID, capacity, disk temperatures, memory, load, last 24h critical log entries. Lazy profile migration writes cpu_cores on first call. Add `--all` for a fleet sweep.
allowed-tools: Bash, Read, Write, Edit
argument-hint: "[--all]"
---

# Health Summary

Aggregierte "vor dem Wegfahren"-Übersicht. SSH-only, kein State-Update außer optional Lazy Profile-Migration.

## Argument parsing

```bash
set -euo pipefail
ALL=0
for arg in ${ARGUMENTS:-}; do
  case "$arg" in
    --all) ALL=1 ;;
    "") ;;
    *) echo "Usage: /health-summary [--all]" >&2; exit 1 ;;
  esac
done
SMP_SLUG_RE='^[a-z0-9][a-z0-9-]{0,31}$'
command -v awk >/dev/null || { echo "ERROR: awk required" >&2; exit 1; }
```

## Per-NAS loader

```bash
# load_nas <slug> — set PROFILE/SLUG/HOST/PORT/NAS_USER/CONNECT_TIMEOUT/KEY_PATH/SSH/DEV_TYPE
# for the given slug. Returns 1 (non-fatal) on any failure; the --all loop skips the
# NAS, the no-flag path turns it into a fatal exit. Mirrors the canonical resolver.
load_nas() {
  local slug="$1" f
  PROFILE="context/nas/$slug/profile.md"; SLUG="$slug"
  [ -f "$PROFILE" ] || { echo "Profile missing for '$slug'" >&2; return 1; }
  for f in host port user; do
    grep -qE "^- ${f}: _not configured_" "$PROFILE" && { echo "'$slug' not configured (field '$f')" >&2; return 1; }
  done
  HOST=$(awk '/^- host:/ {print $3; exit}' "$PROFILE")
  PORT=$(awk '/^- port:/ {print $3; exit}' "$PROFILE")
  NAS_USER=$(awk '/^- user:/ {print $3; exit}' "$PROFILE")
  CONNECT_TIMEOUT=$(awk '/^- connect_timeout_seconds:/ {print $3; exit}' "$PROFILE"); CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
  KEY_PATH=$(awk '/^- key_path:/ {print $3; exit}' "$PROFILE"); KEY_PATH="${KEY_PATH:-$HOME/.ssh/synology-manager-plus_ed25519}"; KEY_PATH="${KEY_PATH/#\~/$HOME}"
  { [ -n "$HOST" ] && [ -n "$PORT" ] && [ -n "$NAS_USER" ]; } || { echo "Profile malformed for '$slug'" >&2; return 1; }
  [[ "$HOST" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo "Invalid host for '$slug'" >&2; return 1; }
  [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || { echo "Invalid port for '$slug'" >&2; return 1; }
  [[ "$NAS_USER" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "Invalid user for '$slug'" >&2; return 1; }
  [[ "$KEY_PATH" =~ ^[A-Za-z0-9_./~-]+$ ]] || { echo "Invalid key_path for '$slug'" >&2; return 1; }
  [ -f "$KEY_PATH" ] || { echo "SSH key not found for '$slug': $KEY_PATH" >&2; return 1; }
  SSH=( ssh -i "$KEY_PATH" -o ConnectTimeout="$CONNECT_TIMEOUT" -p "$PORT" "$NAS_USER@$HOST" )
  DEV_TYPE=$(awk '/^- smartctl_device_type:/ {print $3; exit}' "$PROFILE")
  case "$DEV_TYPE" in ata|sat|nvme|scsi|auto) ;; *) DEV_TYPE=ata ;; esac
  return 0
}

# verdict_rank <verdict> — mirror of smp_verdict_rank (canonical, unit-tested).
verdict_rank() { case "${1:-}" in ok|pass) echo 0 ;; warn|unreachable) echo 1 ;; *) echo 2 ;; esac; }
```

## Resolve targets

```bash
SLUGS=()
if [ "$ALL" -eq 1 ]; then
  for smp_d in context/nas/*/; do [ -f "${smp_d}profile.md" ] && SLUGS+=("$(basename "$smp_d")"); done
  [ "${#SLUGS[@]}" -gt 0 ] || { echo "No NAS configured. Run /first-run." >&2; exit 1; }
  mapfile -t SLUGS < <(printf '%s\n' "${SLUGS[@]}" | sort)   # SC2207-safe sort
else
  ACTIVE=$(cat context/active-nas 2>/dev/null | head -1 || true); ACTIVE="${ACTIVE%%[[:space:]]*}"
  if ! [[ "$ACTIVE" =~ $SMP_SLUG_RE ]] || [ ! -f "context/nas/$ACTIVE/profile.md" ]; then
    smp_found=()
    if [ -d context/nas ]; then for smp_d in context/nas/*/; do [ -f "${smp_d}profile.md" ] && smp_found+=("$(basename "$smp_d")"); done; fi
    if [ "${#smp_found[@]}" -eq 1 ]; then ACTIVE="${smp_found[0]}"; printf '%s\n' "$ACTIVE" > context/active-nas
    elif [ "${#smp_found[@]}" -eq 0 ]; then
      if [ -f context/nas-profile.md ]; then echo "Legacy single-NAS layout detected — run /first-run to upgrade to the multi-NAS layout." >&2
      else echo "No NAS configured. Run /first-run." >&2; fi
      exit 1
    else echo "No active NAS selected. Run /nas-use <slug> (see /nas-list)." >&2; exit 1; fi
  fi
  SLUGS=("$ACTIVE")
fi
WORST_RANK=0; UNREACH=0; FLEET_ROWS=""
```

## Per-NAS body

```bash
run_body() {
  "${SSH[@]}" "sudo -n true 2>/dev/null" || { echo "  ERROR: passwordless sudo required (see /smart-status for the sudoers.d/ one-liner)" >&2; return 1; }

  update_profile_field() {
    local key="$1" value="$2" tmp
    tmp=$(mktemp) || return 1
    if grep -q "^- ${key}:" "$PROFILE"; then
      awk -v k="$key" -v v="$value" '$0 ~ "^- " k ":" { print "- " k ": " v; next } { print }' "$PROFILE" > "$tmp"
    else
      awk -v k="$key" -v v="$value" '{ print } /^## Hardware/ && !inserted { print "- " k ": " v; inserted=1 }' "$PROFILE" > "$tmp"
    fi
    mv "$tmp" "$PROFILE"
  }
  CPU_CORES=$(awk '/^- cpu_cores:/ {print $3; exit}' "$PROFILE")
  if ! [[ "$CPU_CORES" =~ ^[1-9][0-9]*$ ]]; then
    NPROC=$("${SSH[@]}" "nproc" 2>/dev/null || echo "")
    if [[ "$NPROC" =~ ^[1-9][0-9]*$ ]]; then update_profile_field "cpu_cores" "$NPROC"; CPU_CORES="$NPROC"; echo "[migration] cpu_cores=$NPROC written to $PROFILE"
    else CPU_CORES=2; fi
  fi
  DISK_WARN_TEMP=$(awk '/^- disk_warn_temp_c:/ {print $3; exit}' "$PROFILE"); [[ "$DISK_WARN_TEMP" =~ ^[0-9]+$ ]] || DISK_WARN_TEMP=45
  DISK_CRITICAL_TEMP=$(awk '/^- disk_critical_temp_c:/ {print $3; exit}' "$PROFILE"); [[ "$DISK_CRITICAL_TEMP" =~ ^[0-9]+$ ]] || DISK_CRITICAL_TEMP=55

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

  OVERALL="ok"
  DF_PERCENT=$(echo "$DF_OUT" | awk '/\/volume1$/ {gsub(/%/,"",$5); print $5; exit}'); [ -n "$DF_PERCENT" ] || DF_PERCENT=0
  STORAGE_MARK="ok"
  if [ "$DF_PERCENT" -gt 90 ] 2>/dev/null; then STORAGE_MARK="critical"; OVERALL="critical"
  elif [ "$DF_PERCENT" -gt 80 ] 2>/dev/null; then STORAGE_MARK="warn"; [ "$OVERALL" = "ok" ] && OVERALL="warn"; fi
  RAID_MARK="ok"
  if echo "$RAID_OUT" | grep -qE "(degraded|recovering|rebuilding|faulty|resync)"; then RAID_MARK="critical"; OVERALL="critical"; fi
  DISK_MARK="ok"
  for t in $(echo "$DISK_TEMP_OUT" | grep -oE "[0-9]+C" | grep -oE "[0-9]+"); do
    if [ "$t" -gt "$DISK_CRITICAL_TEMP" ] 2>/dev/null; then DISK_MARK="critical"; OVERALL="critical"
    elif [ "$t" -gt "$DISK_WARN_TEMP" ] 2>/dev/null; then [ "$DISK_MARK" = "ok" ] && DISK_MARK="warn"; [ "$OVERALL" = "ok" ] && OVERALL="warn"; fi
  done
  LOAD_MARK="ok"
  LOAD5=$(echo "$LOAD_OUT" | grep -oE "load average: [0-9.]+, [0-9.]+" | awk '{print $4}' | tr -d ',')
  if [ -n "$LOAD5" ]; then LOAD_INT=${LOAD5%.*}; LIMIT=$((CPU_CORES * 2)); [ "$LOAD_INT" -gt "$LIMIT" ] 2>/dev/null && { LOAD_MARK="warn"; [ "$OVERALL" = "ok" ] && OVERALL="warn"; }; fi

  echo "NAS Health Summary — ${TS}  (${HOSTNAME_VAL:-?}, DSM ${DSM_VERSION:-?})"
  echo "===================================================================="
  echo ""
  echo "Storage:    volume1 ${DF_PERCENT}% used  [${STORAGE_MARK}]"
  echo "RAID:       $(echo "$RAID_OUT" | grep -E "^md" | head -3 | tr '\n' ' ')  [${RAID_MARK}]"
  echo "Disks:      ${DISK_TEMP_OUT}[${DISK_MARK}]"
  echo "Memory:     ${MEM_OUT}"
  echo "Load:       $(echo "$LOAD_OUT" | grep -oE "load average:.*") [${LOAD_MARK}]"
  echo ""
  echo "Recent critical events:"
  if [ -n "$LOG_OUT" ]; then echo "$LOG_OUT" | sed 's/^/  /'; else echo "  (none)"; fi
  echo ""
  echo "Overall verdict: ${OVERALL}"
  return 0
}
```

## Run

```bash
for slug in "${SLUGS[@]}"; do
  [ "$ALL" -eq 1 ] && { echo ""; echo "──────── $slug ────────"; }
  if ! load_nas "$slug"; then
    [ "$ALL" -eq 1 ] || exit 1
    r=$(verdict_rank warn); [ "$r" -gt "$WORST_RANK" ] && WORST_RANK=$r; FLEET_ROWS+="  $slug: error"$'\n'; continue
  fi
  if [ "$ALL" -eq 1 ]; then
    if ! timeout 6 ssh -i "$KEY_PATH" -o BatchMode=yes -o ConnectTimeout=3 -p "$PORT" "$NAS_USER@$HOST" true 2>/dev/null; then
      echo "  unreachable"; UNREACH=$((UNREACH+1)); r=$(verdict_rank unreachable); [ "$r" -gt "$WORST_RANK" ] && WORST_RANK=$r; FLEET_ROWS+="  $slug: unreachable"$'\n'; continue
    fi
  fi
  if ! run_body; then
    [ "$ALL" -eq 1 ] || exit 1
    r=$(verdict_rank warn); [ "$r" -gt "$WORST_RANK" ] && WORST_RANK=$r; FLEET_ROWS+="  $slug: error"$'\n'; continue
  fi
  r=$(verdict_rank "$OVERALL"); [ "$r" -gt "$WORST_RANK" ] && WORST_RANK=$r; FLEET_ROWS+="  $slug: $OVERALL"$'\n'
done
if [ "$ALL" -eq 1 ]; then
  case "$WORST_RANK" in 0) FLEET=ok ;; 1) FLEET=warn ;; *) FLEET=critical ;; esac
  echo ""; echo "Fleet summary:"; printf '%s' "$FLEET_ROWS"
  echo "Fleet verdict: $FLEET  (worst of ${#SLUGS[@]} NAS; ${UNREACH} unreachable)"
fi
```
