---
description: Filtered log viewer for DSM system, ssh, package, and docker logs. Supports source/timeframe/grep filters and error-only severity default.
argument-hint: "[--source=system|ssh|package|docker] [--last=1h|24h|7d] [--grep=PATTERN] [--all-levels]"
allowed-tools: Bash, Read
---

# Logs

Gefilterter Log-Viewer.

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

## Argument parsing

```bash
source="system"
last="24h"
grep_pattern=""
all_levels=0

# Default-Expansion ${VAR:-} ist essentiell unter set -u —
# ohne Default würde ein bare /logs (kein Argument) hier mit
# "ARGUMENTS: unbound variable" abbrechen, bevor die Defaults
# greifen können.
for arg in ${ARGUMENTS:-}; do
  case "$arg" in
    --source=*)     source="${arg#*=}" ;;
    --last=*)       last="${arg#*=}" ;;
    --grep=*)       grep_pattern="${arg#*=}" ;;
    --all-levels)   all_levels=1 ;;
    "")             ;;
    *)              echo "Unknown argument: $arg" >&2
                    echo "Usage: /logs [--source=system|ssh|package|docker] [--last=Nh|Nd] [--grep=PATTERN] [--all-levels]" >&2
                    exit 1 ;;
  esac
done

case "$source" in
  system|ssh|package|docker) ;;
  *) echo "Invalid --source: $source" >&2; exit 1 ;;
esac

[[ "$last" =~ ^[0-9]+[hd]$ ]] || { echo "Invalid --last: $last" >&2; exit 1; }
```

## Query

```bash
SSH=( ssh -i "$HOME/.ssh/synology-manager-plus_ed25519" -o ConnectTimeout="$CONNECT_TIMEOUT" -p "$PORT" "$NAS_USER@$HOST" )

case "$source" in
  system)
    RAW=$("${SSH[@]}" "tail -n 1000 /var/log/messages /var/log/synolog/synolog.cur 2>/dev/null" || echo "")
    ;;
  ssh)
    RAW=$("${SSH[@]}" "test -f /var/log/auth.log && tail -n 500 /var/log/auth.log || journalctl -u sshd --no-pager 2>/dev/null | tail -500 || echo 'no auth.log or journal'" 2>/dev/null || echo "no auth.log or journal")
    ;;
  package)
    RAW=$("${SSH[@]}" "tail -n 500 /var/log/synopkg.log 2>/dev/null" || echo "")
    ;;
  docker)
    CONTAINERS=$("${SSH[@]}" "docker ps --format '{{.Names}}' 2>/dev/null | head -10" || echo "")
    if [ -z "$CONTAINERS" ]; then
      echo "No running docker containers (or docker not accessible — check group membership)" >&2
      exit 0
    fi
    RAW=""
    for c in $CONTAINERS; do
      RAW+="=== $c ==="$'\n'
      RAW+=$("${SSH[@]}" "docker logs --tail 100 $c 2>&1 | tail -100" 2>/dev/null || echo "(failed)")
      RAW+=$'\n'
    done
    ;;
esac

[ -z "$RAW" ] && { echo "(no log lines found)"; exit 0; }

if [ "$all_levels" -eq 0 ]; then
  RAW=$(echo "$RAW" | grep -iE 'error|warn|critical|fail' || echo "(no error/warning lines)")
fi

if [ -n "$grep_pattern" ]; then
  RAW=$(echo "$RAW" | grep -E "$grep_pattern" || echo "(no matches)")
fi

echo "$RAW" | head -100
TOTAL=$(echo "$RAW" | wc -l)
if [ "$TOTAL" -gt 100 ]; then
  echo ""
  echo "... ($((TOTAL - 100)) more lines truncated)"
fi
```
