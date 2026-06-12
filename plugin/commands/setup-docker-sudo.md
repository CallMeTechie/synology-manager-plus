---
description: Set up passwordless sudo for the docker binary on the active NAS via the DSM Task Scheduler, then verify and record the result.
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---

# Setup Docker Sudo

Re-runnable command that configures `NOPASSWD: /usr/local/bin/docker` for the active NAS user via the DSM Task Scheduler. Use it after a DSM update wipes `sudoers.d` drop-ins, or any time the `/compose-*` and `/docker-list` commands report "a password is required". The command probes the current state first and exits immediately if passwordless docker-sudo is already active.

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

## Set up docker-sudo

**Probe current state:**

```bash
DOCKER_INFO=$("${SSH[@]}" "sudo -n /usr/local/bin/docker info --format '{{.ServerVersion}}' 2>&1" || true)
case "$DOCKER_INFO" in
  [0-9]*\.[0-9]*) echo "Passwordless docker-sudo is already active."; exit 0 ;;
  *"command not found"*|*"No such file"*) echo "docker not found at /usr/local/bin/docker. Run 'which docker' on the NAS and adjust the path."; exit 1 ;;
esac
HOME_PATH=$("${SSH[@]}" "echo \$HOME")
IS_ADMIN=$("${SSH[@]}" "id -Gn 2>/dev/null | grep -qw administrators && echo admin || echo standard" || echo standard)
```

Configuring `NOPASSWD` on `/usr/local/bin/docker` is effectively granting root on the NAS — a container can mount `/` and escape the filesystem boundary. This scope cannot be narrowed without breaking compose, run, and exec workflows. If `IS_ADMIN=standard`, the DSM Task Scheduler is the only available delivery path; if `IS_ADMIN=admin`, it is still the recommended path (sudo itself requires a root-owned, root-written dropin in `/etc/sudoers.d`).

**Render the root script:**

```bash
SUDO_SCRIPT=$(cat <<EOF
#!/bin/sh
# synology-manager-plus: NOPASSWD only for the docker binary (effective root).
USER_NAME="$NAS_USER"
DOCKER_BIN="/usr/local/bin/docker"
DROPIN="/etc/sudoers.d/synology-manager-plus-docker"
MARKER="$HOME_PATH/smp-sudo-setup.result"
LINE="\$USER_NAME ALL=(ALL) NOPASSWD: \$DOCKER_BIN"
fail() { echo "rc=1 stage=\$1 msg=\$2" > "\$MARKER"; chmod 0644 "\$MARKER" 2>/dev/null; exit 1; }
printf '%s' "\$USER_NAME" | grep -qE '^[A-Za-z0-9_.@-]+\$' || fail validate "username unsafe for sudoers"
grep -Eq '^[@#]includedir[[:space:]]+"?/etc/sudoers\.d' /etc/sudoers \\
  || fail includedir "/etc/sudoers includes no /etc/sudoers.d"
TMP="\$(mktemp /etc/sudoers.d/.smp-XXXXXX)" || fail mktemp "mktemp unavailable"
printf '%s\n' "\$LINE" > "\$TMP"
if command -v visudo >/dev/null 2>&1; then
  visudo -cf "\$TMP" || { rm -f "\$TMP"; fail visudo "syntax check failed"; }
  VALIDATED=yes
else
  VALIDATED=no
fi
chown root:root "\$TMP" && chmod 0440 "\$TMP" || { rm -f "\$TMP"; fail perms "chown/chmod failed"; }
mv -f "\$TMP" "\$DROPIN" || { rm -f "\$TMP"; fail install "rename to sudoers.d failed"; }
echo "rc=0 stage=done validated=\$VALIDATED user=\$USER_NAME bin=\$DOCKER_BIN" > "\$MARKER"
chmod 0644 "\$MARKER" 2>/dev/null
echo "OK: NOPASSWD for \$USER_NAME -> \$DOCKER_BIN active."
EOF
)
```

**Choose delivery (use `AskUserQuestion`):**

Present **"Paste full script (recommended)"** as the safer default — no upload-then-execute window; the user sees the exact script that runs as root. Print `$SUDO_SCRIPT` and write a reference copy:

```bash
mkdir -p "context/nas/$SLUG"
printf '%s\n' "$SUDO_SCRIPT" > "context/nas/$SLUG/setup-docker-sudo.sh"
```

For **"Upload + one-liner (trusted environments only)"**: state the privilege-escalation caveat — the file is owned and writable by the SSH user but executed as root by the scheduled task; a process running as that user could replace its contents in the window between upload and execution. `chmod 0700` limits but does not close this (the file owner can re-add write permission). Prefer paste unless the NAS is single-user/trusted:

```bash
printf '%s\n' "$SUDO_SCRIPT" | "${SSH[@]}" "cat > '$HOME_PATH/smp-setup-docker-sudo.sh' && chmod 0700 '$HOME_PATH/smp-setup-docker-sudo.sh'"
echo "Task Scheduler 'Run command':  bash $HOME_PATH/smp-setup-docker-sudo.sh"
```

**Delete any stale result marker BEFORE the user runs the task:**

```bash
"${SSH[@]}" "rm -f '$HOME_PATH/smp-sudo-setup.result'" || true
```

**Print the GUI steps** and wait via `AskUserQuestion` "Done — verify now?":

> Control Panel → Task Scheduler → Create → Scheduled Task → User-defined script. User: **root**. Task Settings → paste the script (or the one-liner). Save → select the task → **Run** → confirm. You may delete the task afterwards.

**Verify:**

```bash
MARKER_OUT=$("${SSH[@]}" "cat '$HOME_PATH/smp-sudo-setup.result' 2>/dev/null" || true)
OK=no
for i in 1 2 3; do
  P=$("${SSH[@]}" "sudo -n /usr/local/bin/docker info --format '{{.ServerVersion}}' 2>&1" || true)
  case "$P" in [0-9]*\.[0-9]*) OK=yes; break ;; esac
  sleep 2
done
```

On `OK=yes`, atomically update the active profile's sudo fields and refresh CLAUDE.md:

```bash
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp=$(mktemp)
awk -v ts="$TS" '
  /^- sudo_passwordless:/ { print "- sudo_passwordless: yes"; next }
  /^- sudo_checked_at:/   { print "- sudo_checked_at: " ts; next }
  { print }
' "$PROFILE" > "$tmp" && mv "$tmp" "$PROFILE"
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
render_claude_md "$SLUG"
echo "Passwordless docker-sudo is now active on '$SLUG'."
```

On `OK=no`:

- No marker found → The task was not run, or was not run as root (most common cause). Verify in Task Scheduler that the user is set to **root**, not the login user.
- Marker present with `rc=1` → Show the real error from the `stage=` and `msg=` fields in `$MARKER_OUT`.
- Marker present with `rc=0` but probe still fails → Diagnose in order: was the task run as root? Is `validated=no` in the marker (no visudo on this DSM)? Does the dropin user match `$NAS_USER`? Is the `/etc/sudoers` includedir directive active? Is `/usr/local/bin/docker` the correct path and is the daemon running?
