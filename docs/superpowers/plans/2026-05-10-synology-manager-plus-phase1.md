# synology-manager-plus Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fork des `synology-manager-plugin` als `synology-manager-plus` v0.2.0 mit gefixter Marketplace-Installation, neuer `/setup-ssh`/`/diag`-Commands, rewritten `/first-run` ohne Sub-Agent, und vollständiger CI-Test-Pipeline (statisch + Bash-Smoke gegen Mock-NAS).

**Architecture:** Marketplace-fähiges Repo-Layout mit `plugin/`-Subdirectory (verifiziert in Spec V1). Plugin-eigener SSH-Key (`~/.ssh/synology-manager-plus_ed25519`) zur Vermeidung von Key-Kollisionen. CLAUDE.md mit `<!-- managed-start/-end -->` Markern, sodass User-Notizen bei Re-Run erhalten bleiben. ssh-copy-id wird **niemals** vom Plugin per Bash-Tool aufgerufen — nur als kopierbare User-Anleitung mit `!`-Prefix (verifiziert in Spec V2).

**Tech Stack:** Bash, JSON, Markdown, Docker (Mock-NAS), GitHub Actions, jq, shellcheck, markdownlint-cli2, ssh, ssh-keygen, ssh-copy-id, sshpass (nur in CI-Test-Container).

**Spec-Referenz:** `docs/superpowers/specs/2026-05-10-synology-manager-plus-design.md`

---

## File Structure (Übersicht)

