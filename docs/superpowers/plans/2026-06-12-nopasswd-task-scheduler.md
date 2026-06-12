# Passwortloses Docker-sudo via DSM-Aufgabenplaner — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** First-run und ein neues `/setup-docker-sudo` richten passwortloses `sudo` für das Docker-Binary auf der NAS ein, indem sie ein sicheres root-Skript für den DSM-Aufgabenplaner generieren, den User durch die GUI führen und das Ergebnis selbst verifizieren.

**Architecture:** Eine kanonische, unit-getestete Lib `_sudo-lib.sh` (reine Klassifizierungs- + Skript-Render-Funktionen) ist die Source of Truth. Da CC-Plugin-Commands Libs nicht zur Laufzeit sourcen können, betten `first-run.md` und das neue `setup-docker-sudo.md` einen Inline-Mirror ein. Das generierte root-Skript ist busybox-tauglich, validiert via `visudo` (falls vorhanden), aktiviert das Drop-in per atomarem Same-FS-rename und schreibt einen vom Plugin lesbaren Result-Marker.

**Tech Stack:** Bash (shellcheck-clean), Markdown-Command-Files mit YAML-Frontmatter, bestehende Test-Harness (`tests/unit/test-*.sh` per Glob vom Runner erfasst, `tests/static/*` Validatoren).

---

## Spec

Basiert auf `docs/superpowers/specs/2026-06-12-nopasswd-task-scheduler-design.md`. Bei Unklarheiten ist die Spec maßgeblich.

## Aufgelöste Entscheidungen (aus „Im Plan zu klären")

1. **Zwei Klassifizierer — bewusst getrennt.** `_compose-lib.sh::docker_daemon_precheck` behält seinen `return 0/1`-Kontrakt (Fast-Path-Gate für alle `/compose-*`-Commands); nur sein Fix-Hinweis-Text wird auf `/setup-docker-sudo` umgestellt. Die neue `smp_docker_sudo_probe` (Status-String) ist der Setup-Zeit-Klassifizierer. **Nicht** den precheck umschreiben (er ist von 6 Commands genutzt; Kontrakt-Bruch-Risiko). Beide rufen dasselbe `sudo -n /usr/local/bin/docker info` auf.
2. **`set -e`-Sicherheit.** `smp_docker_sudo_probe` kapselt die SSH-Ausgabe mit `|| true` und klassifiziert via `if/elif grep -q` (grep-Exit in einer `if`-Bedingung löst `set -e` nicht aus). Der Inline-Setup-Flow in `first-run.md` ruft die Probe so, dass kein nackter Nicht-Null-Exit den Wizard abbricht.
3. **`home_path` live, nicht persistiert.** first-run ermittelt ihn via neuem `discover home "echo \$HOME"`; `/setup-docker-sudo` probt live. Kein Profilfeld.

## File Structure

| Datei | Verantwortung |
| - | - |
| `plugin/commands/_sudo-lib.sh` | **neu.** Kanonisch, unit-getestet. Reine Funktionen: `smp_classify_docker_info`, `smp_docker_sudo_probe`, `smp_render_sudoers_script`, `smp_user_is_admin_probe`. |
| `tests/unit/test-sudo-lib.sh` | **neu.** Unit-Tests der vier Lib-Funktionen. Vom Runner per Glob erfasst. |
| `plugin/commands/setup-docker-sudo.md` | **neu.** Eigenständiges Command. Inline-Mirror der Lib + interaktiver Setup-Flow. |
| `plugin/commands/first-run.md` | Probe-Fix; `discover home`; Schema-Feld `sudo_checked_at`; neuer Step 8 (Inline-Setup-Flow nach atomarem Profil-Write). |
| `plugin/commands/nas-add.md` | Probe-Fix (gleiche Semantik wie first-run). |
| `plugin/commands/_compose-lib.sh` | Fix-Hinweis-Text → Verweis auf `/setup-docker-sudo`. |
| `plugin/CLAUDE.md` | `/setup-docker-sudo` in Command-Tabelle. |
| `README.md` | Command-Zeile + Troubleshooting-Eintrag. |
| `CHANGELOG.md` | `0.8.0`-Eintrag. |

**Konventionen, die jede Datei einhalten muss:**
- Docker über SSH **immer** als literaler `/usr/local/bin/docker` (der `docker-abspath-check` flaggt `$docker info`-Variablen als bare-docker-Bug — daher literal, nie via Pfad-Variable im `info`-Aufruf).
- Command-`.md`: Frontmatter mit `description:` (20–200 Zeichen) + `allowed-tools:` nur aus `{Bash, Read, Write, Edit, AskUserQuestion}`.
- Bash shellcheck-clean; Namerefs mit `# shellcheck disable=SC2178`.

---

## Task 1: `_sudo-lib.sh` anlegen + `smp_classify_docker_info`

**Files:**
- Create: `plugin/commands/_sudo-lib.sh`
- Test: `tests/unit/test-sudo-lib.sh`

- [ ] **Step 1: Failing test schreiben**

