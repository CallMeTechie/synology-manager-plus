---
description: First-time setup wizard. Gathers NAS details interactively, ensures SSH key auth, discovers hardware, and populates all context files. No sub-agent.
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---

# First Run — Interactive Setup

This command runs entirely in the main agent context. It does NOT delegate to a sub-agent (the previous `synology-intake` pattern was broken: sub-agents cannot maintain a multi-turn dialog with the user).

## Steps

### 1. Greet and explain

Print: "Setting up your Synology NAS workspace. I'll ask a few questions, deploy an SSH key, discover your NAS, and populate the context files. Takes about 2 minutes."

### 2. Detect existing config

Read `context/nas-profile.md`. If the file shows real values (not `_not configured_`), ask via `AskUserQuestion`:

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
DOCKER_OK=$(discover docker "command -v docker >/dev/null && docker --version || echo 'not installed'")
SUDO_OK=$(discover sudo "sudo -n true 2>/dev/null && echo yes || echo no")
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

#### `context/nas-profile.md` (atomic write)

Plugin-owned, no user content. Write to a temp file first, then `mv` — so a
crash mid-write never leaves a half-populated profile that future commands
would parse and act on.

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

## Volumes
<DF_OUTPUT in fenced block>

## RAID
<RAID_STATUS in fenced block>

## Shared Folders (volume1)
<VOL1_LIST in fenced block>

## Last Updated
<ISO 8601 UTC>
```

#### `context/volumes/volume1-snapshot.txt`

Append `<ISO 8601 UTC>` header + ssh `ls -la /volume1/` output.

#### `context/mounts/current.txt`

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

4. Replace the content **between** the markers with the new Quick Reference table (populated values) and the Scoped Operations checklist (`[x]` for selected, `[ ]` for not selected). The awk script must reset `in_block=0` at start (`BEGIN { in_block=0 }`) for idempotent re-runs.

5. Content **after** the managed-end marker is left untouched.

6. Write the result atomically (`tmp + mv`) so a crash during write never leaves CLAUDE.md half-rewritten.

### 8. Summary

Print:

> "Setup complete. Profile: `<host>:<port>` as `<user>`, DSM `<DSM_VERSION>`, model `<MODEL>`. Run `/diag` to verify overall health."