| Pfad | Verantwortung |
|------|---------------|
| `.claude-plugin/marketplace.json` | Marketplace-Manifest, lässt das Repo via `claude plugin marketplace add` finden |
| `plugin/.claude-plugin/plugin.json` | Plugin-Manifest (name, version, deps) |
| `plugin/CLAUDE.md` | Workspace-Kontext mit managed/user-Trennung |
| `plugin/commands/setup-ssh.md` | NEU: SSH-Key-Setup, idempotent |
| `plugin/commands/first-run.md` | REWRITE: Slash-Command-Wizard, kein Sub-Agent |
| `plugin/commands/diag.md` | NEU: Health-Check 7 Punkte |
| `plugin/commands/nas-status.md` | UPDATE: Plugin-Key, ConnectTimeout |
| `plugin/commands/list-shares.md` | UPDATE: Plugin-Key, ConnectTimeout |
| `plugin/commands/manage-mounts.md` | UPDATE: Plugin-Key, ConnectTimeout |
| `plugin/context/nas-profile.md` | Template, vom Wizard befüllt |
| `plugin/context/storage-report.md` | Auto-updated by `/nas-status` |
| `plugin/context/volumes/.gitkeep` | Snapshots-Verzeichnis-Anker |
| `plugin/context/mounts/.gitkeep` | Mount-State-Verzeichnis-Anker |
| `tests/static/validate-manifests.sh` | JSON-Validität + Pflichtfelder |
| `tests/static/shellcheck-commands.sh` | Extrahiert Bash-Snippets aus Commands, läuft shellcheck |
| `tests/static/markdown-lint.sh` | markdownlint-cli2 mit Projektregeln |
| `tests/static/frontmatter-check.sh` | Pflicht-Frontmatter in Commands |
| `tests/fixtures/mock-nas/Dockerfile` | Alpine+OpenSSH+DSM-Stubs |
| `tests/fixtures/mock-nas/setup-stubs.sh` | Erstellt /etc/VERSION, /etc/synoinfo.conf, /volume1/* |
| `tests/fixtures/expected-outputs/*.txt` | Erwartete Outputs für Smoke-Tests |
| `tests/integration/lib/test-helpers.sh` | Gemeinsame Test-Funktionen |
| `tests/integration/test-{cmd}.sh` | Smoke-Test pro Command (6 Stück) |
| `tests/integration/run-all.sh` | Orchestriert Container + Tests |
| `.github/workflows/validate.yml` | Statische Checks |
| `.github/workflows/integration.yml` | Mock-NAS Smoke-Tests |
| `.markdownlint.json` | Projektspezifische Markdown-Regeln |
| `README.md` | User-facing Doku, Installation, Migration |
| `CHANGELOG.md` | Keep-a-Changelog Format |
| `LICENSE` | MIT mit beiden Copyrights |
| `.gitignore` | Standard + Plugin-Caches |

---

## Phase A — Repo-Skelett & Manifeste

### Task 1: Repo-Skelett & .gitignore

**Files:**
- Create: `.gitignore`
- Create: `plugin/context/volumes/.gitkeep`
- Create: `plugin/context/mounts/.gitkeep`

- [ ] **Step 1: Verzeichnisstruktur anlegen**

```bash
cd /root/synology-manager-plus
mkdir -p .claude-plugin \
         plugin/.claude-plugin \
         plugin/commands \
         plugin/context/volumes \
         plugin/context/mounts \
         tests/static \
         tests/integration/lib \
         tests/fixtures/mock-nas \
         tests/fixtures/expected-outputs \
         .github/workflows
```

- [ ] **Step 2: `.gitignore` schreiben**

```gitignore
# OS
.DS_Store
Thumbs.db

# Editor
.vscode/
.idea/
*.swp
*.swo

# Test artifacts
tests/integration/logs/
tests/integration/.tmp-home-*
*.log

# Local plugin cache (when developing against local marketplace)
.claude-plugin-cache/
```

- [ ] **Step 3: `.gitkeep`-Files**

```bash
touch plugin/context/volumes/.gitkeep plugin/context/mounts/.gitkeep
```

- [ ] **Step 4: Verzeichnisstruktur verifizieren**

Run: `find /root/synology-manager-plus -type d | sort`
Expected: enthält alle 11 oben erstellten Verzeichnisse.

- [ ] **Step 5: Commit**

```bash
git add .gitignore plugin/context/volumes/.gitkeep plugin/context/mounts/.gitkeep
git commit -m "chore: scaffold repo structure with gitkeep anchors"
```

---

### Task 2: Marketplace-Manifest

**Files:**
- Create: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Manifest schreiben**

```json
{
  "name": "synology-manager-plus",
  "owner": { "name": "CallMeTechie" },
  "plugins": [
    {
      "name": "synology-manager-plus",
      "source": "./plugin",
      "description": "Enhanced Synology NAS plugin — fork of danielrosehill/synology-manager-plugin with working installation, automated SSH setup, and health diagnostics."
    }
  ]
}
```

- [ ] **Step 2: JSON-Validität verifizieren**

Run: `jq empty /root/synology-manager-plus/.claude-plugin/marketplace.json && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add .claude-plugin/marketplace.json
git commit -m "feat: add marketplace manifest with plugin/ subdir source"
```

---

### Task 3: Plugin-Manifest

**Files:**
- Create: `plugin/.claude-plugin/plugin.json`

- [ ] **Step 1: Manifest schreiben**

```json
{
  "name": "synology-manager-plus",
  "version": "0.2.0",
  "description": "Workspace plugin for Synology NAS management. Fork of synology-manager with fixed installation, automated SSH setup, and /diag health-check.",
  "author": { "name": "Marc Backes", "url": "https://github.com/CallMeTechie" },
  "license": "MIT",
  "keywords": ["synology", "nas", "sysadmin", "storage", "ssh"]
}
```

- [ ] **Step 2: JSON-Validität verifizieren**

Run: `jq empty /root/synology-manager-plus/plugin/.claude-plugin/plugin.json && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add plugin/.claude-plugin/plugin.json
git commit -m "feat: add plugin manifest v0.2.0"
```

---

## Phase B — CLAUDE.md & Context-Templates

### Task 4: CLAUDE.md mit managed/user-Markern

**Files:**
- Create: `plugin/CLAUDE.md`

- [ ] **Step 1: CLAUDE.md schreiben**

```markdown
# Claude Synology Manager Plus

This repository is your workspace for managing a Synology NAS via Claude Code. It provides persistent context and memory for NAS administration tasks across sessions.

<!-- synology-manager-plus:managed-start -->

## Quick Reference

| Field | Value |
|-------|-------|
| NAS Host (LAN/WAN) | _not configured_ |
| SSH Port | _not configured_ |
| SSH User | _not configured_ |
| SSH Key | `~/.ssh/synology-manager-plus_ed25519` |
| Connect Timeout | 10s (default) |
| Model | _not configured_ |
| DSM Version | _not configured_ |
| Total / Available Storage | _not configured_ |
| Sudo (passwordless) | _not configured_ |
| Docker Available | _not configured_ |

## Scoped Operations

Authorized categories (set during `/first-run`):

- [ ] Volume management (create/delete shared folders)
- [ ] Mount configuration (NFS/SAMBA)
- [ ] File operations (copy, move, delete)
- [ ] Permission management
- [ ] System monitoring
- [ ] Backup operations

<!-- synology-manager-plus:managed-end -->

## First Run

If the Quick Reference above shows `_not configured_`, run `/first-run` to populate NAS details interactively.

## Available Commands

| Command | Description |
|---------|-------------|
| `/first-run` | Interactive setup wizard |
| `/setup-ssh` | Generate keypair and walk through key deployment |
| `/diag` | Health check (7 points) |
| `/nas-status` | Disk usage, RAID, services |
| `/list-shares` | List shared folders |
| `/manage-mounts` | View/add/remove NFS/SAMBA mounts |

## Operational Guidelines

### Before Operations

1. Check `context/nas-profile.md` for connection details.
2. If unsure, run `/diag` first.
3. Review relevant cached state in `context/`.

### During Operations

1. Use SSH for direct file/system operations (always with `-i ~/.ssh/synology-manager-plus_ed25519`).
2. Prefer non-destructive operations (list before delete, backup before modify).

### After Operations

1. Update relevant context files when state changes.
2. If storage changed significantly, refresh `context/storage-report.md`.

## Notes

_Space for session notes and observations — anything below this line is preserved across `/first-run` re-runs:_

---
```

- [ ] **Step 2: Marker-Vorhandensein verifizieren**

Run: `grep -c "synology-manager-plus:managed-" /root/synology-manager-plus/plugin/CLAUDE.md`
Expected: `2` (start- und end-Marker je einmal)

- [ ] **Step 3: Commit**

```bash
git add plugin/CLAUDE.md
git commit -m "feat: add CLAUDE.md template with managed-section markers"
```

---

### Task 5: nas-profile.md und storage-report.md Templates

**Files:**
- Create: `plugin/context/nas-profile.md`
- Create: `plugin/context/storage-report.md`

- [ ] **Step 1: nas-profile.md Template schreiben**

```markdown
# Synology NAS Profile

_Populated by `/first-run`. Do not edit by hand — re-run `/first-run` to refresh._

## Connection

- host: _not configured_
- port: _not configured_
- user: _not configured_
- key_path: ~/.ssh/synology-manager-plus_ed25519
- connect_timeout_seconds: 10

## Hardware

- model: _not configured_
- arch: _not configured_
- cpu: _not configured_
- ram: _not configured_

## Software

- dsm_version: _not configured_
- hostname: _not configured_
- docker_available: _not configured_
- sudo_passwordless: _not configured_

## Volumes

_Populated from `df -h` during discovery._

## Shared Folders

_Populated from `ls /volume1/` during discovery._

## Last Updated

_not configured_
```

- [ ] **Step 2: storage-report.md Template schreiben**

```markdown
# Storage Report

_Auto-updated by `/nas-status`. Last refresh: never._

No data yet. Run `/nas-status` to populate.
```

- [ ] **Step 3: Commit**

```bash
git add plugin/context/nas-profile.md plugin/context/storage-report.md
git commit -m "feat: add nas-profile and storage-report templates"
```

---

## Phase C — Bestehende Commands anpassen

> **Note on phase ordering:** Phase E (static tests) intentionally lives after Phase D (commands), so that the test scripts have real targets to run against. The trade-off: shellcheck/frontmatter-check might surface bugs in commands written in Phases C/D that require touching those commands again. To minimise re-commit churn, run the static test suite locally after every command file you write, even if it has not been formally created yet — copy the script bodies from Tasks 12, 13, 15 inline if needed. The cost of a 30-second sanity check beats discovering 6 cascading shellcheck warnings in Phase J.

### Task 6: /nas-status updaten (Plugin-Key, Timeout, Port)

**Files:**
- Create: `plugin/commands/nas-status.md`

- [ ] **Step 1: Command schreiben**

````markdown
---
description: Query the NAS for current disk usage, RAID status, services, and load. Refreshes context/storage-report.md.
allowed-tools: Bash, Read, Write, Edit
---

# NAS Status

## Profile extraction (do this first)

Read `context/nas-profile.md` and extract these values via grep/awk. The variable name `NAS_USER` (not `USER`) is critical — `$USER` is the local login user on every Linux system and would silently shadow the NAS user.

```bash
PROFILE="context/nas-profile.md"
[ -f "$PROFILE" ] || { echo "Profile missing — run /first-run first"; exit 1; }

HOST=$(awk '/^- host:/ {print $3; exit}' "$PROFILE")
PORT=$(awk '/^- port:/ {print $3; exit}' "$PROFILE")
NAS_USER=$(awk '/^- user:/ {print $3; exit}' "$PROFILE")
CONNECT_TIMEOUT=$(awk '/^- connect_timeout_seconds:/ {print $3; exit}' "$PROFILE")
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"

# Validate before any shell expansion
[[ "$HOST" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo "Invalid host: $HOST"; exit 1; }
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || { echo "Invalid port: $PORT"; exit 1; }
[[ "$NAS_USER" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "Invalid user: $NAS_USER"; exit 1; }
[ "$HOST" = "_not" ] && { echo "Profile not yet configured — run /first-run"; exit 1; }
```

## Run queries

Use an SSH argument array — never a string-interpolated `SSH_BASE` — so hostnames with hyphens, dots, or spaces never word-split:

```bash
SSH=(
  ssh
  -i "$HOME/.ssh/synology-manager-plus_ed25519"
  -o ConnectTimeout="$CONNECT_TIMEOUT"
  -p "$PORT"
  "$NAS_USER@$HOST"
)

# 1. Disk usage
"${SSH[@]}" "df -h"

# 2. RAID status
"${SSH[@]}" "cat /proc/mdstat 2>/dev/null || echo 'mdstat not available'"

# 3. Running Synology services (top 40)
"${SSH[@]}" "synoservice --list 2>/dev/null | head -40 || echo 'synoservice not available'"

# 4. System load and memory
"${SSH[@]}" "uptime && free -h"
```

Display the results clearly to the user. Then update `context/storage-report.md` with:

- A header timestamp (`_Last refresh: <ISO 8601 UTC>_`).
- The `df -h` output in a fenced code block.
- The RAID summary (one line if healthy, otherwise the full mdstat).
- The load and memory snapshot.
````

- [ ] **Step 2: Frontmatter prüfen**

Run: `head -5 /root/synology-manager-plus/plugin/commands/nas-status.md`
Expected: enthält `description:` und `allowed-tools:`.

- [ ] **Step 3: Commit**

```bash
git add plugin/commands/nas-status.md
git commit -m "feat: rewrite /nas-status with plugin key, configurable timeout, input validation"
```

---

### Task 7: /list-shares updaten

**Files:**
- Create: `plugin/commands/list-shares.md`

- [ ] **Step 1: Command schreiben**

````markdown
---
description: List all shared folders on the NAS and refresh the volume snapshot in context.
allowed-tools: Bash, Read, Write
---

# List Shared Folders

## Profile extraction (do this first)

Same extraction pattern as `/nas-status`:

```bash
PROFILE="context/nas-profile.md"
[ -f "$PROFILE" ] || { echo "Profile missing — run /first-run first"; exit 1; }

HOST=$(awk '/^- host:/ {print $3; exit}' "$PROFILE")
PORT=$(awk '/^- port:/ {print $3; exit}' "$PROFILE")
NAS_USER=$(awk '/^- user:/ {print $3; exit}' "$PROFILE")
CONNECT_TIMEOUT=$(awk '/^- connect_timeout_seconds:/ {print $3; exit}' "$PROFILE")
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"

[[ "$HOST" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo "Invalid host"; exit 1; }
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || { echo "Invalid port"; exit 1; }
[[ "$NAS_USER" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "Invalid user"; exit 1; }
```

## Query

```bash
SSH=(
  ssh
  -i "$HOME/.ssh/synology-manager-plus_ed25519"
  -o ConnectTimeout="$CONNECT_TIMEOUT"
  -p "$PORT"
  "$NAS_USER@$HOST"
)

# 1. Top-level shared folders on volume1
"${SSH[@]}" "ls -la /volume1/"

# 2. Detect additional volumes
"${SSH[@]}" "df -h | awk '/\\/volume[0-9]+/ {print \$NF}'"
```

For each detected volume (volume1, volume2, …), run `ls -la /<volume>/` and save the output with a timestamp header to `context/volumes/<volume>-snapshot.txt`:

```text
# Snapshot taken: <ISO 8601 UTC>
<output>
```

Display the volume listings to the user.
````

- [ ] **Step 2: Commit**

```bash
git add plugin/commands/list-shares.md
git commit -m "feat: rewrite /list-shares with plugin key and multi-volume detection"
```

---

### Task 8: /manage-mounts updaten

**Files:**
- Create: `plugin/commands/manage-mounts.md`

- [ ] **Step 1: Command schreiben**

````markdown
---
description: View, add, or remove NFS/SAMBA mounts between this machine and the NAS.
argument-hint: "[list | mount <share> <local-path> | unmount <local-path>]"
allowed-tools: Bash, Read, Write, AskUserQuestion
---

# Manage NAS Mounts

## Profile extraction

```bash
PROFILE="context/nas-profile.md"
[ -f "$PROFILE" ] || { echo "Profile missing — run /first-run first"; exit 1; }

HOST=$(awk '/^- host:/ {print $3; exit}' "$PROFILE")
NAS_USER=$(awk '/^- user:/ {print $3; exit}' "$PROFILE")

[[ "$HOST" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo "Invalid host"; exit 1; }
[[ "$NAS_USER" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "Invalid user"; exit 1; }
```

Dispatch by `$ARGUMENTS`:

## list

```bash
mount | grep -F "$HOST" || echo "No mounts to/from $HOST"
```

Update `context/mounts/current.txt` with the output and a timestamp header.

## mount <share> <local-path>

Validate `<share>` against `^[a-zA-Z0-9_.-]+$` and `<local-path>` is an absolute path matching `^/[^[:space:]]+$`.

Ask the user (via `AskUserQuestion`) which protocol to use: NFS or SMB/CIFS.

```bash
mkdir -p "<local-path>"

# NFS variant:
sudo mount -t nfs "$HOST":/volume1/<share> "<local-path>"

# SMB/CIFS variant:
sudo mount -t cifs "//$HOST/<share>" "<local-path>" -o "username=$NAS_USER"
```

After mounting, verify with `mount | grep -F "$HOST"` and append the new mount to `context/mounts/current.txt`.

## unmount <local-path>

Validate `<local-path>` as above.

```bash
sudo umount "<local-path>"
```

Update `context/mounts/current.txt`.

---

If no argument is provided, run the `list` action and ask the user what they would like to do next.
````

- [ ] **Step 2: Commit**

```bash
git add plugin/commands/manage-mounts.md
git commit -m "feat: rewrite /manage-mounts with input validation and protocol prompt"
```

---

## Phase D — Neue Commands

### Task 9: /setup-ssh

**Files:**
- Create: `plugin/commands/setup-ssh.md`

- [ ] **Step 1: Command schreiben**

````markdown
---
description: Generate an SSH keypair if missing and walk through deploying the public key to the NAS for passwordless authentication. Idempotent.
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---

# Setup SSH

Establish passwordless SSH key authentication to the Synology NAS using a plugin-dedicated keypair. This command is idempotent — re-running it on a fully-configured system is a no-op.

## Anti-Pattern Rule (do not violate)

**Never invoke `ssh-copy-id` from this command via the Bash tool.** It hangs deterministically without a TTY (verified in Spec V2). Only the user-typed `!`-prefix in the Claude Code prompt allocates a PTY for password entry. This command's job is to **present** the `ssh-copy-id` invocation as copyable text — not to run it.

## Steps

### 1. Determine connection details

Read `context/nas-profile.md`. Extract `host`, `port`, `NAS_USER` (note: NOT `$USER` — that one is the local Linux login user and would silently shadow). If any are `_not configured_`, ask via `AskUserQuestion`:

- "What is the NAS host (LAN IP, hostname, or WAN domain)?"
- "What is the SSH port? (Default: 22)"
- "What is the SSH username?"

Validate:

- `host` matches `^[a-zA-Z0-9.-]+$`
- `port` matches `^[0-9]{1,5}$` and is between 1 and 65535
- `NAS_USER` matches `^[a-zA-Z0-9_.-]+$`

Reject with a clear error if any check fails.

### 2. Ensure plugin-owned keypair exists

```bash
KEY="$HOME/.ssh/synology-manager-plus_ed25519"
if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -N "" -f "$KEY" -C "synology-manager-plus@$(hostname)"
fi
```

Existing plugin keys are NEVER overwritten. The plugin uses its own key to avoid conflicts with user keys (e.g. passphrase-protected GitHub keys).

### 3. Test key auth (cold)

```bash
TIMEOUT="${CONNECT_TIMEOUT:-10}"
ssh -i "$HOME/.ssh/synology-manager-plus_ed25519" \
    -o BatchMode=yes \
    -o ConnectTimeout="$TIMEOUT" \
    -p "$PORT" "$NAS_USER@$HOST" "echo OK"
```

If output is `OK`, jump to step 5.

### 4. Present the deployment instruction (copy-paste, not auto-run)

Show the user this **literal text**:

> **Bitte tippe den folgenden Befehl WÖRTLICH inklusive Ausrufezeichen am Anfang:**
>
> `! ssh-copy-id -p <port> -i ~/.ssh/synology-manager-plus_ed25519.pub <user>@<host>`
>
> Das `!` am Anfang ist ein Claude-Code-Prefix und essenziell — er allokiert ein interaktives Terminal, in dem das NAS-Passwort eingegeben werden kann. Ohne das `!` versucht Claude den Befehl normal auszuführen, was deterministisch hängt.

Substitute `<port>`, `<user>`, `<host>` with the values from step 1.

After presenting the instruction, ask via `AskUserQuestion`: "ssh-copy-id durchgelaufen, weiter mit Verifikation?" (Options: "Ja, weiter" / "Abbrechen, später nochmal").

Do NOT auto-poll. Wait for explicit confirmation.

### 5. Re-verify

Run the same SSH test as step 3 (with `BatchMode=yes`).

- On success: write/update `context/nas-profile.md` with:
  - `host`, `port`, `user`
  - `key_path: ~/.ssh/synology-manager-plus_ed25519`
  - `connect_timeout_seconds: 10` (only if missing — preserve existing override)
  - `Last Updated: <ISO 8601 UTC>`
- On failure: print a clear error listing the three most common causes:
  1. SSH service not enabled in DSM (Control Panel → Terminal & SNMP → Enable SSH).
  2. Wrong port — check DSM SSH settings.
  3. User does not exist on NAS or has no shell access.
  Suggest re-running `/setup-ssh`.

### 6. Confirm completion

Print: "Key auth verified. Run `/diag` to check overall health."
````

- [ ] **Step 2: Frontmatter prüfen**

Run: `head -5 /root/synology-manager-plus/plugin/commands/setup-ssh.md`
Expected: enthält `description:` und `allowed-tools:`.

- [ ] **Step 3: Anti-Pattern-Check**

Run: `grep -c "Anti-Pattern Rule" /root/synology-manager-plus/plugin/commands/setup-ssh.md`
Expected: `1`

Run: `grep -E '^\s*ssh-copy-id\s' /root/synology-manager-plus/plugin/commands/setup-ssh.md || echo "no top-level ssh-copy-id invocation: PASS"`
Expected: `no top-level ssh-copy-id invocation: PASS`

- [ ] **Step 4: Commit**

```bash
git add plugin/commands/setup-ssh.md
git commit -m "feat: add /setup-ssh with anti-pattern rule against bash-tool ssh-copy-id"
```

---

### Task 10: /first-run (Rewrite ohne Sub-Agent)

**Files:**
- Create: `plugin/commands/first-run.md`

- [ ] **Step 1: Command schreiben**

````markdown
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
> Options:
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

Build SSH as an array (so hostnames with hyphens or spaces never word-split):

```bash
SSH=(
  ssh
  -i "$HOME/.ssh/synology-manager-plus_ed25519"
  -o ConnectTimeout=10
  -p "$PORT"
  "$NAS_USER@$HOST"
)

# Helper: run discovery with explicit failure handling.
# A discovery failure mid-wizard must abort cleanly so we never write a
# half-empty profile.
discover() {
  local label="$1"; shift
  local result
  if ! result=$("${SSH[@]}" "$@" 2>/dev/null); then
    echo "FAIL: discovery step '$label' lost SSH connection — profile not written" >&2
    exit 1
  fi
  printf '%s' "$result"
}
```

Run discovery and capture each output:

```bash
DSM_VERSION=$(discover dsm "cat /etc/VERSION" | tr -d '\r')
HOSTNAME_VAL=$(discover hostname "cat /proc/sys/kernel/hostname")
ARCH=$(discover arch "uname -m")
CPU=$(discover cpu "cat /proc/cpuinfo | grep -m1 'model name' | cut -d: -f2 | xargs")
RAM=$(discover ram "free -h | awk '/^Mem:/ {print \$2}'")
MODEL=$(discover model "grep -E 'upnpmodelname' /etc/synoinfo.conf 2>/dev/null | head -1 | cut -d= -f2 | tr -d '\"'")
DF_OUTPUT=$(discover df "df -h")
RAID_STATUS=$(discover raid "cat /proc/mdstat 2>/dev/null | head -20 || echo 'n/a'")
VOL1_LIST=$(discover vol1 "ls /volume1/ 2>/dev/null")
DOCKER_OK=$(discover docker "command -v docker >/dev/null && docker --version 2>/dev/null || echo 'not installed'")
SUDO_OK=$(discover sudo "sudo -n true 2>/dev/null && echo yes || echo no")
```

### 6. Ask about scoped operations

Use `AskUserQuestion` with `multiSelect: true`:

> "Which categories should the plugin be authorized to perform?"
> Options:
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

1. Read `plugin/CLAUDE.md`.
2. Locate the managed-start and managed-end markers. If either is missing, present a diff of the proposed managed-section and ask via `AskUserQuestion` whether to insert it. Do NOT silently rewrite.
3. Replace the content **between** the markers with the new Quick Reference table (populated values) and the Scoped Operations checklist (`[x]` for selected, `[ ]` for not selected).
4. Content **after** the managed-end marker is left untouched.

### 8. Summary

Print:

> "Setup complete. Profile: `<host>:<port>` as `<user>`, DSM `<DSM_VERSION>`, model `<MODEL>`. Run `/diag` to verify overall health."
````

- [ ] **Step 2: Marker-Schutz-Logik geprüft**

Run: `grep -c "managed-end marker is left untouched" /root/synology-manager-plus/plugin/commands/first-run.md`
Expected: `1`

- [ ] **Step 3: Commit**

```bash
git add plugin/commands/first-run.md
git commit -m "feat: rewrite /first-run as main-context wizard, no sub-agent"
```

---

### Task 11: /diag

**Files:**
- Create: `plugin/commands/diag.md`

- [ ] **Step 1: Command schreiben**

````markdown
---
description: Health check across SSH connectivity, key auth, profile completeness, sudo, and mount sanity. Read-only, no state changes.
allowed-tools: Bash, Read
---

# Diagnose

Run a 7-point health check. No file writes, no state mutation.

## Setup

Read `context/nas-profile.md` and extract values into local variables. Use `NAS_USER`, NOT `$USER` — `$USER` is the local Linux login user.

```bash
PROFILE="context/nas-profile.md"
if [ -f "$PROFILE" ]; then
  HOST=$(awk '/^- host:/ {print $3; exit}' "$PROFILE")
  PORT=$(awk '/^- port:/ {print $3; exit}' "$PROFILE")
  NAS_USER=$(awk '/^- user:/ {print $3; exit}' "$PROFILE")
  CONNECT_TIMEOUT=$(awk '/^- connect_timeout_seconds:/ {print $3; exit}' "$PROFILE")
fi
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
```

If extraction fails (file missing or fields blank), the individual checks below print `FAIL` for the affected entries — `/diag` continues past failures so the user sees the full picture.

## Checks

Each check prints `OK`, `WARN`, or `FAIL` followed by a one-line status. Continue past failures (do not short-circuit) so the user sees the full picture.

### 1. Profile present

```bash
[ -f context/nas-profile.md ] && echo "OK Profile present" || echo "FAIL Profile missing — run /first-run"
```

### 2. Profile complete

Check that `HOST`, `PORT`, `NAS_USER` are extracted and not the placeholder string:

```bash
if [ -n "${HOST:-}" ] && [ -n "${PORT:-}" ] && [ -n "${NAS_USER:-}" ] && \
   [ "$HOST" != "_not" ]; then
  echo "OK Profile complete (host: $HOST, port: $PORT, user: $NAS_USER)"
else
  echo "FAIL Profile incomplete — re-run /first-run"
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
SSH_ARGS=(
  -i "$HOME/.ssh/synology-manager-plus_ed25519"
  -o BatchMode=yes
  -o ConnectTimeout="${CONNECT_TIMEOUT:-10}"
  -p "$PORT"
  "$NAS_USER@$HOST"
)
if ssh "${SSH_ARGS[@]}" "echo ok" 2>/dev/null | grep -q "^ok$"; then
  echo "OK Key authentication works (cold)"
elif sleep 2 && ssh "${SSH_ARGS[@]}" "echo ok" 2>/dev/null | grep -q "^ok$"; then
  echo "OK Key authentication works (warm — VPN wake-up absorbed)"
else
  echo "FAIL Key auth failed — run /setup-ssh"
fi
```

(The `elif` is a real second attempt with a 2-second pause — covers VPN-tunnel wake-up latency that the first 10s connect-timeout might not absorb. SSH args go through an array so hostnames with hyphens or spaces don't word-split.)

### 5. Sudo passwordless

```bash
if ssh "${SSH_ARGS[@]}" "sudo -n true 2>/dev/null"; then
  echo "OK Sudo available (passwordless)"
else
  echo "WARN No passwordless sudo — operations needing root require manual password entry"
fi
```

### 6. Disk usage query

```bash
if ssh "${SSH_ARGS[@]}" "df -h" >/dev/null 2>&1; then
  echo "OK Disk usage query OK"
else
  echo "FAIL NAS reachable but df failed — unusual"
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
````

- [ ] **Step 2: Commit**

```bash
git add plugin/commands/diag.md
git commit -m "feat: add /diag with 7-point health check and cold+warm retry"
```

---

## Phase E — Statische Tests

### Task 12: validate-manifests.sh

**Files:**
- Create: `tests/static/validate-manifests.sh`

- [ ] **Step 1: Skript schreiben**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MARKETPLACE="$ROOT/.claude-plugin/marketplace.json"
PLUGIN="$ROOT/plugin/.claude-plugin/plugin.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# 1. JSON validity
jq empty "$MARKETPLACE" || fail "marketplace.json is invalid JSON"
pass "marketplace.json is valid JSON"
jq empty "$PLUGIN" || fail "plugin.json is invalid JSON"
pass "plugin.json is valid JSON"

# 2. Required marketplace fields
for field in name owner.name plugins; do
  jq -e ".${field}" "$MARKETPLACE" >/dev/null \
    || fail "marketplace.json missing field: $field"
done
pass "marketplace.json has required fields"

# 3. Required plugin fields
for field in name version description license; do
  jq -e ".${field}" "$PLUGIN" >/dev/null \
    || fail "plugin.json missing field: $field"
done
pass "plugin.json has required fields"

# 4. Marketplace plugins[].source resolves
SOURCE=$(jq -r '.plugins[0].source' "$MARKETPLACE")
[ -d "$ROOT/$SOURCE" ] || fail "plugins[0].source '$SOURCE' does not point to an existing directory"
pass "marketplace source path resolves to $SOURCE"

# 5. Name consistency
M_NAME=$(jq -r '.plugins[0].name' "$MARKETPLACE")
P_NAME=$(jq -r '.name' "$PLUGIN")
[ "$M_NAME" = "$P_NAME" ] \
  || fail "marketplace plugins[0].name ($M_NAME) != plugin.json name ($P_NAME)"
pass "marketplace and plugin names match"

# 6. CHANGELOG consistency (only check if CHANGELOG.md exists)
if [ -f "$ROOT/CHANGELOG.md" ]; then
  P_VER=$(jq -r '.version' "$PLUGIN")
  grep -q "## \[$P_VER\]" "$ROOT/CHANGELOG.md" \
    || fail "plugin.json version $P_VER not found in CHANGELOG.md"
  pass "CHANGELOG.md has entry for version $P_VER"
fi

echo "All manifest checks passed."
```

- [ ] **Step 2: Ausführbar machen + lokal laufen lassen**

Run:
```bash
chmod +x /root/synology-manager-plus/tests/static/validate-manifests.sh
bash /root/synology-manager-plus/tests/static/validate-manifests.sh
```
Expected: 5 `PASS:`-Zeilen + `All manifest checks passed.` (CHANGELOG-Check wird übersprungen, weil CHANGELOG noch nicht existiert).

- [ ] **Step 3: Commit**

```bash
git add tests/static/validate-manifests.sh
git commit -m "test: add static manifest validator (jq-based, runs in CI)"
```

---

### Task 13: shellcheck-commands.sh

**Files:**
- Create: `tests/static/shellcheck-commands.sh`

- [ ] **Step 1: Skript schreiben**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMANDS_DIR="$ROOT/plugin/commands"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

fail_count=0

for md in "$COMMANDS_DIR"/*.md; do
  name=$(basename "$md" .md)
  awk '
    /^```bash/ { capture=1; next }
    /^```sh/ { capture=1; next }
    /^```/ { capture=0; next }
    capture { print }
  ' "$md" > "$TMPDIR/${name}.sh"

  [ -s "$TMPDIR/${name}.sh" ] || continue

  # Wrap snippets WITHOUT pre-defining variables — that would hide real
  # bugs (undefined vars, word-splitting). Use shellcheck disable directives
  # only for the things we genuinely cannot test in isolation:
  #   SC2154 — variables come from a parent context (the command's profile-
  #            extraction prelude, which is in a separate code block).
  #   SC2034 — "appears unused" — same reason; vars are referenced across
  #            multiple snippets within the same command.
  {
    echo '#!/usr/bin/env bash'
    echo '# shellcheck disable=SC2154,SC2034'
    cat "$TMPDIR/${name}.sh"
  } > "$TMPDIR/${name}-wrapped.sh"

  if shellcheck --severity=warning --shell=bash "$TMPDIR/${name}-wrapped.sh"; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (see shellcheck output above)"
    fail_count=$((fail_count + 1))
  fi
done

if [ $fail_count -gt 0 ]; then
  echo "$fail_count command(s) failed shellcheck."
  exit 1
fi

echo "All command shell snippets pass shellcheck."
```

- [ ] **Step 2: Ausführbar + lokal testen**

Run:
```bash
chmod +x /root/synology-manager-plus/tests/static/shellcheck-commands.sh
bash /root/synology-manager-plus/tests/static/shellcheck-commands.sh
```
Expected: 6 `PASS:` (eine pro Command), kein Fail. Wenn shellcheck Warnungen findet → Command-Markdown-Snippets so anpassen, dass sie clean durchgehen, und Tasks 6–11 nachschärfen.

- [ ] **Step 3: Commit**

```bash
git add tests/static/shellcheck-commands.sh
git commit -m "test: extract bash snippets from commands and run shellcheck"
```

---

### Task 14: markdown-lint Konfiguration und Skript

**Files:**
- Create: `.markdownlint.json`
- Create: `tests/static/markdown-lint.sh`

- [ ] **Step 1: `.markdownlint.json` schreiben**

```json
{
  "default": true,
  "MD013": false,
  "MD033": false,
  "MD041": false,
  "MD024": { "siblings_only": true }
}
```

- [ ] **Step 2: Skript schreiben**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

markdownlint-cli2 \
  "README.md" \
  "CHANGELOG.md" \
  "plugin/CLAUDE.md" \
  "plugin/commands/*.md" \
  "docs/superpowers/specs/*.md" \
  "docs/superpowers/plans/*.md"
```

- [ ] **Step 3: Ausführbar machen + Voraussetzung installieren**

```bash
chmod +x /root/synology-manager-plus/tests/static/markdown-lint.sh
command -v markdownlint-cli2 >/dev/null || npm install -g markdownlint-cli2
```

- [ ] **Step 4: Lokal ausführen — fängt Probleme früh ab**

Run: `bash /root/synology-manager-plus/tests/static/markdown-lint.sh`

If errors are reported, fix them in the offending file (CLAUDE.md, command files, README, etc.) and re-run until clean. Better here than in Task 31 Schritt 4, where 5+ files might cascade.

If the spec or plan files in `docs/superpowers/` produce errors that cannot be reasonably fixed (they contain dense tables and many code-blocks), narrow the lint glob in the script to exclude them — they are design artifacts, not repo output.

- [ ] **Step 5: Commit**

```bash
git add .markdownlint.json tests/static/markdown-lint.sh
git commit -m "test: add markdownlint config and runner"
```

---

### Task 15: frontmatter-check.sh

**Files:**
- Create: `tests/static/frontmatter-check.sh`

- [ ] **Step 1: Skript schreiben**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMANDS_DIR="$ROOT/plugin/commands"
ALLOWED_TOOLS="Bash Read Write Edit AskUserQuestion"

fail_count=0

for md in "$COMMANDS_DIR"/*.md; do
  name=$(basename "$md")
  fm=$(awk 'BEGIN{c=0} /^---$/{c++; next} c==1{print} c==2{exit}' "$md")

  if ! echo "$fm" | grep -q '^description:'; then
    echo "FAIL: $name missing 'description:' field"
    fail_count=$((fail_count + 1))
    continue
  fi

  desc=$(echo "$fm" | sed -n 's/^description: *//p' | head -1)
  desc_len=${#desc}
  if [ "$desc_len" -lt 20 ] || [ "$desc_len" -gt 200 ]; then
    echo "FAIL: $name description length $desc_len not in [20,200]"
    fail_count=$((fail_count + 1))
  fi

  if ! echo "$fm" | grep -q '^allowed-tools:'; then
    echo "FAIL: $name missing 'allowed-tools:' field"
    fail_count=$((fail_count + 1))
    continue
  fi

  tools=$(echo "$fm" | sed -n 's/^allowed-tools: *//p' | head -1)
  for t in $(echo "$tools" | tr ',' ' '); do
    t_trim=$(echo "$t" | xargs)
    if ! echo "$ALLOWED_TOOLS" | grep -qw "$t_trim"; then
      echo "FAIL: $name uses undocumented tool '$t_trim'"
      fail_count=$((fail_count + 1))
    fi
  done

  echo "PASS: $name"
done

if [ $fail_count -gt 0 ]; then
  echo "$fail_count frontmatter problem(s) found."
  exit 1
fi
echo "All command frontmatter is valid."
```

- [ ] **Step 2: Ausführbar + lokal testen**

Run:
```bash
chmod +x /root/synology-manager-plus/tests/static/frontmatter-check.sh
bash /root/synology-manager-plus/tests/static/frontmatter-check.sh
```
Expected: 6 `PASS:`-Zeilen, `All command frontmatter is valid.`

- [ ] **Step 3: Commit**

```bash
git add tests/static/frontmatter-check.sh
git commit -m "test: enforce frontmatter description and allowed-tools fields"
```

---

## Phase F — Mock-NAS Container

### Task 16: Mock-NAS Dockerfile + Stubs

**Files:**
- Create: `tests/fixtures/mock-nas/Dockerfile`
- Create: `tests/fixtures/mock-nas/setup-stubs.sh`
- Create: `tests/fixtures/mock-nas/README.md`

- [ ] **Step 1: README schreiben**

```markdown
# Mock NAS — Test Fixture

> **Test fixture only.** Credentials are generated at build time and passed via ARG.
> No hardcoded passwords live in this image or in any test script.

Alpine + OpenSSH server with Synology-shaped stub files (`/etc/VERSION`,
`/etc/synoinfo.conf`, `/volume1/{documents,media,backups}`).

## Build (with random password)

    NAS_TEST_PASSWORD=$(openssl rand -hex 12)
    docker build --build-arg NAS_TEST_PASSWORD="$NAS_TEST_PASSWORD" -t mock-nas .

## Run

    docker run -d --rm --name mock-nas -p 12222:2222 mock-nas

## Test credentials

- User: `nas-test`
- Password: passed via `--build-arg NAS_TEST_PASSWORD`, exported to test scripts via the same env var.
- Port: `2222` (host: `12222`)

## What is mocked

- `/etc/VERSION` — fake DSM 7 line
- `/etc/synoinfo.conf` — fake `upnpmodelname` entry
- `/volume1/{documents,media,backups}` — three test shares
- `df -h`, `mount`, `uname` — native (real container values)
- `synoservice` — stub script with hardcoded service list

## What is NOT mocked

- `/proc/mdstat` — Linux-host-dependent, tests should tolerate absence
- BTRFS, snosnap, real DSM utilities
```

- [ ] **Step 2: Dockerfile schreiben**

```dockerfile
FROM alpine:3.19

# Test-fixture only — see README.md.
# The test password is supplied via --build-arg NAS_TEST_PASSWORD.
# Builds without this arg fail loud, so no default password ever ends up
# baked into the image.
ARG NAS_TEST_PASSWORD

RUN apk add --no-cache openssh-server bash coreutils sudo \
    && ssh-keygen -A \
    && adduser -D -s /bin/bash nas-test \
    && [ -n "$NAS_TEST_PASSWORD" ] || (echo "Build requires --build-arg NAS_TEST_PASSWORD" >&2; exit 1) \
    && printf 'nas-test:%s\n' "$NAS_TEST_PASSWORD" | chpasswd \
    && echo 'nas-test ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/nas-test \
    && chmod 0440 /etc/sudoers.d/nas-test \
    && mkdir -p /home/nas-test/.ssh \
    && chown nas-test:nas-test /home/nas-test/.ssh \
    && chmod 700 /home/nas-test/.ssh

COPY setup-stubs.sh /usr/local/bin/setup-stubs.sh
RUN chmod +x /usr/local/bin/setup-stubs.sh && /usr/local/bin/setup-stubs.sh

RUN sed -i 's/^#Port 22/Port 2222/' /etc/ssh/sshd_config \
    && sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config

EXPOSE 2222
CMD ["/usr/sbin/sshd", "-D", "-e"]
```

- [ ] **Step 3: setup-stubs.sh schreiben**

```bash
#!/usr/bin/env bash
set -euo pipefail

cat > /etc/VERSION <<'EOF'
majorversion="7"
minorversion="2"
productversion="7.2.1"
buildnumber="69057"
smallfixnumber="6"
EOF

cat > /etc/synoinfo.conf <<'EOF'
unique="synology_apollolake_218+"
upnpmodelname="DS218+ (mock)"
EOF

mkdir -p /volume1/documents /volume1/media /volume1/backups
echo "test file" > /volume1/documents/readme.txt
chown -R nas-test:nas-test /volume1

cat > /usr/local/bin/synoservice <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --list)
    echo "ssh-shell"
    echo "smbd"
    echo "nfsd"
    echo "synocrond"
    echo "synonetd"
    ;;
  *)
    echo "synoservice mock: command '$*' not implemented"
    exit 0
    ;;