Create `tests/unit/test-sudo-lib.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="sudo-lib"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT/plugin/commands/_sudo-lib.sh"

pass_count=0
fail_count=0

check_eq() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo "PASS: $label"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: $label — expected '$expected', got '$actual'"
    fail_count=$((fail_count + 1))
  fi
}

# --- smp_classify_docker_info ---
check_eq "classify ok"            "$(smp_classify_docker_info '24.0.2')"                                  "ok"
check_eq "classify pwd"           "$(smp_classify_docker_info 'sudo: a password is required')"            "password-required"
check_eq "classify daemon-down"   "$(smp_classify_docker_info 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock')" "daemon-down"
check_eq "classify not-found"     "$(smp_classify_docker_info 'sudo: /usr/local/bin/docker: command not found')" "not-found"
check_eq "classify unknown"       "$(smp_classify_docker_info 'some weird output')"                       "unknown"

echo ""
echo "=== test-sudo-lib: $pass_count pass, $fail_count fail ==="
[ "$fail_count" -eq 0 ]
```

- [ ] **Step 2: Test laufen lassen — muss fehlschlagen**

Run: `bash tests/unit/test-sudo-lib.sh`
Expected: FAIL — `_sudo-lib.sh` existiert nicht (`source: No such file`).

- [ ] **Step 3: Lib mit `smp_classify_docker_info` anlegen**

Create `plugin/commands/_sudo-lib.sh`:

```bash
#!/usr/bin/env bash
# Shared helpers for passwordless docker-sudo setup. Canonical, unit-tested.
# Commands CANNOT source libs at runtime — first-run.md and setup-docker-sudo.md
# embed inline mirrors of these functions. Keep them in sync.
# Run shellcheck directly: `shellcheck _sudo-lib.sh`.

# smp_classify_docker_info <raw-output>
# Pure: maps the output of `sudo -n /usr/local/bin/docker info` (or its error
# text) to exactly one status token on stdout:
#   ok | password-required | daemon-down | not-found | unknown
smp_classify_docker_info() {
  local out="$1"
  if printf '%s' "$out" | grep -q '^[0-9][0-9]*\.[0-9]'; then
    echo ok
  elif printf '%s' "$out" | grep -qi 'a password is required'; then
    echo password-required
  elif printf '%s' "$out" | grep -qi 'cannot connect to the .* daemon'; then
    echo daemon-down
  elif printf '%s' "$out" | grep -qiE 'command not found|no such file'; then
    echo not-found
  else
    echo unknown
  fi
}
```

- [ ] **Step 4: Test laufen lassen — muss bestehen**

Run: `bash tests/unit/test-sudo-lib.sh`
Expected: PASS — `5 pass, 0 fail`.

- [ ] **Step 5: shellcheck**

Run: `shellcheck plugin/commands/_sudo-lib.sh`
Expected: keine Ausgabe (exit 0).

- [ ] **Step 6: Commit**

```bash
git add plugin/commands/_sudo-lib.sh tests/unit/test-sudo-lib.sh
git commit -m "feat: add _sudo-lib with docker-info classifier"
```

---

## Task 2: `smp_docker_sudo_probe` (SSH-Wrapper + set-e-sicher)

**Files:**
- Modify: `plugin/commands/_sudo-lib.sh`
- Test: `tests/unit/test-sudo-lib.sh`

- [ ] **Step 1: Failing test ergänzen**

In `tests/unit/test-sudo-lib.sh`, vor der `echo ""`-Abschlusszeile einfügen:

```bash
# --- smp_docker_sudo_probe (SSH array via nameref; stubbed) ---
# The probe runs "${SSH[@]}" "<cmd>". A bash function as the array element
# receives the command string as $1 and ignores it, returning canned output.
stub_ok()  { echo "24.0.2"; }
stub_pwd() { echo "sudo: a password is required"; }
SSH_OK=( stub_ok );  check_eq "probe ok"  "$(smp_docker_sudo_probe SSH_OK)"  "ok"
SSH_PW=( stub_pwd ); check_eq "probe pwd" "$(smp_docker_sudo_probe SSH_PW)"  "password-required"

# set -e safety: a failing SSH (non-zero) must not abort the caller.
stub_fail() { echo "boom"; return 1; }
SSH_FAIL=( stub_fail ); check_eq "probe unknown on fail" "$(smp_docker_sudo_probe SSH_FAIL)" "unknown"
```

- [ ] **Step 2: Test laufen lassen — muss fehlschlagen**

Run: `bash tests/unit/test-sudo-lib.sh`
Expected: FAIL — `smp_docker_sudo_probe: command not found`.

- [ ] **Step 3: Funktion zur Lib hinzufügen**

In `plugin/commands/_sudo-lib.sh` anhängen:

```bash
# smp_docker_sudo_probe <ssh-array-name>
# Runs 'sudo -n /usr/local/bin/docker info' over the named SSH array and echoes
# one status token (see smp_classify_docker_info). The docker path is the literal
# /usr/local/bin/docker — the abspath regression guard forbids a path variable,
# and the entire codebase hardcodes this path; a non-standard path surfaces as
# 'not-found'. set -e safe: never returns non-zero, never aborts the caller.
smp_docker_sudo_probe() {
  local ssh_var="$1"
  # shellcheck disable=SC2178
  local -n ssh_ref="$ssh_var"
  local out
  out=$("${ssh_ref[@]}" "sudo -n /usr/local/bin/docker info --format '{{.ServerVersion}}' 2>&1" || true)
  smp_classify_docker_info "$out"
}
```

