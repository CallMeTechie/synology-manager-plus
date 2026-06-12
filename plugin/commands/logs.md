---
description: Filtered log viewer for DSM system, ssh, package, and docker logs. Supports source/timeframe/grep filters and error-only severity default.
argument-hint: "[--source=system|ssh|package|docker] [--last=1h|24h|7d] [--grep=PATTERN] [--all-levels]"
allowed-tools: Bash, Read
---

# Logs

Gefilterter Log-Viewer.

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
case "$source" in
  system)
    # /var/log/messages is root:log mode 660 on DSM; /var/log/synolog/* is
    # often root-only. We capture stderr so a permission denial surfaces
    # with a concrete remediation instead of an empty output.
    RAW=$("${SSH[@]}" "tail -n 1000 /var/log/messages /var/log/synolog/synolog.cur 2>&1" || echo "")
    if echo "$RAW" | grep -qi "permission denied"; then
      echo "ERROR: cannot read DSM system logs as user '$NAS_USER' — these files are root:log on DSM." >&2
      echo "Two options to enable /logs --source=system:" >&2
      echo "  (A) Add user to 'log' group (cleaner, no broad sudo grant):" >&2
      echo "      ssh $NAS_USER@$HOST 'sudo synogroup --member add log $NAS_USER'" >&2
      echo "      Log out / back in to refresh group membership." >&2
      echo "  (B) Extend plugin sudoers drop-in for tail (broader scope):" >&2
      echo "      echo '$NAS_USER ALL=(ALL) NOPASSWD: /usr/bin/tail' | sudo tee -a /etc/sudoers.d/synology-manager-plus" >&2
      exit 1
    fi
    ;;
  ssh)
    RAW=$("${SSH[@]}" "test -f /var/log/auth.log && tail -n 500 /var/log/auth.log || journalctl -u sshd --no-pager 2>/dev/null | tail -500 || echo 'no auth.log or journal'" 2>/dev/null || echo "no auth.log or journal")
    ;;
  package)
    RAW=$("${SSH[@]}" "tail -n 500 /var/log/synopkg.log 2>&1" || echo "")
    if echo "$RAW" | grep -qi "permission denied"; then
      echo "ERROR: cannot read /var/log/synopkg.log — same group/sudo options apply as --source=system." >&2
      exit 1
    fi
    ;;
  docker)
    # /usr/local/bin/docker is absolute: DSM's non-interactive SSH PATH omits
    # /usr/local/bin, so a bare `docker` would not resolve even when installed.
    CONTAINERS=$("${SSH[@]}" "/usr/local/bin/docker ps --format '{{.Names}}' 2>/dev/null | head -10" || echo "")
    if [ -z "$CONTAINERS" ]; then
      echo "No running docker containers (or docker not accessible — check group membership)" >&2
      exit 0
    fi
    RAW=""
    for c in $CONTAINERS; do
      RAW+="=== $c ==="$'\n'
      RAW+=$("${SSH[@]}" "/usr/local/bin/docker logs --tail 100 $c 2>&1 | tail -100" 2>/dev/null || echo "(failed)")
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