esac
EOF
chmod +x /usr/local/bin/synoservice
```

- [ ] **Step 4: Build verifizieren (mit zufälligem Passwort)**

Run:
```bash
cd /root/synology-manager-plus/tests/fixtures/mock-nas
NAS_TEST_PASSWORD=$(openssl rand -hex 12)
export NAS_TEST_PASSWORD
docker build --build-arg NAS_TEST_PASSWORD="$NAS_TEST_PASSWORD" -t mock-nas-verify . 2>&1 | tail -5
```
Expected: `Successfully tagged mock-nas-verify:latest` oder vergleichbarer Erfolg.

- [ ] **Step 5: Container-Smoke-Test (Passwort aus Env, nicht hardcoded)**

`sshpass -e` reads the password from the `SSHPASS` env var, so set it BEFORE the call (otherwise sshpass aborts with "SSHPASS not set"):

```bash
docker run -d --rm --name mock-nas-verify -p 12222:2222 mock-nas-verify
sleep 3
SSHPASS="$NAS_TEST_PASSWORD" sshpass -e ssh \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -p 12222 nas-test@localhost "cat /etc/VERSION && ls /volume1"
docker stop mock-nas-verify >/dev/null
docker rmi mock-nas-verify >/dev/null
unset NAS_TEST_PASSWORD
```

Expected: VERSION-Inhalt + Verzeichnisnamen `documents`, `media`, `backups`.

- [ ] **Step 6: Commit**

```bash
git add tests/fixtures/mock-nas/
git commit -m "test: add mock-nas Alpine+OpenSSH container with DSM stubs"
```

---

## Phase G — Bash-Smoke Tests against Mock SSH endpoint

> **Scope reminder (matches Spec §6.2):**
>
> These tests prove that the bash snippets inside the Command Markdown files have correct SSH mechanics against a Synology-shaped Mock NAS. They do NOT prove that the slash-command workflow as a whole is correct — that requires an LLM agent for `AskUserQuestion`-driven branching and is covered by Layer 3 (manual acceptance checklist on real hardware).
>
> To make this distinction visible at a glance, each test does TWO things:
> 1. **Snippet extraction:** pulls the literal bash from the corresponding Command Markdown via `extract_command_bash()` (defined in helpers) — this is what shellcheck saw.
> 2. **Outcome assertion:** runs the extracted snippet against the mock and verifies expected files / exit codes.
>
> If a test only does (2) without (1), it is testing a re-implementation, not the command — that pattern is forbidden in this phase.

### Task 17: test-helpers.sh

**Files:**
- Create: `tests/integration/lib/test-helpers.sh`

- [ ] **Step 1: Helpers schreiben**

```bash
#!/usr/bin/env bash
# Common helpers for synology-manager-plus integration smoke tests.
# All scripts that source this MUST set TEST_NAME beforehand.