- [ ] **Step 4: Test laufen lassen — muss bestehen**

Run: `bash tests/unit/test-sudo-lib.sh`
Expected: PASS — `8 pass, 0 fail`.

- [ ] **Step 5: shellcheck**

Run: `shellcheck plugin/commands/_sudo-lib.sh`
Expected: keine Ausgabe.

- [ ] **Step 6: Commit**

```bash
git add plugin/commands/_sudo-lib.sh tests/unit/test-sudo-lib.sh
git commit -m "feat: add smp_docker_sudo_probe over SSH"
```

---

## Task 3: `smp_render_sudoers_script`

**Files:**
- Modify: `plugin/commands/_sudo-lib.sh`
- Test: `tests/unit/test-sudo-lib.sh`

- [ ] **Step 1: Failing test ergänzen**

In `tests/unit/test-sudo-lib.sh`, vor der `echo ""`-Abschlusszeile einfügen:

```bash
# --- smp_render_sudoers_script ---
SCRIPT="$(smp_render_sudoers_script 'svc' '/usr/local/bin/docker' '/var/services/homes/svc')"
contains() { case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac; }
check_eq "render: username interpolated"   "$(contains 'USER_NAME="svc"' "$SCRIPT")" "yes"
check_eq "render: marker absolute path"    "$(contains 'MARKER="/var/services/homes/svc/smp-sudo-setup.result"' "$SCRIPT")" "yes"
check_eq "render: no tilde in marker"      "$(contains 'MARKER="~' "$SCRIPT")" "no"
check_eq "render: dropin name no dot"      "$(contains 'DROPIN="/etc/sudoers.d/synology-manager-plus-docker"' "$SCRIPT")" "yes"
check_eq "render: temp in sudoers.d"       "$(contains 'mktemp /etc/sudoers.d/.smp-XXXXXX' "$SCRIPT")" "yes"
check_eq "render: conditional visudo"      "$(contains 'command -v visudo' "$SCRIPT")" "yes"
check_eq "render: mode 0440"               "$(contains 'chmod 0440' "$SCRIPT")" "yes"
check_eq "render: includedir check"        "$(contains 'includedir' "$SCRIPT")" "yes"
check_eq "render: includedir allows quote" "$(contains 'includedir[[:space:]]+"?/etc/sudoers' "$SCRIPT")" "yes"
check_eq "render: username sanitize"       "$(contains 'username unsafe for sudoers' "$SCRIPT")" "yes"
check_eq "render: success marker rc=0"     "$(contains 'rc=0 stage=done' "$SCRIPT")" "yes"
```

- [ ] **Step 2: Test laufen lassen — muss fehlschlagen**

Run: `bash tests/unit/test-sudo-lib.sh`
Expected: FAIL — `smp_render_sudoers_script: command not found`.

- [ ] **Step 3: Funktion zur Lib hinzufügen**

In `plugin/commands/_sudo-lib.sh` anhängen (heredoc: `$user`/`$docker`/`$home` werden interpoliert, `\$…` bleiben im generierten Skript literal):

```bash
# smp_render_sudoers_script <username> <docker_path> <home_path>
# Echoes the root setup script for the DSM Task Scheduler. The script:
#  - fails early (with a result marker) if /etc/sudoers does not include sudoers.d
#  - creates the temp file INSIDE /etc/sudoers.d (dot-prefixed -> ignored) so the
#    final `mv` is an atomic same-fs rename (no half-written-line lockout window)
#  - validates with visudo if present, recording validated=yes/no in the marker
#  - writes a plugin-readable result marker (rc/stage/validated) to <home>/...
smp_render_sudoers_script() {
  local user="$1" docker="$2" home="$3"
  cat <<EOF
#!/bin/sh
# synology-manager-plus: NOPASSWD only for the docker binary (effective root).
USER_NAME="$user"
DOCKER_BIN="$docker"
DROPIN="/etc/sudoers.d/synology-manager-plus-docker"
MARKER="$home/smp-sudo-setup.result"
LINE="\$USER_NAME ALL=(ALL) NOPASSWD: \$DOCKER_BIN"

fail() { echo "rc=1 stage=\$1 msg=\$2" > "\$MARKER"; chmod 0644 "\$MARKER" 2>/dev/null; exit 1; }

# Defense-in-depth for the no-visudo case: reject a username that would produce a
# syntactically invalid sudoers line (an invalid drop-in can break sudo system-wide).
printf '%s' "\$USER_NAME" | grep -qE '^[A-Za-z0-9_.@-]+\$' \\
  || fail validate "username unsafe for sudoers"

# Accept both modern @includedir and legacy #includedir, quoted or unquoted path.
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
}
```

- [ ] **Step 4: Test laufen lassen — muss bestehen**

Run: `bash tests/unit/test-sudo-lib.sh`
Expected: PASS — `19 pass, 0 fail`.

