---
description: Health check across SSH connectivity, key auth, profile completeness, sudo, and mount sanity. Read-only, no state changes.
allowed-tools: Bash, Read
---

# Diagnose

Run a 7-point health check. No file writes, no state mutation.

## Setup

`/diag` is read-only and must not exit early — it continues past failures so the user sees every check. Therefore the extraction here is gentler than in `/nas-status`: it sets variables to empty strings on missing data, and the per-check assertions below decide what's a `FAIL` versus `WARN` versus `OK`.

Use `NAS_USER`, NOT `$USER` — `$USER` is the local Linux login user.

This command intentionally does NOT use `set -e` — every check must run to completion so the user sees the full picture. Failures inside individual checks are caught with `if`/`||` patterns and emit a labelled `FAIL`/`WARN` line:

```bash
set -uo pipefail  # -e omitted on purpose; per-check error handling below

PROFILE="context/nas-profile.md"
HOST=""; PORT=""; NAS_USER=""; CONNECT_TIMEOUT=""

if [ -f "$PROFILE" ]; then
  HOST=$(awk '/^- host:/ {print $3; exit}' "$PROFILE")
  PORT=$(awk '/^- port:/ {print $3; exit}' "$PROFILE")
  NAS_USER=$(awk '/^- user:/ {print $3; exit}' "$PROFILE")
  CONNECT_TIMEOUT=$(awk '/^- connect_timeout_seconds:/ {print $3; exit}' "$PROFILE")
  # Treat placeholder values as empty so check 2 reports incomplete.
  for field in host port user; do
    if grep -qE "^- ${field}: _not configured_" "$PROFILE"; then
      case $field in
        host) HOST="" ;;
        port) PORT="" ;;
        user) NAS_USER="" ;;
      esac
    fi
  done
fi
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
```

## Checks

Each check prints `OK`, `WARN`, or `FAIL` followed by a one-line status. Continue past failures (do not short-circuit) so the user sees the full picture.

### 1. Profile present

```bash
[ -f context/nas-profile.md ] && echo "OK Profile present" || echo "FAIL Profile missing — run /first-run"
```

### 2. Profile complete

All three fields must be present (placeholders are normalised to empty in the extraction prelude above, so a single `-n` check covers both "missing" and "still placeholder").

```bash
if [ -n "$HOST" ] && [ -n "$PORT" ] && [ -n "$NAS_USER" ]; then
  echo "OK Profile complete (host: $HOST, port: $PORT, user: $NAS_USER)"
else
  missing=()
  [ -z "$HOST" ] && missing+=(host)
  [ -z "$PORT" ] && missing+=(port)
  [ -z "$NAS_USER" ] && missing+=(user)
  echo "FAIL Profile incomplete (missing: ${missing[*]}) — re-run /first-run"
fi
```

### 3. SSH reachable (TCP)

```bash
if nc -z -w3 "$HOST" "$PORT" 2>/dev/null; then
  echo "OK SSH reachable on $HOST:$PORT"
else
  echo "FAIL SSH unreachable — check host/port, NAS may be powered off"
fi
```

### 4. Key auth works (cold + warm retry)

```bash
KEY_AUTH_OK=0
SSH_ARGS=(
  -i "$HOME/.ssh/synology-manager-plus_ed25519"
  -o BatchMode=yes
  -o ConnectTimeout="${CONNECT_TIMEOUT:-10}"
  -p "$PORT"
  "$NAS_USER@$HOST"
)
if ssh "${SSH_ARGS[@]}" "echo ok" 2>/dev/null | grep -q "^ok$"; then
  echo "OK Key authentication works (cold)"
  KEY_AUTH_OK=1
elif sleep 2 && ssh "${SSH_ARGS[@]}" "echo ok" 2>/dev/null | grep -q "^ok$"; then
  echo "OK Key authentication works (warm — VPN wake-up absorbed)"
  KEY_AUTH_OK=1
else
  echo "FAIL Key auth failed — run /setup-ssh"
fi
```

(The `elif` is a real second attempt with a 2-second pause — covers VPN-tunnel wake-up latency that the first 10s connect-timeout might not absorb. SSH args go through an array so hostnames with hyphens or spaces don't word-split. `KEY_AUTH_OK` lets later checks skip cleanly so a dead NAS doesn't burn 30+ seconds in `/diag`.)

### 5. Sudo passwordless

Skipped if Check 4 already failed — without working key auth, this would hang for ConnectTimeout seconds and tell the user nothing new.

```bash
if [ "$KEY_AUTH_OK" -eq 1 ]; then
  if ssh "${SSH_ARGS[@]}" "sudo -n true 2>/dev/null"; then
    echo "OK Sudo available (passwordless)"
  else
    echo "WARN No passwordless sudo — operations needing root require manual password entry"
  fi
else
  echo "SKIP Sudo check (depends on Check 4)"
fi
```

### 6. Disk usage query

Same skip rule.

```bash
if [ "$KEY_AUTH_OK" -eq 1 ]; then
  if ssh "${SSH_ARGS[@]}" "df -h" >/dev/null 2>&1; then
    echo "OK Disk usage query OK"
  else
    echo "FAIL NAS reachable but df failed — unusual"
  fi
else
  echo "SKIP Disk usage check (depends on Check 4)"
fi
```

### 7. Local mounts sanity

`findmnt` is preferred over `stat` here — `stat` on a stale NFS mount can itself hang, defeating the purpose of a quick health check. `findmnt --target` returns immediately with a clear status.

```bash
MOUNTS=$(mount | grep -F "$HOST" || true)
if [ -z "$MOUNTS" ]; then
  echo "OK No local NAS mounts (or none configured)"
else
  STALE=0
  while read -r line; do
    MP=$(echo "$line" | awk '{print $3}')
    if ! timeout 3 findmnt --target "$MP" >/dev/null 2>&1; then
      echo "WARN Mount $MP is stale (run: sudo umount $MP)"
      STALE=$((STALE+1))
    fi
  done <<< "$MOUNTS"
  [ $STALE -eq 0 ] && echo "OK All local NAS mounts are healthy"
fi
```

## Summary

Print a final line: `<passed>/7 checks passed, <warnings> warnings, <failures> failures.`