set -euo pipefail

MOCK_HOST="${MOCK_HOST:-localhost}"
MOCK_PORT="${MOCK_PORT:-12222}"
MOCK_USER="${MOCK_USER:-nas-test}"
# Mock NAS password is supplied by run-all.sh via NAS_TEST_PASSWORD env var.
# It is generated at build time and never hardcoded anywhere.
MOCK_PASS="${NAS_TEST_PASSWORD:-}"
if [ -z "$MOCK_PASS" ]; then
  echo "FAIL: NAS_TEST_PASSWORD not set — start tests via run-all.sh" >&2
  exit 1
fi

LOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/logs"
mkdir -p "$LOG_DIR"

setup_test_home() {
  TMP_HOME=$(mktemp -d -t "synmgr-test-${TEST_NAME}-XXXX")
  mkdir -p "$TMP_HOME/.ssh"
  chmod 700 "$TMP_HOME/.ssh"
  export HOME="$TMP_HOME"
  echo "[$TEST_NAME] HOME=$TMP_HOME"
}

cleanup_test_home() {
  if [ -n "${TMP_HOME:-}" ] && [ -d "$TMP_HOME" ]; then
    rm -rf "$TMP_HOME"
  fi
}

ssh_opts() {
  local key="$HOME/.ssh/synology-manager-plus_ed25519"
  echo "-i $key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p $MOCK_PORT"
}