- [ ] **Step 5: Erzeugtes Skript ist syntaktisch gültiges sh**

Run: `bash -n <(source plugin/commands/_sudo-lib.sh; smp_render_sudoers_script svc /usr/local/bin/docker /home/svc)`
Expected: keine Ausgabe (exit 0) — Skript parst sauber.

- [ ] **Step 6: shellcheck**

Run: `shellcheck plugin/commands/_sudo-lib.sh`
Expected: keine Ausgabe.

- [ ] **Step 7: Commit**

```bash
git add plugin/commands/_sudo-lib.sh tests/unit/test-sudo-lib.sh
git commit -m "feat: add smp_render_sudoers_script (atomic, busybox-safe, marker)"
```

---

## Task 4: `smp_user_is_admin_probe`

**Files:**
- Modify: `plugin/commands/_sudo-lib.sh`
- Test: `tests/unit/test-sudo-lib.sh`

- [ ] **Step 1: Failing test ergänzen**

In `tests/unit/test-sudo-lib.sh`, vor der `echo ""`-Abschlusszeile einfügen:

```bash
# --- smp_user_is_admin_probe ---
check_eq "admin probe snippet" "$(smp_user_is_admin_probe)" \
  "id -Gn 2>/dev/null | grep -qw administrators && echo admin || echo standard"
```

- [ ] **Step 2: Test laufen lassen — muss fehlschlagen**

Run: `bash tests/unit/test-sudo-lib.sh`
Expected: FAIL — `smp_user_is_admin_probe: command not found`.

- [ ] **Step 3: Funktion zur Lib hinzufügen**

In `plugin/commands/_sudo-lib.sh` anhängen:

```bash
# smp_user_is_admin_probe
# Echoes the remote shell snippet (to run over SSH) that prints 'admin' if the
# SSH user is in the DSM administrators group, else 'standard'. Used to tailor
# the setup messaging (Task Scheduler mandatory vs. recommended).
smp_user_is_admin_probe() {
  printf '%s' "id -Gn 2>/dev/null | grep -qw administrators && echo admin || echo standard"
}
```

- [ ] **Step 4: Test laufen lassen — muss bestehen**

Run: `bash tests/unit/test-sudo-lib.sh`
Expected: PASS — `20 pass, 0 fail`.

- [ ] **Step 5: shellcheck**

Run: `shellcheck plugin/commands/_sudo-lib.sh`
Expected: keine Ausgabe.

- [ ] **Step 6: Commit**

```bash
git add plugin/commands/_sudo-lib.sh tests/unit/test-sudo-lib.sh
git commit -m "feat: add smp_user_is_admin_probe"
```

---

## Task 5: `first-run.md` — Probe-Fix, `discover home`, Schema-Feld

**Files:**
- Modify: `plugin/commands/first-run.md` (Discovery-Block ~Z. 144-146; Profil-Schema ~Z. 210-214)

- [ ] **Step 1: Discovery um `home` ergänzen und Sudo-Probe fixen**

In `plugin/commands/first-run.md`, im Discovery-Block (nach der `DOCKER_OK=`-Zeile) den `SUDO_OK`-Block ersetzen. Alt:

```bash
SUDO_OK=$(discover sudo "sudo -n true 2>/dev/null && echo yes || echo no")
```

Neu (literaler Docker-Pfad wegen abspath-check; an `DOCKER_OK` gekoppelt; `discover home` ergänzt):

```bash
HOME_PATH=$(discover home "echo \$HOME")
if [ "$DOCKER_OK" = "not installed" ]; then
  SUDO_OK="n/a"
else
  SUDO_OK=$(discover sudo "sudo -n /usr/local/bin/docker info >/dev/null 2>&1 && echo yes || echo no")
fi
```

- [ ] **Step 2: Profil-Schema um `sudo_checked_at` erweitern**

Im `## Software`-Block des Profil-Markdown-Templates (Z. ~210-214) die Sudo-Zeile ergänzen. Alt:

```markdown
- docker_available: <DOCKER_OK>
- sudo_passwordless: <SUDO_OK>
```

Neu:

```markdown
- docker_available: <DOCKER_OK>
- sudo_passwordless: <SUDO_OK>
- sudo_checked_at: <ISO 8601 UTC>
```

- [ ] **Step 3: Statische Checks**

Run: `bash tests/static/docker-abspath-check.sh`
Expected: `All command files invoke docker via /usr/local/bin/docker.`

Run: `bash tests/static/shellcheck-commands.sh && bash tests/static/markdown-lint.sh && bash tests/static/frontmatter-check.sh`
Expected: alle PASS / exit 0.

- [ ] **Step 4: Commit**

```bash
git add plugin/commands/first-run.md
git commit -m "fix: probe docker-specific passwordless sudo, discover \$HOME"
```

---

## Task 6: `first-run.md` — Step 8 Inline-Setup-Flow

**Files:**
- Modify: `plugin/commands/first-run.md` (neuer Abschnitt nach Step 7 „Write context files", vor Step 8 „Summary")

Der atomare Profil-Write (Step 7) bleibt **vor** diesem Flow — Resumability. Der bisherige `### 8. Summary` wird zu `### 9. Summary`.

