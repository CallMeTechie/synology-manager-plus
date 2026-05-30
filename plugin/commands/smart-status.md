---
description: Show SMART health for both NAS disks (temperature, reallocated/pending sectors, power-on hours) with a pass/warn/critical verdict. Add `--all` for a fleet sweep.
allowed-tools: Bash, Read
argument-hint: "[--all]"
---

# Smart Status

SMART-Health pro Disk mit Verdict. Verifiziert gegen DSM 7.3.1 mit smartctl 6.5 (Text-Format).

## Argument parsing

```bash
set -euo pipefail
ALL=0
for arg in ${ARGUMENTS:-}; do
  case "$arg" in
    --all) ALL=1 ;;
    "") ;;
    *) echo "Usage: /smart-status [--all]" >&2; exit 1 ;;
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
  "${SSH[@]}" "sudo -n true 2>/dev/null" || {
    echo "  ERROR: /smart-status needs passwordless sudo for smartctl." >&2
    echo "  Fix (DSM has no visudo, use sudoers.d drop-in):" >&2
    echo "    echo '$NAS_USER ALL=(ALL) NOPASSWD: /usr/bin/smartctl, /usr/syno/sbin/synoupgrade' | sudo tee /etc/sudoers.d/synology-manager-plus" >&2
    echo "    sudo chmod 0440 /etc/sudoers.d/synology-manager-plus" >&2
    return 1
  }

  DISKS=$("${SSH[@]}" "sudo -n /usr/bin/smartctl --scan 2>&1" | awk '/^\/dev\/sd[a-z]/ {print $1}')
  [ -z "$DISKS" ] && { echo "  ERROR: smartctl --scan returned no disks" >&2; return 1; }

  WORST_VERDICT="pass"
  echo "SMART Status ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
  echo "==============================================="

  for DEV in $DISKS; do
    OUT=$("${SSH[@]}" "sudo -n /usr/bin/smartctl -d $DEV_TYPE -a $DEV 2>&1")
    if [ -z "$OUT" ]; then
      echo ""; echo "Disk $DEV — ERROR: smartctl returned no output"; WORST_VERDICT="critical"; continue
    fi
    MODEL=$(echo "$OUT" | awk -F: '/^Device Model:/ {sub(/^ +/,"",$2); print $2; exit}')
    SERIAL=$(echo "$OUT" | awk -F: '/^Serial Number:/ {sub(/^ +/,"",$2); print $2; exit}')
    if echo "$OUT" | grep -q "SMART overall-health self-assessment test result: PASSED"; then PASSED=true
    elif echo "$OUT" | grep -q "SMART overall-health self-assessment test result: FAILED"; then PASSED=false
    else PASSED=unknown; fi
    attr_raw() { echo "$OUT" | awk -v id="$1" '$1==id {print $NF; exit}'; }
    REALLOC=$(attr_raw 5); PENDING=$(attr_raw 197); TEMP=$(attr_raw 194); HOURS=$(attr_raw 9)
    if [ "$PASSED" = "unknown" ] && [ -z "$REALLOC" ] && [ -z "$TEMP" ]; then
      echo ""; echo "Disk $DEV — ERROR: smartctl output unexpected"
      echo "  Hint: try 'smartctl_device_type: sat' in context/nas/$SLUG/profile.md (current: $DEV_TYPE)"
      WORST_VERDICT="critical"; continue
    fi
    REALLOC="${REALLOC:-0}"; PENDING="${PENDING:-0}"; TEMP="${TEMP:-0}"; HOURS="${HOURS:-0}"
    VERDICT="pass"; REASON=""
    if [ "$PASSED" = "false" ]; then VERDICT="critical"; REASON="SMART overall-health FAILED"
    elif [ "$REALLOC" -gt 100 ] 2>/dev/null; then VERDICT="critical"; REASON="Reallocated sectors $REALLOC > 100"
    elif [ "$PENDING" -gt 0 ] 2>/dev/null; then VERDICT="critical"; REASON="Pending sectors $PENDING > 0"
    elif [ "$TEMP" -gt 55 ] 2>/dev/null; then VERDICT="critical"; REASON="Temperature ${TEMP}C > 55"
    elif [ "$PASSED" = "unknown" ]; then VERDICT="warn"; REASON="SMART health-statement absent"
    elif [ "$REALLOC" -gt 0 ] 2>/dev/null && [ "$REALLOC" -le 100 ] 2>/dev/null; then VERDICT="warn"; REASON="${REALLOC} reallocated sectors — monitor"
    elif [ "$TEMP" -gt 45 ] 2>/dev/null; then VERDICT="warn"; REASON="Temperature ${TEMP}C > 45"
    fi
    echo ""; echo "Disk $DEV — ${MODEL:-unknown} (${SERIAL:-unknown})"
    echo "  Health:      ${PASSED}"; echo "  Temperature: ${TEMP}C"; echo "  Power-On:    ${HOURS}h"
    echo "  Reallocated: ${REALLOC}"; echo "  Pending:     ${PENDING}"
    if [ -n "$REASON" ]; then echo "  Verdict:     ${VERDICT}  ($REASON)"; else echo "  Verdict:     ${VERDICT}"; fi
    case "$VERDICT" in
      critical) WORST_VERDICT="critical" ;;
      warn) [ "$WORST_VERDICT" = "pass" ] && WORST_VERDICT="warn" ;;
    esac
  done
  echo ""; echo "Overall: ${WORST_VERDICT}"
  OVERALL="$WORST_VERDICT"
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