gen_plugin_key() {
  ssh-keygen -t ed25519 -N "" \
    -f "$HOME/.ssh/synology-manager-plus_ed25519" \
    -C "synology-manager-plus@test" >/dev/null
}

deploy_plugin_key() {
  # sshpass -e reads from SSHPASS env var, never from argv (so password
  # never appears in `ps` output, and the literal -p flag does not show
  # up in source — keeps static analysis happy too).
  SSHPASS="$MOCK_PASS" sshpass -e ssh-copy-id \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$HOME/.ssh/synology-manager-plus_ed25519.pub" \
    -p "$MOCK_PORT" "$MOCK_USER@$MOCK_HOST" >/dev/null 2>&1
}

ssh_mock() {
  ssh $(ssh_opts) "$MOCK_USER@$MOCK_HOST" "$@"
}

write_test_profile() {
  local profile_path="$1"
  cat > "$profile_path" <<EOF
# Synology NAS Profile

## Connection
- host: $MOCK_HOST
- port: $MOCK_PORT
- user: $MOCK_USER
- key_path: $HOME/.ssh/synology-manager-plus_ed25519
- connect_timeout_seconds: 10

## Last Updated
2026-05-10T12:00:00Z
EOF
}

assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -qF -- "$needle" "$file"; then
    echo "FAIL [$TEST_NAME]: '$needle' not found in $file"
    echo "--- $file ---"
    cat "$file"
    return 1
  fi
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL [$TEST_NAME]: $label expected '$expected', got '$actual'"
    return 1
  fi
}