- [ ] **Step 1: Neuen Step 8 einfügen**

In `plugin/commands/first-run.md` zwischen Step 7 und der Summary einfügen:

````markdown
### 8. Set up passwordless docker-sudo (only if needed)

Gate: only run this if Docker is installed AND passwordless sudo is not yet active.
Skip entirely otherwise. The profile is already written (Step 7) with
`sudo_passwordless: no`, so abandoning this step mid-way leaves a complete,
correct profile — `/setup-docker-sudo` can finish it later.

```bash
# Re-probe live (set -e safe). $SSH is the discovery SSH array from Step 5.
if [ "$DOCKER_OK" != "not installed" ]; then
  PROBE=$("${SSH[@]}" "sudo -n /usr/local/bin/docker info --format '{{.ServerVersion}}' 2>&1" || true)
  case "$PROBE" in
    [0-9]*\.[0-9]*) NEED_SETUP=no ;;   # already ok (literal dot)
    *)              NEED_SETUP=yes ;;
  esac
else
  NEED_SETUP=no
fi
```

If `NEED_SETUP=no` → skip to Step 9.

If `NEED_SETUP=yes`, run the shared setup flow. **This is an inline mirror of
`_sudo-lib.sh` — keep it identical to the canonical functions.** Tell the user
plainly: passwordless sudo for `/usr/local/bin/docker` is effectively root on the
NAS; we set it via the Task Scheduler (you run it, not me).

1. Detect the user model and render the script:

```bash
IS_ADMIN=$("${SSH[@]}" "id -Gn 2>/dev/null | grep -qw administrators && echo admin || echo standard" || echo standard)
DROPIN_USER="$NAS_USER"
SUDO_SCRIPT=$(cat <<EOF
#!/bin/sh
# synology-manager-plus: NOPASSWD only for the docker binary (effective root).
USER_NAME="$DROPIN_USER"
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

2. Use `AskUserQuestion` to let the user choose the delivery mechanism. Present
   **"Paste full script" as the recommended/safer default** — it has no
   upload-then-execute window and the user sees exactly what runs as root.
   - "Paste full script (recommended)" — print `$SUDO_SCRIPT`, ask them to paste
     it into the Task Scheduler script box, AND write a reference copy to the
     workspace (spec requires both):

```bash
mkdir -p "context/nas/$nas_slug"
printf '%s\n' "$SUDO_SCRIPT" > "context/nas/$nas_slug/setup-docker-sudo.sh"
```

   - "Upload + one-liner (trusted environments only)" — upload the script to the
     user home over SSH and run it by ABSOLUTE path (never `~`, which is root's
     home under the task). **Security caveat to state to the user:** the uploaded
     file is owned and writable by the SSH user but executed as root, so a process
     running as that user could swap its contents in the window before the task
     runs (local privilege escalation). Prefer the paste option unless the NAS is
     single-user/trusted. `chmod 0700` limits exposure but does not close it
     (the owner can re-add write):

```bash
printf '%s\n' "$SUDO_SCRIPT" | "${SSH[@]}" "cat > '$HOME_PATH/smp-setup-docker-sudo.sh' && chmod 0700 '$HOME_PATH/smp-setup-docker-sudo.sh'"
echo "Task Scheduler 'Run command':  bash $HOME_PATH/smp-setup-docker-sudo.sh"
```

3. Delete any stale result marker BEFORE the user runs the task (proof-of-this-run;
   the user owns their home dir and may unlink the root-owned 0644 file):

```bash
"${SSH[@]}" "rm -f '$HOME_PATH/smp-sudo-setup.result'" || true
```

4. Print the GUI steps, then wait (AskUserQuestion "Done — verify now?"):
   > Control Panel → Task Scheduler → Create → Scheduled Task → User-defined script.
   > User: **root**. Task Settings → paste the script (or the one-liner). Save →
   > select the task → **Run** → confirm. You may delete the task afterwards.

5. Verify — read the marker, then re-probe with retries:

```bash
MARKER_OUT=$("${SSH[@]}" "cat '$HOME_PATH/smp-sudo-setup.result' 2>/dev/null" || true)
OK=no
for i in 1 2 3; do
  P=$("${SSH[@]}" "sudo -n /usr/local/bin/docker info --format '{{.ServerVersion}}' 2>&1" || true)
  case "$P" in [0-9]*\.[0-9]*) OK=yes; break ;; esac
  sleep 2
done
```

   - `OK=yes` → update the profile field `sudo_passwordless` to `yes` and refresh
     `sudo_checked_at` (atomic edit), then re-run `render_claude_md "$nas_slug"`.
   - `OK=no` and `$MARKER_OUT` contains `rc=1` → show the real error from
     `stage=`/`msg=` directly.
   - `OK=no` and no marker → "the task was not run, or not as root" (most common;
     state first).
   - `OK=no` and marker `rc=0` → diagnose by frequency: ran as root? `validated=no`?
     dropin user == `$NAS_USER`? includedir active? path/daemon.
````

- [ ] **Step 2: Summary-Überschrift umnummerieren**

In `plugin/commands/first-run.md`: `### 8. Summary` → `### 9. Summary`.

