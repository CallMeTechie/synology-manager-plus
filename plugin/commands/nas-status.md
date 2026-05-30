---
description: Query the NAS for current disk usage, RAID status, services, and load. Refreshes context/nas/$SLUG/storage-report.md. Add `--all` for a fleet sweep.
allowed-tools: Bash, Read, Write
argument-hint: "[--all]"
---

# NAS Status

## Argument parsing

```bash
set -euo pipefail
ALL=0
for arg in ${ARGUMENTS:-}; do
  case "$arg" in
    --all) ALL=1 ;;
    "") ;;
    *) echo "Usage: /nas-status [--all]" >&2; exit 1 ;;
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
  echo "# df -h"
  "${SSH[@]}" "df -h"
  echo "# RAID (/proc/mdstat)"
  "${SSH[@]}" "cat /proc/mdstat 2>/dev/null || echo 'mdstat not available'"
  echo "# Services (top 40)"
  "${SSH[@]}" "sudo -n /usr/syno/sbin/synoservice --list 2>/dev/null || /usr/syno/sbin/synoservice --list 2>/dev/null || echo 'synoservice not available'" | head -40
  echo "# Load + memory"
  "${SSH[@]}" "uptime && free -h"
  return 0
}
```

## Run

Display the results clearly to the user. After each successful `run_body`, update `context/nas/$SLUG/storage-report.md` with:

- A header timestamp (`_Last refresh: <ISO 8601 UTC>_`).
- The `df -h` output in a fenced code block.
- The RAID summary (one line if healthy, otherwise the full mdstat).
- The load and memory snapshot.

This applies per surveyed NAS in `--all` mode, or to the active NAS when no flag is given.

```bash
SURVEYED=0
for slug in "${SLUGS[@]}"; do
  [ "$ALL" -eq 1 ] && { echo ""; echo "──────── $slug ────────"; }
  if ! load_nas "$slug"; then [ "$ALL" -eq 1 ] || exit 1; continue; fi
  if [ "$ALL" -eq 1 ]; then
    if ! timeout 6 ssh -i "$KEY_PATH" -o BatchMode=yes -o ConnectTimeout=3 -p "$PORT" "$NAS_USER@$HOST" true 2>/dev/null; then
      echo "  unreachable"; UNREACH=$((UNREACH+1)); continue
    fi
  fi
  run_body || { [ "$ALL" -eq 1 ] || exit 1; continue; }
  SURVEYED=$((SURVEYED+1))
done
# Use `if ... fi`, NOT `&& { ... }`: a false `[ ]` as the script's last command
# would make a successful no-flag run exit 1.
if [ "$ALL" -eq 1 ]; then echo ""; echo "Surveyed $SURVEYED NAS (${UNREACH} unreachable)."; fi
```