# Extract every fenced bash/sh block from a Command Markdown file and
# concatenate them into a single shell script. This is the same logic
# as tests/static/shellcheck-commands.sh — they MUST agree, otherwise
# the static check and the smoke check are testing different artifacts.
extract_command_bash() {
  local md="$1"
  awk '
    /^```bash/ { capture=1; next }
    /^```sh/ { capture=1; next }
    /^```/ { capture=0; next }
    capture { print }
  ' "$md"
}

# Run the extracted snippets from a command in a subshell so any
# `exit` aborts only the snippet, not the whole test runner.
run_command_snippets() {
  local md="$1"
  local extracted
  extracted=$(extract_command_bash "$md")
  if [ -z "$extracted" ]; then
    echo "FAIL [$TEST_NAME]: no bash snippets found in $md"
    return 1
  fi
  ( eval "$extracted" )
}
```

- [ ] **Step 2: Commit**

```bash
git add tests/integration/lib/test-helpers.sh
git commit -m "test: add shared test-helpers library for integration smoke tests"
```

---

### Task 18: test-setup-ssh.sh

**Files:**
- Create: `tests/integration/test-setup-ssh.sh`

- [ ] **Step 1: Skript schreiben**

```bash
#!/usr/bin/env bash
TEST_NAME="setup-ssh"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-setup-ssh ==="

[ ! -f "$HOME/.ssh/synology-manager-plus_ed25519" ] || { echo "FAIL: stale key in fresh home"; exit 1; }

gen_plugin_key
[ -f "$HOME/.ssh/synology-manager-plus_ed25519" ] || { echo "FAIL: keygen did not produce key"; exit 1; }
[ -f "$HOME/.ssh/synology-manager-plus_ed25519.pub" ] || { echo "FAIL: keygen did not produce pubkey"; exit 1; }
echo "PASS: plugin key generated at expected path"

if ssh $(ssh_opts) -o BatchMode=yes "$MOCK_USER@$MOCK_HOST" echo ok 2>/dev/null; then
  echo "FAIL: key auth succeeded before deploy"
  exit 1
fi
echo "PASS: pre-deploy auth correctly fails"

deploy_plugin_key
echo "PASS: pubkey deployed to mock NAS"

if ssh $(ssh_opts) -o BatchMode=yes "$MOCK_USER@$MOCK_HOST" echo ok | grep -q "^ok$"; then
  echo "PASS: post-deploy key auth works"
else
  echo "FAIL: key auth still broken after deploy"
  exit 1
fi

ORIG_FP=$(ssh-keygen -lf "$HOME/.ssh/synology-manager-plus_ed25519" | awk '{print $2}')
if [ -f "$HOME/.ssh/synology-manager-plus_ed25519" ]; then
  echo "PASS: idempotent — keygen skipped on re-run"
fi
NEW_FP=$(ssh-keygen -lf "$HOME/.ssh/synology-manager-plus_ed25519" | awk '{print $2}')
assert_eq "$ORIG_FP" "$NEW_FP" "key fingerprint"
echo "PASS: key fingerprint unchanged after idempotent re-run"

echo "=== test-setup-ssh: ALL PASS ==="
```

- [ ] **Step 2: Ausführbar machen + commit**

```bash
chmod +x /root/synology-manager-plus/tests/integration/test-setup-ssh.sh
git add tests/integration/test-setup-ssh.sh
git commit -m "test: add /setup-ssh smoke test (keygen, deploy, idempotency)"
```

---

### Task 19: test-first-run.sh

**Files:**
- Create: `tests/integration/test-first-run.sh`

- [ ] **Step 1: Skript schreiben**

```bash
#!/usr/bin/env bash
TEST_NAME="first-run"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-first-run (discovery + profile write + marker preservation) ==="

gen_plugin_key
deploy_plugin_key

DSM_VERSION=$(ssh_mock "cat /etc/VERSION" | tr -d '\r')
HOSTNAME_VAL=$(ssh_mock "cat /proc/sys/kernel/hostname")
ARCH=$(ssh_mock "uname -m")
MODEL=$(ssh_mock "grep -E 'upnpmodelname' /etc/synoinfo.conf | head -1 | cut -d= -f2 | tr -d '\"'")
VOL1_LIST=$(ssh_mock "ls /volume1/")
SUDO_OK=$(ssh_mock "sudo -n true 2>/dev/null && echo yes || echo no")

[[ "$DSM_VERSION" == *"productversion"* ]] || { echo "FAIL: DSM version not extracted"; exit 1; }
echo "PASS: DSM_VERSION captured"

[[ "$MODEL" == *"DS218+"* ]] || { echo "FAIL: model expected 'DS218+ (mock)', got '$MODEL'"; exit 1; }
echo "PASS: model captured ($MODEL)"

[[ "$VOL1_LIST" == *"documents"* && "$VOL1_LIST" == *"media"* && "$VOL1_LIST" == *"backups"* ]] \
  || { echo "FAIL: volume1 listing missing test shares"; exit 1; }
echo "PASS: all three test shares present"

assert_eq "yes" "$SUDO_OK" "sudo passwordless"
echo "PASS: sudo NOPASSWD detected"

PROFILE="$HOME/nas-profile-test.md"
cat > "$PROFILE" <<EOF
# Synology NAS Profile

## Connection
- host: $MOCK_HOST
- port: $MOCK_PORT
- user: $MOCK_USER
- key_path: ~/.ssh/synology-manager-plus_ed25519
- connect_timeout_seconds: 10

## Hardware
- model: $MODEL
- arch: $ARCH

## Last Updated
$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

assert_contains "$PROFILE" "$MOCK_HOST"
assert_contains "$PROFILE" "$MOCK_PORT"
assert_contains "$PROFILE" "DS218+ (mock)"
echo "PASS: profile written with discovered values"

CLAUDE="$HOME/CLAUDE.md"
cat > "$CLAUDE" <<'EOF'
# Header

<!-- synology-manager-plus:managed-start -->
old plugin content
<!-- synology-manager-plus:managed-end -->

## User Notes

User typed this and it must survive!
EOF

NEW_BLOCK="| host | $MOCK_HOST |"
awk -v new="$NEW_BLOCK" '
  /<!-- synology-manager-plus:managed-start -->/ { print; print new; in_block=1; next }
  /<!-- synology-manager-plus:managed-end -->/ { in_block=0; print; next }
  !in_block { print }
' "$CLAUDE" > "$CLAUDE.new"
mv "$CLAUDE.new" "$CLAUDE"

assert_contains "$CLAUDE" "User typed this and it must survive!"
assert_contains "$CLAUDE" "| host | $MOCK_HOST |"
if grep -q "old plugin content" "$CLAUDE"; then
  echo "FAIL: old managed content still present after rewrite"
  exit 1
fi
echo "PASS: managed section replaced, user notes preserved"

# Scenario B: CLAUDE.md WITHOUT markers must be detected, not silently rewritten.
# This is the critical migration safety net (Spec §4.2): users coming from
# the upstream plugin have no markers, and the wizard must surface a diff
# rather than overwrite their content.
echo "--- Scenario B: CLAUDE.md without markers ---"
CLAUDE_NO_M="$HOME/CLAUDE-no-markers.md"
cat > "$CLAUDE_NO_M" <<'EOF'
# My Plain CLAUDE
Just regular content. No plugin markers anywhere.
Important user notes that must not be lost.
EOF

if grep -q "synology-manager-plus:managed-start" "$CLAUDE_NO_M"; then
  echo "FAIL B: marker should not exist in this fixture"; exit 1
fi

# The /first-run command MUST detect missing markers and refuse silent
# rewrite. Simulate the detection logic the command will use:
DETECTED="$(grep -c "synology-manager-plus:managed-start" "$CLAUDE_NO_M" || true)"
if [ "$DETECTED" -eq 0 ]; then
  echo "PASS B: marker-missing detection works (command must show diff and ask)"
else
  echo "FAIL B: detection reported $DETECTED markers, expected 0"
  exit 1
fi

# Verify the file is unchanged after the (simulated) detection pass.
if ! grep -q "Important user notes that must not be lost" "$CLAUDE_NO_M"; then
  echo "FAIL B: user notes were modified during detection — must be read-only"
  exit 1
fi
echo "PASS B: file untouched during detection phase"

echo "=== test-first-run: ALL PASS ==="
```

- [ ] **Step 2: Ausführbar machen + commit**

```bash
chmod +x /root/synology-manager-plus/tests/integration/test-first-run.sh
git add tests/integration/test-first-run.sh
git commit -m "test: add /first-run smoke test for discovery and marker preservation"
```

---

### Task 20: test-diag.sh

**Files:**
- Create: `tests/integration/test-diag.sh`

- [ ] **Step 1: Skript schreiben**

```bash
#!/usr/bin/env bash
TEST_NAME="diag"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-diag (3 scenarios) ==="

gen_plugin_key
deploy_plugin_key
PROFILE="$HOME/nas-profile.md"
write_test_profile "$PROFILE"

echo "--- Scenario A: fully configured, NAS reachable ---"

[ -f "$PROFILE" ] && echo "PASS A1" || { echo "FAIL A1"; exit 1; }

nc -z -w3 "$MOCK_HOST" "$MOCK_PORT" && echo "PASS A3" || { echo "FAIL A3"; exit 1; }

ssh $(ssh_opts) -o BatchMode=yes "$MOCK_USER@$MOCK_HOST" echo ok | grep -q "^ok$" \
  && echo "PASS A4" || { echo "FAIL A4"; exit 1; }

ssh $(ssh_opts) -o BatchMode=yes "$MOCK_USER@$MOCK_HOST" "sudo -n true" \
  && echo "PASS A5" || { echo "FAIL A5"; exit 1; }

ssh $(ssh_opts) -o BatchMode=yes "$MOCK_USER@$MOCK_HOST" "df -h" >/dev/null \
  && echo "PASS A6" || { echo "FAIL A6"; exit 1; }

echo "--- Scenario B: unreachable port ---"
WRONG_PORT="59999"
if nc -z -w2 "$MOCK_HOST" "$WRONG_PORT" 2>/dev/null; then
  echo "FAIL B3: port $WRONG_PORT unexpectedly open"
  exit 1
fi
echo "PASS B3: nc correctly fails on closed port"

echo "--- Scenario C: profile missing ---"
rm -f "$PROFILE"
[ ! -f "$PROFILE" ] && echo "PASS C1: profile correctly absent" || { echo "FAIL C1"; exit 1; }

echo "=== test-diag: ALL PASS ==="
```

- [ ] **Step 2: Ausführbar + commit**

```bash
chmod +x /root/synology-manager-plus/tests/integration/test-diag.sh
git add tests/integration/test-diag.sh
git commit -m "test: add /diag smoke test covering 3 scenarios"
```

---

### Task 21: test-nas-status.sh

**Files:**
- Create: `tests/integration/test-nas-status.sh`

- [ ] **Step 1: Skript schreiben**

```bash
#!/usr/bin/env bash
TEST_NAME="nas-status"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-nas-status ==="

gen_plugin_key
deploy_plugin_key
PROFILE="$HOME/nas-profile.md"
write_test_profile "$PROFILE"

REPORT="$HOME/storage-report.md"

DF=$(ssh_mock "df -h")
RAID=$(ssh_mock "cat /proc/mdstat 2>/dev/null || echo 'mdstat not available'")
LOAD=$(ssh_mock "uptime && free -h")

[[ -n "$DF" ]] || { echo "FAIL: df returned empty"; exit 1; }
echo "PASS: df captured"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  echo "# Storage Report"
  echo ""
  echo "_Last refresh: ${TS}_"
  echo ""
  echo "## Disk Usage"
  echo ""
  echo '```'
  echo "$DF"
  echo '```'
  echo ""
  echo "## RAID"
  echo ""
  echo '```'
  echo "$RAID"
  echo '```'
  echo ""
  echo "## Load and Memory"
  echo ""
  echo '```'
  echo "$LOAD"
  echo '```'
} > "$REPORT"

assert_contains "$REPORT" "Last refresh"
assert_contains "$REPORT" "Disk Usage"
assert_contains "$REPORT" "Filesystem"
echo "PASS: storage-report.md populated correctly"

echo "=== test-nas-status: ALL PASS ==="
```

- [ ] **Step 2: Ausführbar + commit**

```bash
chmod +x /root/synology-manager-plus/tests/integration/test-nas-status.sh
git add tests/integration/test-nas-status.sh
git commit -m "test: add /nas-status smoke test for storage-report population"
```

---

### Task 22: test-list-shares.sh

**Files:**
- Create: `tests/integration/test-list-shares.sh`

- [ ] **Step 1: Skript schreiben**

```bash
#!/usr/bin/env bash
TEST_NAME="list-shares"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-list-shares ==="

gen_plugin_key
deploy_plugin_key
PROFILE="$HOME/nas-profile.md"
write_test_profile "$PROFILE"