- [ ] **Step 3: Statische Checks**

Run: `bash tests/static/docker-abspath-check.sh`
Expected: `All command files invoke docker via /usr/local/bin/docker.`

Run: `bash tests/static/shellcheck-commands.sh && bash tests/static/markdown-lint.sh && bash tests/static/frontmatter-check.sh`
Expected: alle PASS / exit 0.

- [ ] **Step 4: Commit**

```bash
git add plugin/commands/first-run.md
git commit -m "feat: first-run sets up docker-sudo after atomic profile write"
```

---

## Task 7: `setup-docker-sudo.md` — eigenständiges Command

**Files:**
- Create: `plugin/commands/setup-docker-sudo.md`

- [ ] **Step 1: Command anlegen**

Create `plugin/commands/setup-docker-sudo.md` (Frontmatter-`description` 20–200 Zeichen; `allowed-tools` nur erlaubte). Der Profil-Resolver-Block ist der Inline-Mirror aus den anderen Commands (z. B. `docker-list.md:14-70` 1:1 übernehmen). Der Setup-Flow ist der Inline-Mirror von Task 6, Schritte 1–5, ohne das first-run-Gating:

````markdown
---
description: Set up passwordless sudo for the docker binary on the active NAS via the DSM Task Scheduler, then verify and record the result.
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---

# Setup Docker Sudo

Configures `NOPASSWD: /usr/local/bin/docker` on the active NAS so all `/compose-*`
and `/docker-list` commands work non-interactively. Re-runnable — DSM updates
periodically wipe `sudoers.d` drop-ins, and this command repairs them without a
full `/first-run`.

## Steps

### 1. Resolve the active NAS

Copy the standard profile-resolver block **verbatim** from any existing command
that has it (e.g. the block under `## SSH + ...` near the top of `docker-list.md`
or `compose-list.md` — identified by the comment `# Mirrors plugin/commands/_profile-lib.sh`).
It reads `context/active-nas` → loads `context/nas/<slug>/profile.md` → validates →
builds `SSH=( ssh -i "$KEY_PATH" -o ConnectTimeout="$CONNECT_TIMEOUT" -p "$PORT" "$NAS_USER@$HOST" )`.
Paste the real code here — do not leave a comment placeholder.

### 2. Probe current state

```bash
DOCKER_INFO=$("${SSH[@]}" "sudo -n /usr/local/bin/docker info --format '{{.ServerVersion}}' 2>&1" || true)
case "$DOCKER_INFO" in
  [0-9]*.[0-9]*)               echo "Passwordless docker-sudo is already active."; exit 0 ;;
  *"command not found"*|*"No such file"*) echo "docker not found at /usr/local/bin/docker. Run 'which docker' on the NAS and adjust."; exit 1 ;;
esac
HOME_PATH=$("${SSH[@]}" "echo \$HOME")
IS_ADMIN=$("${SSH[@]}" "id -Gn 2>/dev/null | grep -qw administrators && echo admin || echo standard" || echo standard)
```

### 3. Security note + render script

Tell the user plainly: `NOPASSWD` on `/usr/local/bin/docker` is effectively root on
the NAS (a container can mount `/`). It cannot be scoped narrower without breaking
compose/run/exec. If `IS_ADMIN=standard`, the Task Scheduler is the only way; if
`admin`, it is the recommended way.

Render the script (inline mirror of `smp_render_sudoers_script`, identical to
first-run Step 8.1, with `USER_NAME="$NAS_USER"` and `MARKER="$HOME_PATH/smp-sudo-setup.result"`).

### 4. Choose delivery (AskUserQuestion), delete stale marker, print GUI steps

Use the SAME blocks as first-run Task 6 Step 2/3/4 (copy them verbatim, with
`USER_NAME="$NAS_USER"`). **Note the slug variable differs:** here the active slug
is `$SLUG` (set by the resolver block, `SLUG="$ACTIVE"`), not first-run's `$nas_slug`.
- `AskUserQuestion` delivery choice — present **"Paste full script (recommended)"**
  as the safer default, and write the reference copy
  `printf '%s\n' "$SUDO_SCRIPT" > "context/nas/$SLUG/setup-docker-sudo.sh"`.
- The **"Upload + one-liner (trusted environments only)"** branch with the absolute
  path (never `~`), `chmod 0700`, and the local-privilege-escalation caveat stated
  to the user.
- Delete the stale marker BEFORE the GUI steps:
  `"${SSH[@]}" "rm -f '$HOME_PATH/smp-sudo-setup.result'" || true`.
- Print the Task Scheduler GUI steps (User: **root**).

### 5. Verify

Use the SAME block as first-run Task 6 Step 5 (copy verbatim): read the marker,
re-probe with 3 retries. On success, update the active profile's
`sudo_passwordless: yes` + `sudo_checked_at` (atomic edit) and re-render CLAUDE.md.
On failure, diagnose by frequency (not-run/not-root first, then marker
`stage`/`msg`, then user/includedir/path).
````

> Beim Umsetzen: ALLE Referenz-Hinweise (`Copy … verbatim`, `SAME block as …`)
> durch den **tatsächlichen** Code ersetzen. Keine Kommentar-Platzhalter und keine
> „SAME block"-Verweise im finalen File belassen — Step 2 erzwingt das.

