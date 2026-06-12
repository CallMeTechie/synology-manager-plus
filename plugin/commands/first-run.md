---
description: First-time setup wizard. Gathers NAS details interactively, ensures SSH key auth, discovers hardware, and populates all context files. No sub-agent.
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---

# First Run — Interactive Setup

This command runs entirely in the main agent context. It does NOT delegate to a sub-agent (the previous `synology-intake` pattern was broken: sub-agents cannot maintain a multi-turn dialog with the user).

## Steps

### 1. Greet and explain

Print: "Setting up your Synology NAS workspace. I'll ask a few questions, deploy an SSH key, discover your NAS, and populate the context files. Takes about 2 minutes."

### 0. Migrate legacy layout (one-time)

Run this block unconditionally at startup. It is a no-op when the workspace is already in the per-NAS layout or when no legacy profile exists.

```bash
set -euo pipefail
# One-time, resumable, lossless migration of the legacy flat layout.
smp_active=$(cat context/active-nas 2>/dev/null | head -1 || true)
smp_active="${smp_active%%[[:space:]]*}"
if ! { [[ "$smp_active" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] && [ -f "context/nas/$smp_active/profile.md" ]; } \
   && [ -f context/nas-profile.md ]; then
  smp_host=$(awk '/^- hostname:/ {print $3; exit}' context/nas-profile.md)
  [ "$smp_host" = "_not" ] && smp_host=""
  smp_slug=$(printf '%s' "$smp_host" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/^-+//; s/-+$//')
  smp_slug="${smp_slug:0:32}"; smp_slug=$(printf '%s' "$smp_slug" | sed -E 's/-+$//')
  [[ "$smp_slug" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || smp_slug="main"
  rm -rf context/.nas-migrate.tmp
  mkdir -p "context/.nas-migrate.tmp/$smp_slug"
  cp context/nas-profile.md "context/.nas-migrate.tmp/$smp_slug/profile.md"
  [ -f context/storage-report.md ] && cp context/storage-report.md "context/.nas-migrate.tmp/$smp_slug/storage-report.md"
  [ -d context/volumes ] && cp -r context/volumes "context/.nas-migrate.tmp/$smp_slug/volumes"
  [ -d context/mounts ] && cp -r context/mounts "context/.nas-migrate.tmp/$smp_slug/mounts"
  rm -rf -- "context/nas/${smp_slug:?slug empty}"
  mkdir -p context/nas
  mv "context/.nas-migrate.tmp/$smp_slug" "context/nas/$smp_slug"
  smp_tmp=$(mktemp); printf '%s\n' "$smp_slug" > "$smp_tmp" && mv "$smp_tmp" context/active-nas
  rm -f context/nas-profile.md context/storage-report.md
  rm -rf context/volumes context/mounts context/.nas-migrate.tmp
  echo "[migration] single-NAS workspace migrated to context/nas/$smp_slug/"
fi
```

### 2. Detect existing config

Read `context/active-nas` to get the active slug, then check `context/nas/<slug>/profile.md`. If the file shows real values (not `_not configured_`), ask via `AskUserQuestion`:

> "Profile already exists for `<host>:<port>` (user `<user>`). What now?"
>
> Options:
>
> - "Refresh — re-discover and overwrite managed sections"
> - "Cancel — keep current profile"

If "Cancel" → stop. If "Refresh" → continue.

### 3. Gather connection details

Use `AskUserQuestion` one at a time:

- "What is the LAN host or IP for the NAS?" (free text)
- "What is the WAN host (optional, leave blank to skip)?" (free text)
- "What is the SSH port? (Default 22)" (free text, blank → 22)
- "What is the SSH username?" (free text)

Validate each as in `/setup-ssh` step 1. Reject and re-ask on failure.

If both LAN and WAN are given, prefer LAN for the initial test. Store both in the profile.

### 4. Ensure SSH key auth

Run the same logic as `/setup-ssh` steps 2–6 (plugin-owned key generation, BatchMode test, copy-paste instruction with `!`-prefix, re-verification, profile update, completion print). On failure: stop and ask the user to fix and re-run `/first-run`.

### 5. Discover NAS hardware and software

`set -euo pipefail` at the top is required — `discover()`'s `exit 1` is consumed by surrounding pipes (`| tr -d '\r'`) without `pipefail`, which would silently produce empty values:

```bash
set -euo pipefail

SSH=(
  ssh
  -i "$HOME/.ssh/synology-manager-plus_ed25519"
  -o ConnectTimeout=10
  -p "$PORT"
  "$NAS_USER@$HOST"
)

# Helper: run discovery with explicit failure handling.
# A discovery failure mid-wizard must abort cleanly so we never write a
# half-empty profile. stderr is captured and surfaced — a generic "SSH
# dropped" message is wrong 4 times out of 5 (most failures are auth,
# command-not-found on NAS, or permission denied), so we show the real
# diagnostic from sshd / the remote shell.
discover() {
  local label="$1"; shift
  local result errfile
  errfile=$(mktemp)
  if ! result=$("${SSH[@]}" "$@" 2>"$errfile"); then
    echo "FAIL: discovery step '$label' failed. Remote stderr:" >&2
    cat "$errfile" >&2
    rm -f "$errfile"
    exit 1
  fi
  rm -f "$errfile"
  # Required fields must not be empty — a successful SSH that returns
  # nothing means the remote command produced no output, which is a
  # different failure mode and equally fatal for profile correctness.
  if [ -z "$result" ] && [ "$label" != "raid" ]; then
    echo "FAIL: discovery step '$label' returned empty — profile not written" >&2
    exit 1
  fi
  printf '%s' "$result"
}
```

Run discovery and capture each output:

Discovery commands intentionally do NOT swallow stderr at the SSH-payload
level — `discover()` captures and surfaces it. Inner pipelines that
legitimately tolerate "missing on this box" (RAID, Docker, sudo) explicitly
say so via `|| echo`; everything else must succeed or the wizard aborts.

```bash
DSM_VERSION=$(discover dsm "cat /etc/VERSION" | tr -d '\r')
HOSTNAME_VAL=$(discover hostname "cat /proc/sys/kernel/hostname")
ARCH=$(discover arch "uname -m")
CPU=$(discover cpu "cat /proc/cpuinfo | grep -m1 'model name' | cut -d: -f2 | xargs")
RAM=$(discover ram "free -h | awk '/^Mem:/ {print \$2}'")
MODEL=$(discover model "grep -E 'upnpmodelname' /etc/synoinfo.conf | head -1 | cut -d= -f2 | tr -d '\"'")
DF_OUTPUT=$(discover df "df -h")
# RAID is the one optional field — non-Synology DSM-likes won't have mdstat,
# and discover() exempts label 'raid' from the empty-result check.
RAID_STATUS=$(discover raid "cat /proc/mdstat | head -20 2>/dev/null || echo 'n/a'")
VOL1_LIST=$(discover vol1 "ls /volume1/")
# DSM installs docker at /usr/local/bin/docker, which is NOT on the PATH of a
# non-interactive SSH session (/etc/profile is not sourced). Probing the
# absolute path — not `command -v docker` — is the only reliable detection;
# all /compose-* commands use the same absolute path.
DOCKER_OK=$(discover docker "[ -x /usr/local/bin/docker ] && /usr/local/bin/docker --version || echo 'not installed'")
HOME_PATH=$(discover home "echo \$HOME")
if [ "$DOCKER_OK" = "not installed" ]; then
  SUDO_OK="n/a"
else
  SUDO_OK=$(discover sudo "sudo -n /usr/local/bin/docker info >/dev/null 2>&1 && echo yes || echo no")
fi
```

Validate the must-have fields explicitly — `discover()` already aborts on
empty for non-RAID, but a human-readable second pass before profile write
makes the failure mode obvious in the wizard output:

```bash
for var in DSM_VERSION HOSTNAME_VAL ARCH MODEL VOL1_LIST; do
  if [ -z "${!var}" ]; then
    echo "FAIL: required discovery field $var is empty — profile not written" >&2
    exit 1
  fi
done
```

### 6. Ask about scoped operations

Use `AskUserQuestion` with `multiSelect: true`:

> "Which categories should the plugin be authorized to perform?"
>
> Options:
>
> - "Volume management"
> - "Mount configuration"
> - "File operations"
> - "Permission management"
> - "System monitoring"
> - "Backup operations"

### 7. Write context files (managed sections only)

#### Per-NAS profile write (atomic)

Derive `<slug>` from `HOSTNAME_VAL` using the same normalize+validate logic as Step 0 (fallback `main`). Create subdirs, write the profile atomically, then set `context/active-nas` atomically.

```bash
nas_slug=$(printf '%s' "$HOSTNAME_VAL" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/^-+//; s/-+$//')
nas_slug="${nas_slug:0:32}"; nas_slug=$(printf '%s' "$nas_slug" | sed -E 's/-+$//')
[[ "$nas_slug" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || nas_slug="main"
mkdir -p "context/nas/$nas_slug/volumes" "context/nas/$nas_slug/mounts"
```

Plugin-owned, no user content. Write `context/nas/<slug>/profile.md` to a temp file first, then `mv` — so a crash mid-write never leaves a half-populated profile that future commands would parse and act on.

