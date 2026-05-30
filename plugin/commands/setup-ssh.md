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

First, resolve where to read and write the profile:

```bash
set -euo pipefail
if [ -f context/nas-profile.md ] && [ ! -d context/nas ]; then
  echo "Legacy single-NAS layout detected — run /first-run to upgrade before /setup-ssh." >&2
  exit 1
fi
ACTIVE=$(cat context/active-nas 2>/dev/null | head -1 || true)
ACTIVE="${ACTIVE%%[[:space:]]*}"
if [[ "$ACTIVE" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] && [ -f "context/nas/$ACTIVE/profile.md" ]; then
  SLUG="$ACTIVE"
else
  SLUG="main"   # fresh setup: first NAS
fi
TARGET_PROFILE="context/nas/$SLUG/profile.md"
mkdir -p "context/nas/$SLUG"
```

If `$TARGET_PROFILE` exists, extract `host`, `port`, `NAS_USER` (note: NOT `$USER` — that one is the local Linux login user and would silently shadow), and `CONNECT_TIMEOUT` from it:

```bash
HOST=$(awk '/^- host:/ {print $3; exit}' "$TARGET_PROFILE")
PORT=$(awk '/^- port:/ {print $3; exit}' "$TARGET_PROFILE")
NAS_USER=$(awk '/^- user:/ {print $3; exit}' "$TARGET_PROFILE")
CONNECT_TIMEOUT=$(awk '/^- connect_timeout_seconds:/ {print $3; exit}' "$TARGET_PROFILE")
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
```

If `$TARGET_PROFILE` does not exist, or if any extracted value is `_not configured_` or empty, prompt via `AskUserQuestion`:

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

- On success: write/update `$TARGET_PROFILE` (`context/nas/$SLUG/profile.md`) with:
  - `host`, `port`, `user`
  - `key_path: ~/.ssh/synology-manager-plus_ed25519`
  - `connect_timeout_seconds: 10` (only if missing — preserve existing override)
  - `Last Updated: <ISO 8601 UTC>`

  Then ensure `context/active-nas` contains `$SLUG` (atomic write):

  ```bash
  _smp_tmp=$(mktemp)
  printf '%s\n' "$SLUG" > "$_smp_tmp" && mv "$_smp_tmp" context/active-nas
  ```

- On failure: print a clear error listing the three most common causes:
  1. SSH service not enabled in DSM (Control Panel → Terminal & SNMP → Enable SSH).
  2. Wrong port — check DSM SSH settings.
  3. User does not exist on NAS or has no shell access.
  Suggest re-running `/setup-ssh`.

### 6. Confirm completion

Print: "Key auth verified. Run `/diag` to check overall health."