- [ ] **Step 2: Anti-Stub-Verifikation + statische Checks**

Zuerst sicherstellen, dass keine Plan-Referenzmarker im ausgelieferten File
zurückgeblieben sind (kein Static-Check fängt das sonst):

Run: `! grep -nE 'INLINE MIRROR|SAME block as|Copy .* verbatim|do not leave a comment placeholder' plugin/commands/setup-docker-sudo.md`
Expected: exit 0 (kein Treffer). Bei Treffer: den Platzhalter durch echten Code ersetzen.
(Hinweis: KEIN bare `<!--` im Pattern — die mitkopierte `render_claude_md`-Funktion
enthält die Marker-Strings `<!-- synology-manager-plus:managed-start -->` legitim als
Bash-Strings, genau wie in `nas-add.md`. Die spezifischen Stub-Marker oben reichen.)

Run: `bash tests/static/frontmatter-check.sh`
Expected: enthält `PASS: setup-docker-sudo.md`.

Run: `bash tests/static/docker-abspath-check.sh && bash tests/static/shellcheck-commands.sh && bash tests/static/markdown-lint.sh && bash tests/static/validate-manifests.sh`
Expected: alle PASS / exit 0.

- [ ] **Step 3: Commit**

```bash
git add plugin/commands/setup-docker-sudo.md
git commit -m "feat: add /setup-docker-sudo command"
```

---

## Task 8: `nas-add.md` — Probe-Fix, Schema-Feld, Setup-Angebot

**Files:**
- Modify: `plugin/commands/nas-add.md:93` (Probe), `:130-131` (Schema), Profil-Write-Ende (Angebot)

- [ ] **Step 1: Sudo-Probe ersetzen**

In `plugin/commands/nas-add.md` die `SUDO_OK`-Zeile (Z. 93) ersetzen. Alt:

```bash
SUDO_OK=$(discover sudo "sudo -n true 2>/dev/null && echo yes || echo no")
```

Neu:

```bash
if [ "$DOCKER_OK" = "not installed" ]; then
  SUDO_OK="n/a"
else
  SUDO_OK=$(discover sudo "sudo -n /usr/local/bin/docker info >/dev/null 2>&1 && echo yes || echo no")
fi
```

- [ ] **Step 2: Profil-Schema um `sudo_checked_at` erweitern**

Im `## Software`-Block des Profil-Templates (Z. ~130-131) die Sudo-Zeile ergänzen,
damit `nas-add`-Profile dasselbe Schema wie `first-run`-Profile haben. Alt:

```markdown
- docker_available: $DOCKER_OK
- sudo_passwordless: $SUDO_OK
```

Neu:

```markdown
- docker_available: $DOCKER_OK
- sudo_passwordless: $SUDO_OK
- sudo_checked_at: <ISO 8601 UTC>
```

- [ ] **Step 3: Setup-Angebot nach dem Profil-Write**

Nach dem atomaren Profil-Write der neuen NAS (am Ende des Erfolgs-Pfads, vor der
Abschlussmeldung) einen Hinweis ausgeben, wenn Docker da ist aber sudo fehlt. Wir
fahren den Flow hier NICHT inline (DRY — er lebt in `/setup-docker-sudo`), sondern
bieten ihn an:

```bash
if [ "$DOCKER_OK" != "not installed" ] && [ "$SUDO_OK" != "yes" ]; then
  echo "Docker is installed on '$SLUG' but passwordless docker-sudo is not set up."
  echo "Run /setup-docker-sudo to configure it (it operates on the active NAS —"
  echo "switch first with: /nas-use $SLUG)."
fi
```

- [ ] **Step 4: Statische Checks**

Run: `bash tests/static/docker-abspath-check.sh && bash tests/static/shellcheck-commands.sh && bash tests/static/markdown-lint.sh`
Expected: alle PASS / exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugin/commands/nas-add.md
git commit -m "feat: nas-add fixes sudo probe and offers docker-sudo setup"
```

---

## Task 9: `_compose-lib.sh` — Fix-Hinweis auf `/setup-docker-sudo`

**Files:**
- Modify: `plugin/commands/_compose-lib.sh:36-41`

- [ ] **Step 1: Hinweis-Text ersetzen**

In `docker_daemon_precheck()` den `password is required`-Zweig (Z. 36-41) ersetzen. Alt:

```bash
    echo "ERROR: passwordless sudo for /usr/local/bin/docker is not configured on the NAS." >&2
    echo "  Fix:" >&2
    echo "    echo '<user> ALL=(ALL) NOPASSWD: /usr/local/bin/docker' | \\" >&2
    echo "      sudo tee /etc/sudoers.d/synology-manager-plus-docker" >&2
    echo "    sudo chmod 0440 /etc/sudoers.d/synology-manager-plus-docker" >&2
    return 1
```

Neu:

```bash
    echo "ERROR: passwordless sudo for /usr/local/bin/docker is not configured on the NAS." >&2
    echo "  Fix: run /setup-docker-sudo (guided Task Scheduler setup + verification)." >&2
    return 1