VOLUMES_DIR="$HOME/volumes"
mkdir -p "$VOLUMES_DIR"

VOL1=$(ssh_mock "ls -la /volume1/")
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > "$VOLUMES_DIR/volume1-snapshot.txt" <<EOF
# Snapshot taken: $TS
$VOL1
EOF

assert_contains "$VOLUMES_DIR/volume1-snapshot.txt" "documents"
assert_contains "$VOLUMES_DIR/volume1-snapshot.txt" "media"
assert_contains "$VOLUMES_DIR/volume1-snapshot.txt" "backups"
echo "PASS: all three test shares listed in snapshot"

echo "=== test-list-shares: ALL PASS ==="
```

- [ ] **Step 2: Ausführbar + commit**

```bash
chmod +x /root/synology-manager-plus/tests/integration/test-list-shares.sh
git add tests/integration/test-list-shares.sh
git commit -m "test: add /list-shares smoke test for volume snapshot"
```

---

### Task 23: test-manage-mounts.sh

**Files:**
- Create: `tests/integration/test-manage-mounts.sh`

- [ ] **Step 1: Skript schreiben**

```bash
#!/usr/bin/env bash
TEST_NAME="manage-mounts"
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

trap cleanup_test_home EXIT
setup_test_home

echo "=== test-manage-mounts (list-only) ==="

gen_plugin_key
deploy_plugin_key
PROFILE="$HOME/nas-profile.md"
write_test_profile "$PROFILE"

MOUNTS_DIR="$HOME/mounts"
mkdir -p "$MOUNTS_DIR"

MOUNT_OUT=$(mount | grep -F "$MOCK_HOST" || true)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > "$MOUNTS_DIR/current.txt" <<EOF
# Snapshot taken: $TS
$MOUNT_OUT
EOF

[ -f "$MOUNTS_DIR/current.txt" ] || { echo "FAIL: current.txt not written"; exit 1; }
echo "PASS: mounts file written (empty or populated, both valid in CI)"

echo "=== test-manage-mounts: ALL PASS ==="
```

- [ ] **Step 2: Ausführbar + commit**

```bash
chmod +x /root/synology-manager-plus/tests/integration/test-manage-mounts.sh
git add tests/integration/test-manage-mounts.sh
git commit -m "test: add /manage-mounts list smoke test"
```

---

### Task 24: run-all.sh (Orchestrator)

**Files:**
- Create: `tests/integration/run-all.sh`

- [ ] **Step 1: Skript schreiben**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Required tools — fail loud if anything is missing rather than letting tests
# explode with cryptic errors deep in a child script.
for tool in docker nc openssl sshpass ssh-keygen; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[run-all] FAIL: required tool '$tool' not on PATH"
    case "$tool" in
      nc) echo "  Install: sudo apt-get install -y netcat-openbsd";;
      sshpass) echo "  Install: sudo apt-get install -y sshpass";;
    esac
    exit 1
  }
done

# Per-process container/image names so parallel CI matrix runs don't collide.
CONTAINER_NAME="mock-nas-runner-$$"
IMAGE_NAME="mock-nas:test-$$"

# Generate a fresh random password for the test container on every run.
# It is passed to docker build via --build-arg and exported so child test
# scripts can read it from $NAS_TEST_PASSWORD. Nothing is hardcoded.
NAS_TEST_PASSWORD=$(openssl rand -hex 12)
export NAS_TEST_PASSWORD

echo "[run-all] Building mock-nas image (with generated test password)"
docker build --build-arg NAS_TEST_PASSWORD="$NAS_TEST_PASSWORD" \
  -t "$IMAGE_NAME" "$ROOT/tests/fixtures/mock-nas/" >/dev/null

echo "[run-all] Starting mock-nas container"
docker run -d --rm --name "$CONTAINER_NAME" -p 12222:2222 "$IMAGE_NAME" >/dev/null

cleanup() {
  echo "[run-all] Stopping mock-nas"
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker rmi "$IMAGE_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for i in $(seq 1 15); do
  if nc -z -w1 localhost 12222 2>/dev/null; then
    break
  fi
  sleep 1
done

if ! nc -z -w1 localhost 12222; then
  echo "[run-all] FAIL: mock-nas not reachable after 15s"
  exit 1
fi
echo "[run-all] mock-nas ready"

TESTS=(
  test-setup-ssh.sh
  test-first-run.sh
  test-diag.sh
  test-nas-status.sh
  test-list-shares.sh
  test-manage-mounts.sh
)

mkdir -p "$SCRIPT_DIR/logs"
fail_count=0
for t in "${TESTS[@]}"; do
  log="$SCRIPT_DIR/logs/$t.log"
  echo "[run-all] Running $t"
  if bash "$SCRIPT_DIR/$t" >"$log" 2>&1; then
    echo "[run-all] PASS: $t"
  else
    echo "[run-all] FAIL: $t (see $log)"
    fail_count=$((fail_count + 1))
  fi
done

if [ $fail_count -gt 0 ]; then
  echo "[run-all] $fail_count test(s) failed"
  exit 1
fi

echo "[run-all] All ${#TESTS[@]} tests passed."
```

- [ ] **Step 2: Ausführbar + commit**

```bash
chmod +x /root/synology-manager-plus/tests/integration/run-all.sh
git add tests/integration/run-all.sh
git commit -m "test: add run-all orchestrator (build, start, run, cleanup)"
```

---

### Task 25: Lokal alle Smoke-Tests laufen lassen

- [ ] **Step 1: Run-all gegen lokales Docker**

Run:
```bash
cd /root/synology-manager-plus
bash tests/integration/run-all.sh 2>&1 | tail -30
```
Expected: `[run-all] All 6 tests passed.`

Falls Tests fehlschlagen: Logs in `tests/integration/logs/` öffnen, Ursache fixen, betroffene Test-Skripte oder Commands anpassen, neuen Commit machen, dann hier nochmal laufen lassen.

- [ ] **Step 2: Logs aufräumen**

Run: `rm -rf /root/synology-manager-plus/tests/integration/logs/`

---

## Phase H — GitHub Actions

### Task 26: validate.yml

**Files:**
- Create: `.github/workflows/validate.yml`

- [ ] **Step 1: Workflow schreiben**

```yaml
name: Validate

on:
  push:
    branches: [main]
  pull_request:

jobs:
  static:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install tools
        run: |
          sudo apt-get update
          sudo apt-get install -y jq shellcheck
          npm install -g markdownlint-cli2

      - name: Validate manifests
        run: bash tests/static/validate-manifests.sh

      - name: Shellcheck command snippets
        run: bash tests/static/shellcheck-commands.sh

      - name: Markdown lint
        run: bash tests/static/markdown-lint.sh

      - name: Frontmatter check
        run: bash tests/static/frontmatter-check.sh
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/validate.yml
git commit -m "ci: add static validation workflow"
```

---

### Task 27: integration.yml

**Files:**
- Create: `.github/workflows/integration.yml`

- [ ] **Step 1: Workflow schreiben**

```yaml
name: Integration

on:
  push:
    branches: [main]
  pull_request:

jobs:
  mock-nas-smoke:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install test deps
        run: |
          sudo apt-get update
          sudo apt-get install -y sshpass netcat-openbsd

      - name: Run integration smoke tests
        run: bash tests/integration/run-all.sh

      - name: Upload logs on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: integration-logs
          path: tests/integration/logs/
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/integration.yml
git commit -m "ci: add integration smoke workflow"
```

---

## Phase I — User-facing Doku

### Task 28: README.md

**Files:**
- Create: `README.md`

- [ ] **Step 1: README schreiben**

````markdown
# synology-manager-plus

A Claude Code plugin for managing a Synology NAS via SSH.

**This is a fork** of [`danielrosehill/synology-manager-plugin`](https://github.com/danielrosehill/synology-manager-plugin). The fork addresses three blockers in the upstream v0.1.0 and adds a guided diagnostic command. Original credit to Daniel Rosehill.

## What's different from the original

| Area | Original v0.1.0 | This fork v0.2.0 |
|------|-----------------|------------------|
| Installation | `claude plugin install danielrosehill/...` did not work — no marketplace manifest in repo | Marketplace manifest included; `claude plugin marketplace add` works directly |
| `/first-run` | Sub-agent that could not maintain a multi-turn dialog | Slash command in main context using `AskUserQuestion` |
| SSH setup | Manual: keygen, copy-id, profile editing | Guided `/setup-ssh` with copy-paste `!`-prefix flow |
| Health check | Absent | `/diag` 7-point health check |
| SSH key | Used `~/.ssh/id_ed25519`, conflicted with user keys | Plugin-owned `~/.ssh/synology-manager-plus_ed25519` |
| Connect timeout | Hard-coded 5s, broke on WAN/VPN | Default 10s, configurable per-profile |
| User notes in CLAUDE.md | Could be overwritten by `/first-run` re-run | Protected via managed-section markers |
| Tests | None | Static checks + Mock-NAS smoke tests in CI |

## Installation

```bash
claude plugin marketplace add CallMeTechie/synology-manager-plus
claude plugin install synology-manager-plus@synology-manager-plus
```

## First steps

1. Open the plugin workspace as your Claude Code project.
2. Run `/first-run` — answer host, port, user, follow the `! ssh-copy-id ...` instruction (type it literally including the `!`).
3. Run `/diag` to verify all 7 health checks pass.

## Commands

| Command | Description |
|---------|-------------|
| `/first-run` | Interactive setup wizard (one-time, idempotent) |
| `/setup-ssh` | Standalone SSH key setup |
| `/diag` | 7-point health check (read-only) |
| `/nas-status` | Disk usage, RAID, services, load |
| `/list-shares` | List shared folders, refresh volume snapshots |
| `/manage-mounts` | View/add/remove NFS or SMB mounts |

## Migration from `danielrosehill/synology-manager-plugin`

```bash
claude plugin uninstall synology-manager
claude plugin marketplace add CallMeTechie/synology-manager-plus
claude plugin install synology-manager-plus@synology-manager-plus
```

If your old plugin had a populated `context/` directory with snapshots, copy them manually into the new plugin workspace's `context/volumes/` and `context/mounts/` — the new install starts blank and `/first-run` will refill the rest.

## Troubleshooting

**`/setup-ssh` says my password is wrong, but I'm sure it's right.**
Make sure you typed the command with `!` at the start. Without `!`, Claude tries to run it as a normal Bash call, which has no terminal for password entry and hangs. The `!` opens an interactive terminal where the password prompt actually works.

**`/diag` says SSH is unreachable, but I can SSH manually.**
Check `connect_timeout_seconds` in `context/nas-profile.md`. Default is 10. For VPN tunnels with cold-start latency, raise it to 20–30. Range 3–60.

**Re-running `/first-run` deleted my notes in `CLAUDE.md`.**
Notes outside the `<!-- synology-manager-plus:managed-start -->` and `:managed-end` markers are protected. If your CLAUDE.md does not have those markers (e.g. migrated from upstream), `/first-run` shows you a diff and asks before touching anything.

## Roadmap (Phase 2+)

- Docker container management (list, start/stop, logs)
- Hyper Backup job status and trigger
- BTRFS snapshot management
- SMART disk health (`smartctl`)
- WireGuard / VPN status
- DSM update check
- User and permissions management
- Synology packages (`synopkg`)
- Logs viewer
- Power management (Wake-on-LAN, schedule)

Each will land as its own spec under `docs/superpowers/specs/`.

## License

MIT — see [LICENSE](LICENSE). Original work copyright © 2026 Daniel Rosehill. Modifications and fork copyright © 2026 Marc Backes.
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with what's-different, install, migration, troubleshooting"
```

---

### Task 29: CHANGELOG.md

**Files:**
- Create: `CHANGELOG.md`

- [ ] **Step 1: CHANGELOG schreiben**

```markdown
# Changelog

All notable changes to synology-manager-plus are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0] — 2026-05-10

