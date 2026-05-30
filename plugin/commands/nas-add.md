---
description: Add an additional Synology NAS profile with its own SSH key, discover its hardware, and optionally make it active.
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---

# NAS Add

Add a second (or further) NAS. Each NAS gets its own SSH key and profile under `context/nas/<slug>/`.

## 1. Slug + connection (interactive)

Ask via `AskUserQuestion`, one at a time, storing answers in `SLUG`, `HOST`, `WAN_HOST`, `PORT`, `NAS_USER`:

- "Short name (slug) for this NAS? (lowercase letters/digits/dashes, e.g. `backup`)"
- "LAN host or IP?"  •  "WAN host (optional, blank to skip)?"  •  "SSH port? (default 22)"  •  "SSH username?"

Validate (reject + re-ask on failure):

```bash
set -euo pipefail
[[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo "Invalid slug: $SLUG (lowercase letters/digits/dashes)" >&2; exit 1; }
[ ! -e "context/nas/$SLUG" ] || { echo "NAS '$SLUG' already exists — use /nas-use $SLUG, or pick another slug." >&2; exit 1; }
[[ "$HOST" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo "Invalid host: $HOST" >&2; exit 1; }
PORT="${PORT:-22}"
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { echo "Invalid port: $PORT" >&2; exit 1; }
[[ "$NAS_USER" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "Invalid user: $NAS_USER" >&2; exit 1; }
KEY="$HOME/.ssh/synology-manager-plus_${SLUG}_ed25519"
```

## 2. Ensure the per-NAS SSH key

```bash
if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -N "" -f "$KEY" -C "synology-manager-plus@$SLUG"
fi
```

Existing keys are never overwritten. Present the copy-paste deployment instruction (Anti-Pattern Rule: NEVER auto-run ssh-copy-id):

> **Bitte tippe den folgenden Befehl WÖRTLICH inklusive Ausrufezeichen am Anfang:**
>
> `! ssh-copy-id -p <port> -i ~/.ssh/synology-manager-plus_<slug>_ed25519.pub <user>@<host>`

After the user confirms (`AskUserQuestion`: "ssh-copy-id durchgelaufen, weiter?"), re-verify with a BatchMode test using `$KEY`:

```bash
ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout="${CONNECT_TIMEOUT:-10}" -p "$PORT" "$NAS_USER@$HOST" "echo OK"
```

On failure, print these three common causes and stop:

> 1. SSH service not enabled in DSM (Control Panel → Terminal & SNMP → Enable SSH).
> 2. Wrong port — check DSM SSH settings.
> 3. User does not exist on NAS or has no shell access.

## 3. Discover hardware/software

```bash
set -euo pipefail
SSH=(
  ssh
  -i "$KEY"
  -o ConnectTimeout=10
  -p "$PORT"
  "$NAS_USER@$HOST"
)

discover() {
  local label="$1"; shift
  local result errfile
  errfile=$(mktemp)
  if ! result=$("${SSH[@]}" "$@" 2>"$errfile"); then
    echo "FAIL: discovery step '$label' failed. Remote stderr:" >&2
    cat "$errfile" >&2; rm -f "$errfile"; exit 1
  fi
  rm -f "$errfile"
  if [ -z "$result" ] && [ "$label" != "raid" ]; then
    echo "FAIL: discovery step '$label' returned empty — profile not written" >&2; exit 1
  fi
  printf '%s' "$result"
}

DSM_VERSION=$(discover dsm "cat /etc/VERSION" | tr -d '\r')
HOSTNAME_VAL=$(discover hostname "cat /proc/sys/kernel/hostname")
ARCH=$(discover arch "uname -m")
CPU=$(discover cpu "cat /proc/cpuinfo | grep -m1 'model name' | cut -d: -f2 | xargs")
RAM=$(discover ram "free -h | awk '/^Mem:/ {print \$2}'")
MODEL=$(discover model "grep -E 'upnpmodelname' /etc/synoinfo.conf | head -1 | cut -d= -f2 | tr -d '\"'")
DF_OUTPUT=$(discover df "df -h")
RAID_STATUS=$(discover raid "cat /proc/mdstat | head -20 2>/dev/null || echo 'n/a'")
VOL1_LIST=$(discover vol1 "ls /volume1/")
DOCKER_OK=$(discover docker "[ -x /usr/local/bin/docker ] && /usr/local/bin/docker --version || echo 'not installed'")
SUDO_OK=$(discover sudo "sudo -n true 2>/dev/null && echo yes || echo no")

for var in DSM_VERSION HOSTNAME_VAL ARCH MODEL VOL1_LIST; do
  if [ -z "${!var}" ]; then
    echo "FAIL: required discovery field $var is empty — profile not written" >&2; exit 1
  fi
done
```

## 4. Write the per-NAS profile (atomic)