```

- [ ] **Step 2: Bestehende Tests laufen lassen**

Run: `bash tests/unit/test-is-critical-compose-project.sh`
Expected: `10 pass, 0 fail` (Funktion unverändert; sanity).

Run: `shellcheck plugin/commands/_compose-lib.sh`
Expected: keine Ausgabe.

- [ ] **Step 3: Commit**

```bash
git add plugin/commands/_compose-lib.sh
git commit -m "refactor: point compose sudo hint to /setup-docker-sudo"
```

---

## Task 10: Doku — `CLAUDE.md`, `README.md`, `CHANGELOG.md`

**Files:**
- Modify: `plugin/CLAUDE.md` (Available Commands-Tabelle)
- Modify: `README.md` (Commands-Tabelle ~Z. 44; Troubleshooting)
- Modify: `CHANGELOG.md` (neuer `0.8.0`-Block oben)

- [ ] **Step 1: `plugin/CLAUDE.md` — Command-Zeile ergänzen**

In der `## Available Commands`-Tabelle nach der `/setup-ssh`-Zeile einfügen:

```markdown
| `/setup-docker-sudo` | Configure passwordless docker-sudo via DSM Task Scheduler |
```

- [ ] **Step 2: `README.md` — Command-Zeile + Troubleshooting**

In der Commands-Tabelle nach der `/setup-ssh`-Zeile:

```markdown
|`/setup-docker-sudo`|Guided passwordless docker-sudo setup via DSM Task Scheduler|
```

Im Troubleshooting-Abschnitt ergänzen:

```markdown
**Docker commands say "a password is required".**

Passwordless sudo for `/usr/local/bin/docker` is missing (DSM updates wipe the
`sudoers.d` drop-in). Run `/setup-docker-sudo` — it generates a root script, walks
you through the DSM Task Scheduler (the only reliable way to run a one-off root
script on DSM), and verifies the result.
```

- [ ] **Step 3: `CHANGELOG.md` — `0.8.0`-Block**

Über dem `## [0.7.0]`-Block einfügen:

```markdown
## [0.8.0] — 2026-06-12

### Added

- `/setup-docker-sudo` — guided passwordless docker-sudo setup via the DSM Task Scheduler, with a `visudo`-validated, atomic, busybox-safe root script and self-verification through a result marker.
- `_sudo-lib.sh` (unit-tested) with `smp_classify_docker_info`, `smp_docker_sudo_probe`, `smp_render_sudoers_script`, `smp_user_is_admin_probe`.
- `/first-run` now sets up docker-sudo after the atomic profile write (resumable) and records `sudo_checked_at`.

### Fixed

- `sudo_passwordless` probe tested global sudo (`sudo -n true`), which fails under a docker-scoped `NOPASSWD` drop-in. It now probes `/usr/local/bin/docker` specifically and is `n/a` when Docker is absent.
```

- [ ] **Step 4: Statische Checks**

Run: `bash tests/static/markdown-lint.sh`
Expected: PASS / exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugin/CLAUDE.md README.md CHANGELOG.md
git commit -m "docs: document /setup-docker-sudo and 0.8.0 changes"
```

---

## Task 11: Vollständige Validierung

**Files:** keine (nur Ausführung)

- [ ] **Step 1: Alle Unit-Tests**

Run: `for t in tests/unit/test-*.sh; do echo "== $t =="; bash "$t" || exit 1; done`
Expected: jeder Test endet mit `… pass, 0 fail`.

- [ ] **Step 2: Alle statischen Checks**

Run: `for s in tests/static/*.sh; do echo "== $s =="; bash "$s" || exit 1; done`
Expected: alle exit 0.

- [ ] **Step 3: Integration (sofern Docker verfügbar)**

Run: `bash tests/integration/run-all.sh`
Expected: PASS. **Achtung:** `test-first-run.sh` und `test-nas-add.sh` prüfen ggf. die
`sudo_passwordless`-Zeile im Profil. Da sich Probe-Semantik (`n/a` bei fehlendem Docker)
und Schema (`sudo_checked_at`) geändert haben, deren Erwartungen prüfen und bei Bedarf
anpassen — dann erneut laufen lassen. Ist keine Docker-in-Docker-Umgebung verfügbar,
läuft die Integration in CI; in dem Fall die beiden Testdateien manuell auf
`sudo_passwordless`/`sudo_checked_at`-Assertions sichten.

- [ ] **Step 4: Abschluss-Commit (falls Integrationstests angepasst wurden)**

```bash
git add tests/integration/
git commit -m "test: align first-run/nas-add expectations with docker-sudo probe"
```

---

## Self-Review-Notiz für den Umsetzer

- Die Inline-Mirrors in `first-run.md` Step 8 und `setup-docker-sudo.md` müssen **byte-genau** der Lib-Logik entsprechen. Bei jeder Lib-Änderung beide Mirrors nachziehen (Repo-Konvention).
- Kein `$docker info` mit Pfad-Variable in `.md`/`.sh` — der `docker-abspath-check` flaggt das. Immer literaler `/usr/local/bin/docker`.
- `home_path` wird nirgends persistiert; jeder Flow ermittelt ihn live.