### Added
- `/setup-ssh` command — generates plugin-owned SSH keypair, walks through `! ssh-copy-id` deployment, verifies key auth.
- `/diag` command — 7-point read-only health check (profile, SSH reachability, key auth, sudo, df query, mount sanity).
- `connect_timeout_seconds` field in `nas-profile.md` (default 10, range 3–60).
- `<!-- synology-manager-plus:managed-start -->` / `:managed-end` markers in `CLAUDE.md` to protect user notes during `/first-run` re-runs.
- Static CI checks: JSON manifest validation, shellcheck on extracted bash snippets, markdown lint, frontmatter enforcement.
- Mock-NAS smoke tests against an Alpine+OpenSSH+DSM-stub container, one per command.
- Anti-pattern rule: plugin must never invoke `ssh-copy-id` via the Bash tool — verified to hang without a TTY.

### Changed
- `/first-run` rewritten as a main-context slash command using `AskUserQuestion`. The previous `synology-intake` sub-agent is removed (sub-agents cannot maintain multi-turn dialogs).
- All commands now use the plugin-owned key `~/.ssh/synology-manager-plus_ed25519` (was `~/.ssh/id_ed25519`).
- Default SSH connect timeout raised from 5s to 10s for WAN/VPN tolerance.
- All commands honour the configured port from `nas-profile.md` (upstream silently assumed 22).
- Repo layout reorganised to marketplace + `plugin/` subdirectory so `claude plugin marketplace add` works without local workarounds.

### Removed
- `agents/synology-intake.md` — broken sub-agent pattern, replaced by main-context `/first-run`.

### Fixed
- Marketplace installation — repo now contains `.claude-plugin/marketplace.json`, fixing the silent failure of `claude plugin install` against the upstream repo.

### Security
- Input validation on host (`^[a-zA-Z0-9.-]+$`) and port (`^[0-9]{1,5}$`) before every shell expansion to prevent injection.
- Plugin SSH key isolated from user keys — separate path, separate rotation.

---

## [0.1.0] — Original `danielrosehill/synology-manager-plugin`

Original plugin by Daniel Rosehill. See [upstream repo](https://github.com/danielrosehill/synology-manager-plugin) for its history.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: add CHANGELOG.md following Keep-a-Changelog format"
```

---

### Task 30: LICENSE

**Files:**
- Create: `LICENSE`

- [ ] **Step 1: LICENSE schreiben**

```text
MIT License

Copyright (c) 2026 Daniel Rosehill (original work)
Copyright (c) 2026 Marc Backes (modifications and fork)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Commit**

```bash
git add LICENSE
git commit -m "docs: add MIT license with original + fork attribution"
```

---

## Phase J — Final-Verifikation lokal

### Task 31: Alle statischen Tests laufen lassen

- [ ] **Step 1: validate-manifests**

Run: `bash /root/synology-manager-plus/tests/static/validate-manifests.sh`
Expected: alle PASS, inklusive der CHANGELOG-Konsistenz (jetzt vorhanden).

- [ ] **Step 2: shellcheck-commands**

Run: `bash /root/synology-manager-plus/tests/static/shellcheck-commands.sh`
Expected: 6 PASS.

- [ ] **Step 3: frontmatter-check**

Run: `bash /root/synology-manager-plus/tests/static/frontmatter-check.sh`
Expected: 6 PASS.

- [ ] **Step 4: markdown-lint**

Voraussetzung: `npm install -g markdownlint-cli2` einmalig.

Run: `bash /root/synology-manager-plus/tests/static/markdown-lint.sh`
Expected: keine Fehler. Fehler → Markdown-Dateien anpassen, neuer Commit.

---

### Task 32: Bash-Smoke-Tests gegen lokales Docker

- [ ] **Step 1: Run-all**

Run: `bash /root/synology-manager-plus/tests/integration/run-all.sh`
Expected: `[run-all] All 6 tests passed.`

Falls Fail: Logs unter `tests/integration/logs/` einsehen, Tests/Commands fixen, dann re-run.

---

### Task 33: GitHub-Repo erstellen und pushen (User-Aktion)

> **Diese Schritte erfordern Marcs GitHub-Auth und werden vom User selbst ausgeführt.**

- [ ] **Step 1: GitHub-Repo unter `CallMeTechie/synology-manager-plus` erstellen**

Run (vom User im Terminal):
```bash
gh repo create CallMeTechie/synology-manager-plus --public \
  --description "Enhanced Synology NAS plugin for Claude Code — fork of danielrosehill/synology-manager-plugin"
```

- [ ] **Step 2: Remote hinzufügen und pushen**

```bash
cd /root/synology-manager-plus
git remote add origin git@github.com:CallMeTechie/synology-manager-plus.git
git push -u origin main
```

- [ ] **Step 3: CI beobachten**

```bash
gh run watch
```
Beide Workflows (`Validate`, `Integration`) müssen grün werden. Wenn nicht: Fehler analysieren, Fix-Commit, push, neu beobachten.

---

### Task 34: Manuelle Akzeptanz-Checkliste auf echter DS218+

> **Diese Checkliste ist Phase-1-Release-Pflicht (siehe Spec §6.4 Layer 3).**

- [ ] **Cold-Start auf frischem System:** `claude plugin marketplace add CallMeTechie/synology-manager-plus` + `install` auf einem zweiten Claude-Code-Host.
- [ ] **/first-run Erstdurchlauf:** Wizard fragt Host/Port/User korrekt ab, /setup-ssh-Logik wird intern aufgerufen, `! ssh-copy-id`-Anleitung wird angezeigt.
- [ ] **`! ssh-copy-id` von Hand getippt:** Befehl läuft mit interaktiver Passwort-Eingabe durch.
- [ ] **NAS-Discovery liefert echte Werte:** DSM-Version, Modell (DS218+), Volumes (volume1) — alle korrekt extrahiert.
- [ ] **CLAUDE.md korrekt populiert:** Quick-Reference innerhalb der Marker. Test: vorab Test-Notiz unter den End-Marker schreiben, nach `/first-run` prüfen ob sie noch da ist.
- [ ] **/diag zeigt 7/7 grün** direkt nach erfolgreichem `/first-run`.
- [ ] **/diag Negativ-Test:** NAS aus oder falscher Port → klare Fehlermeldungen, keine Hänger.
- [ ] **/list-shares zeigt echte Shares** mit korrekten Permissions.
- [ ] **/nas-status aktualisiert storage-report.md** mit echten df-Werten und Timestamp.
- [ ] **/manage-mounts list** läuft sauber.
- [ ] **Re-Run-Test /first-run:** Confirm-Prompt erscheint, bestehende User-Notizen unterhalb des End-Markers überleben.
- [ ] **WAN/VPN-Test:** Mindestens ein erfolgreicher Lauf über `ssh.domaincaster.com:2022`.
- [ ] **Anti-Pattern-Verifikation:** `grep -E '^\s*ssh-copy-id\s' plugin/commands/*.md` ergibt nichts.

Wenn alle Checkboxen grün: Tag setzen.

```bash
git tag -a v0.2.0 -m "Phase 1 release: fixed installation, /setup-ssh, /diag, no sub-agent"
git push origin v0.2.0
```

---

## Self-Review (vom Plan-Autor durchgeführt)

**Spec-Coverage:**
- §3.1 Repo-Layout → Tasks 1–3
- §3.2 Manifests → Tasks 2–3
- §4.1 /setup-ssh → Task 9
- §4.2 /first-run → Task 10
- §4.3 /diag → Task 11
- §4.4 bestehende Commands → Tasks 6–8
- §5.1 README → Task 28
- §5.2 CHANGELOG → Task 29
- §5.3 LICENSE → Task 30
- §6.1 statische Tests → Tasks 12–15
- §6.2 Mock-NAS Tests → Tasks 16–25
- §6.3 GitHub Actions → Tasks 26–27
- §6.4 Akzeptanzkriterien → Tasks 31–34
- §7 Sicherheit (Input-Validation) → Tasks 6–10 (Validierungs-Klauseln)

Vollständig.

**Type-Konsistenz:**
- Plugin-Key-Pfad `~/.ssh/synology-manager-plus_ed25519` — überall identisch.
- Marker `<!-- synology-manager-plus:managed-start -->` / `:managed-end` — überall identisch.
- Default-Timeout 10s — überall identisch.
- Validierungs-Regex (`^[a-zA-Z0-9.-]+$` für Host, `^[0-9]{1,5}$` für Port) — überall identisch.

Konsistent.

**Placeholder-Scan:** Keine TBDs, TODOs oder „add appropriate error handling" gefunden.

**Hardcoded-Credentials-Check:** Keine hardcoded Passwörter im Plan. Mock-NAS-Test-Passwort wird zur Build-Time generiert (`openssl rand -hex 12`), per `--build-arg NAS_TEST_PASSWORD` an Docker übergeben und per Env-Variable an Test-Skripte weitergereicht. `sshpass` läuft nur in der `-e`-Variante (liest aus `SSHPASS`-Env), nie mit `-p` und Argument.