```bash
mkdir -p "context/nas/$SLUG/volumes" "context/nas/$SLUG/mounts"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
prof_tmp=$(mktemp)
cat > "$prof_tmp" <<EOF
# Synology NAS Profile

_Populated by /nas-add on ${TS}._

## Connection
- host: $HOST
- wan_host: ${WAN_HOST:-}
- port: $PORT
- user: $NAS_USER
- key_path: ~/.ssh/synology-manager-plus_${SLUG}_ed25519
- connect_timeout_seconds: 10

## Hardware
- model: $MODEL
- arch: $ARCH
- cpu: $CPU
- ram: $RAM

## Software
- dsm_version: $DSM_VERSION
- hostname: $HOSTNAME_VAL
- docker_available: $DOCKER_OK
- sudo_passwordless: $SUDO_OK
- critical_compose_projects:

## Last Updated
${TS}
EOF
mv "$prof_tmp" "context/nas/$SLUG/profile.md"

# Volumes + mounts snapshots
{ echo "# ${TS}"; "${SSH[@]}" "ls -la /volume1/"; } > "context/nas/$SLUG/volumes/volume1-snapshot.txt" 2>/dev/null || true
{ echo "# ${TS}"; mount | grep -F "$HOST" || echo "no mounts"; } > "context/nas/$SLUG/mounts/current.txt"
```

(For full fidelity with `/first-run`, the implementer may also append the `## Volumes`/`## RAID`/`## Shared Folders` fenced blocks using `$DF_OUTPUT`/`$RAID_STATUS`/`$VOL1_LIST`; they are optional — `render_claude_md` does not read them.)

## 5. Activate?

Ask via `AskUserQuestion`: "Set '<slug>' as the active NAS now? (Yes / No)". If **Yes**:

```bash
tmp=$(mktemp); printf '%s\n' "$SLUG" > "$tmp" && mv "$tmp" context/active-nas
render_claude_md() {
  # $1 = active slug ; profile at context/nas/$1/profile.md ; CLAUDE.md in CWD
  local slug="$1" p="context/nas/$1/profile.md" start end sc ec
  [ -f CLAUDE.md ] || { echo "CLAUDE.md missing — run /first-run" >&2; return 1; }
  start='<!-- synology-manager-plus:managed-start -->'
  end='<!-- synology-manager-plus:managed-end -->'
  sc=$(grep -cF "$start" CLAUDE.md || true)
  ec=$(grep -cF "$end" CLAUDE.md || true)
  if [ "$sc" != "1" ] || [ "$ec" != "1" ]; then
    echo "CLAUDE.md has malformed managed markers (start: $sc, end: $ec) — fix manually." >&2
    return 1
  fi
  local host wan port user dsm model timeout docker sudo crit key
  host=$(awk '/^- host:/ {print $3; exit}' "$p")
  wan=$(awk -F': ' '/^- wan_host:/ {print $2; exit}' "$p"); wan="${wan:-—}"
  port=$(awk '/^- port:/ {print $3; exit}' "$p")
  user=$(awk '/^- user:/ {print $3; exit}' "$p")
  timeout=$(awk '/^- connect_timeout_seconds:/ {print $3; exit}' "$p"); timeout="${timeout:-10}"
  model=$(awk -F': ' '/^- model:/ {print $2; exit}' "$p"); model="${model:-?}"
  dsm=$(awk -F': ' '/^- dsm_version:/ {print $2; exit}' "$p"); dsm="${dsm:-?}"
  docker=$(awk -F': ' '/^- docker_available:/ {print $2; exit}' "$p"); docker="${docker:-?}"
  sudo=$(awk -F': ' '/^- sudo_passwordless:/ {print $2; exit}' "$p"); sudo="${sudo:-?}"
  crit=$(awk -F': ' '/^- critical_compose_projects:/ {print $2; exit}' "$p"); crit="${crit:-—}"
  key=$(awk '/^- key_path:/ {print $3; exit}' "$p"); key="${key:-~/.ssh/synology-manager-plus_${slug}_ed25519}"
  local qr scoped tmp2
  qr=$(cat <<EOF
$start

**Active NAS:** \`$slug\`  (see \`/nas-list\` for all configured NAS)

## Quick Reference

| Field | Value |
| - | - |
| NAS Host (LAN) | $host |
| NAS Host (WAN) | $wan |
| SSH Port | $port |
| SSH User | $user |
| SSH Key | \`$key\` |
| Connect Timeout | ${timeout}s |
| Model | $model |
| DSM Version | $dsm |
| Docker Available | $docker |
| Sudo (passwordless) | $sudo |
| Critical Compose Projects | $crit |
EOF
)
  scoped=$(awk -v s="## Scoped Operations" -v e="$end" '
    $0 ~ s {cap=1}
    cap && index($0,e)==0 {print}
    index($0,e)>0 {exit}
  ' CLAUDE.md)
  tmp2=$(mktemp)
  awk -v start="$start" -v end="$end" -v qr="$qr" -v scoped="$scoped" '
    index($0,start)>0 { print qr; print ""; print scoped; print end; inblk=1; next }
    index($0,end)>0 { inblk=0; next }
    !inblk { print }
  ' CLAUDE.md > "$tmp2" && mv "$tmp2" CLAUDE.md
}
render_claude_md "$SLUG" || echo "(warning) NAS added and set active, but CLAUDE.md was not re-rendered — see message above." >&2
```

If **No**, leave the active NAS unchanged.

## 6. Summary

Print: "Added NAS '<slug>' (<host>, DSM <dsm_version>, model <model>). Active NAS: <active-slug>. Run /nas-list to see all."