```markdown
# Synology NAS Profile

_Populated by /first-run on <ISO 8601 UTC>._

## Connection
- host: <LAN-or-only-host>
- wan_host: <WAN-or-empty>
- port: <PORT>
- user: <NAS_USER>
- key_path: ~/.ssh/synology-manager-plus_ed25519
- connect_timeout_seconds: 10

## Hardware
- model: <MODEL>
- arch: <ARCH>
- cpu: <CPU>
- ram: <RAM>

## Software
- dsm_version: <DSM_VERSION>
- hostname: <HOSTNAME_VAL>
- docker_available: <DOCKER_OK>
- sudo_passwordless: <SUDO_OK>
- sudo_checked_at: <ISO 8601 UTC>

## Volumes
<DF_OUTPUT in fenced block>

## RAID
<RAID_STATUS in fenced block>

## Shared Folders (volume1)
<VOL1_LIST in fenced block>

## Last Updated
<ISO 8601 UTC>
```

After the atomic profile write, set `context/active-nas` to the slug atomically:

```bash
nas_tmp=$(mktemp); printf '%s\n' "$nas_slug" > "$nas_tmp" && mv "$nas_tmp" context/active-nas
```

#### `context/nas/<slug>/volumes/volume1-snapshot.txt`

Append `<ISO 8601 UTC>` header + ssh `ls -la /volume1/` output.

#### `context/nas/<slug>/mounts/current.txt`

Append `<ISO 8601 UTC>` header + local `mount | grep -F "$HOST" || echo "no mounts"` output.

#### `CLAUDE.md` (managed-section only)

1. Read `CLAUDE.md`.
2. Count the markers explicitly — a single asymmetric marker would silently delete user content if naively rewritten:

   ```bash
   START_COUNT=$(grep -c '<!-- synology-manager-plus:managed-start -->' CLAUDE.md || true)
   END_COUNT=$(grep -c '<!-- synology-manager-plus:managed-end -->' CLAUDE.md || true)
   ```

3. Decide based on the counts:
   - `START_COUNT == 1 && END_COUNT == 1` — happy path, proceed to step 4.
   - `START_COUNT == 0 && END_COUNT == 0` — fresh file (e.g. migrated from upstream). Show a diff of the proposed managed block and ask via `AskUserQuestion`: "Insert the managed section at the top of CLAUDE.md? (Yes / No / Show diff again)".
   - Any other combination (asymmetric markers, duplicates) — refuse to write. Print: "CLAUDE.md has malformed markers (start: $START_COUNT, end: $END_COUNT). Fix manually before re-running /first-run." Exit 1. This is the safety net that prevents the awk replacer from deleting everything after a lone start-marker.

4. Write the initial managed section atomically so that the `## Scoped Operations` block (with `[x]`/`[ ]` checkboxes from Step 6) exists between the markers before calling the renderer. This gives `render_claude_md` the Scoped Operations content it preserves via its `awk` extractor:

   ```bash
   _start='<!-- synology-manager-plus:managed-start -->'
   _end='<!-- synology-manager-plus:managed-end -->'
   _ops_block="## Scoped Operations

   Authorized categories (set during \`/first-run\`):

   - $([ "${SCOPE_VOLUME:-0}" = "1" ] && echo "[x]" || echo "[ ]") Volume management (create/delete shared folders)
   - $([ "${SCOPE_MOUNT:-0}" = "1" ] && echo "[x]" || echo "[ ]") Mount configuration (NFS/SAMBA)
   - $([ "${SCOPE_FILE:-0}" = "1" ] && echo "[x]" || echo "[ ]") File operations (copy, move, delete)
   - $([ "${SCOPE_PERM:-0}" = "1" ] && echo "[x]" || echo "[ ]") Permission management
   - $([ "${SCOPE_MON:-0}" = "1" ] && echo "[x]" || echo "[ ]") System monitoring
   - $([ "${SCOPE_BACKUP:-0}" = "1" ] && echo "[x]" || echo "[ ]") Backup operations"
   _tmp_seed=$(mktemp)
   awk -v start="$_start" -v end="$_end" -v ops="$_ops_block" '
     BEGIN { inblk=0 }
     index($0,start)>0 { print start; print ""; print ops; print ""; print end; inblk=1; next }
     index($0,end)>0 { inblk=0; next }
     !inblk { print }
   ' CLAUDE.md > "$_tmp_seed" && mv "$_tmp_seed" CLAUDE.md
   ```

5. Call `render_claude_md "$nas_slug"` (defined below) to overwrite the Quick Reference portion with the canonical active-NAS header and table, preserving the Scoped Operations block written in step 4. Content **after** the managed-end marker is left untouched (the awk pass skips it).

```bash
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
render_claude_md "$nas_slug"
```

### 8. Summary

Print:

> "Setup complete. Profile: `<host>:<port>` as `<user>`, DSM `<DSM_VERSION>`, model `<MODEL>`. Run `/diag` to verify overall health."
