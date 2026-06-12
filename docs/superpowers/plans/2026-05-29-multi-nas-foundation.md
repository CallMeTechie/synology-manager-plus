# Multi-NAS Foundation (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce a per-NAS data layout (`context/nas/<slug>/`) with a canonical, unit-tested resolver library and a lossless one-time migration, then retrofit all profile-reading commands onto it — without changing single-NAS behavior.

**Architecture:** Claude Code commands cannot source bundled libs at runtime (`CLAUDE_PLUGIN_ROOT` is hooks-only; confirmed). So `plugin/commands/_profile-lib.sh` is the canonical, unit-tested source of truth, and each command embeds an equivalent **inline resolver block** (the established `_compose-lib.sh` ↔ `compose-down.md` pattern). Migration runs once, only in `/first-run`. The active NAS is tracked by a one-line sentinel file `context/active-nas`.

**Tech Stack:** Bash (`set -euo pipefail`, arrays, `awk`/`grep`/`tr`/`sed`), shellcheck, the existing Mock-NAS integration harness, and the repo's unit-test pattern (`tests/unit/*.sh`).

**Spec:** `docs/superpowers/specs/2026-05-29-multi-nas-management-design.md` (Phase 1 = `[P1]` sections).

**Conventions for this repo (do not violate):**
- Commit messages: conventional style (`feat:`, `refactor:`, `test:`, `docs:`, `chore:`). **No "Co-Authored-By: Claude", no AI-typical phrasing, no "phase" wording in commit subjects.** (Project memory: release-text-style.)
- Commits/`git add` may be blocked by a local hook in some environments. If `git commit` is refused, leave the work staged-in-tree and note it; do not fight the hook.
- All paths are relative to the repo root `/root/synology-manager-plus` unless absolute.

**Note on "identical behavior":** The retrofit keeps single-NAS behavior **functionally** equivalent, with two intentional, minor improvements: (a) commands now fail early with a clear "SSH key not found" message if the key file is missing (previously `ssh` failed later), and (b) `compose-down`'s previously-silent `|| exit 1` validations now print a message. These are improvements, not regressions — do not claim byte-identical behavior.

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `plugin/commands/_profile-lib.sh` | Canonical, unit-tested NAS-resolution + migration functions. NOT sourced by commands; mirrored inline. | Create |
| `tests/unit/test-profile-lib.sh` | Unit tests for every `_profile-lib.sh` function. | Create |
| `tests/static/shellcheck-commands.sh` | Extend to also lint `plugin/commands/_*.sh` directly. | Modify |
| `plugin/commands/{nas-status,smart-status,health-summary,list-shares,logs,manage-mounts,dsm-update-check,docker-list,compose-list,compose-up,compose-down,compose-logs,compose-update}.md` | Replace ad-hoc profile extraction with the canonical inline resolver block + NAS-relative state paths. | Modify |
| `plugin/commands/diag.md` | Bespoke **non-fatal** active-NAS resolution (diag must run all 7 checks). | Modify |
| `plugin/commands/first-run.md` | Migration first; per-NAS profile write; sentinel; idempotency via new layout; NAS-relative volumes/mounts. | Modify |
| `plugin/commands/setup-ssh.md` | Read/write the NAS-relative profile. | Modify |
| `plugin/context/` (shipped scaffolding) | Replace flat `nas-profile.md`/`storage-report.md`/`volumes`/`mounts` with empty `nas/.gitkeep` so a fresh install starts cleanly. | Modify |
| `tests/integration/lib/test-helpers.sh` | `write_test_profile` includes `hostname` for deterministic migration. | Modify |
| `README.md`, `plugin/CLAUDE.md` | Update stale flat `context/` path references to the per-NAS layout. | Modify |
| `CHANGELOG.md`, `plugin/.claude-plugin/plugin.json` | Changelog entry + version bump (kept in sync — `validate-manifests.sh` enforces). | Modify |

---

## Task 1: Canonical library `_profile-lib.sh`

**Files:**
- Create: `plugin/commands/_profile-lib.sh`

- [ ] **Step 1: Write the library**

```bash
#!/usr/bin/env bash
# Canonical NAS-resolution + migration helpers for synology-manager-plus.
#
# IMPORTANT: Claude Code plugin commands CANNOT reliably source a bundled lib at
# runtime (CLAUDE_PLUGIN_ROOT is exposed to hooks only, not commands; $BASH_SOURCE
# is unstable for extracted snippets). This file is therefore the canonical,
# UNIT-TESTED source of truth — commands embed an equivalent INLINE block. Keep the
# inline blocks in sync with these functions (same pattern as _compose-lib.sh).
# Run shellcheck directly: `shellcheck _profile-lib.sh`.
#
# All functions operate on paths relative to the current working directory (the
# plugin workspace), mirroring how commands reference context/... today.

SMP_SLUG_RE='^[a-z0-9][a-z0-9-]{0,31}$'

# smp_validate_slug <slug> — return 0 if valid, 1 otherwise. No output.
smp_validate_slug() {
  [[ "${1:-}" =~ $SMP_SLUG_RE ]]
}

# smp_derive_slug <hostname> — normalize a hostname into a VALID, NON-EMPTY slug.
# Falls back to "main". This guard prevents an empty slug from ever reaching an
# rm -rf path during migration (spec R2-1).
smp_derive_slug() {
  local raw="${1:-}" slug
  slug=$(printf '%s' "$raw" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9-' '-' \
    | sed -E 's/^-+//; s/-+$//')
  slug="${slug:0:32}"
  slug=$(printf '%s' "$slug" | sed -E 's/-+$//')
  if smp_validate_slug "$slug"; then
    printf '%s' "$slug"
  else
    printf 'main'
  fi
}

# smp_list_nas — echo each configured slug (dir with profile.md), one per line, sorted.
smp_list_nas() {
  [ -d context/nas ] || return 0
  local d
  for d in context/nas/*/; do
    [ -f "${d}profile.md" ] || continue
    basename "$d"
  done | sort
}

# smp_active_nas — echo the active slug, or fail (return 1) with a clear message.
# Self-heals the sentinel when exactly one NAS exists.
smp_active_nas() {
  local active
  active=$(cat context/active-nas 2>/dev/null | head -1 || true)
  active="${active%%[[:space:]]*}"
  if smp_validate_slug "$active" && [ -f "context/nas/$active/profile.md" ]; then
    printf '%s' "$active"
    return 0
  fi
  local -a found=()
  local d
  if [ -d context/nas ]; then
    for d in context/nas/*/; do
      [ -f "${d}profile.md" ] && found+=("$(basename "$d")")
    done
  fi
  if [ "${#found[@]}" -eq 1 ]; then
    printf '%s\n' "${found[0]}" > context/active-nas
    printf '%s' "${found[0]}"
    return 0
  elif [ "${#found[@]}" -eq 0 ]; then
    if [ -f context/nas-profile.md ]; then
      echo "Legacy single-NAS layout detected — run /first-run to upgrade to the multi-NAS layout." >&2
    else
      echo "No NAS configured. Run /first-run." >&2
    fi
    return 1
  else
    echo "No active NAS selected. Run /nas-use <slug> (see /nas-list)." >&2
    return 1
  fi
}

# smp_load_profile [slug] — set HOST PORT NAS_USER CONNECT_TIMEOUT KEY_PATH SLUG.
# shellcheck disable=SC2034  # HOST/PORT/NAS_USER/CONNECT_TIMEOUT/KEY_PATH/SLUG are outputs consumed by callers
smp_load_profile() {
  local slug="${1:-}" profile field var
  if [ -n "$slug" ]; then
    smp_validate_slug "$slug" || { echo "Invalid NAS slug: $slug" >&2; return 1; }
  else
    slug=$(smp_active_nas) || return 1
  fi
  profile="context/nas/$slug/profile.md"
  [ -f "$profile" ] || { echo "Profile missing: $profile — run /first-run" >&2; return 1; }

  for field in host port user; do
    if grep -qE "^- ${field}: _not configured_" "$profile"; then
      echo "Profile not yet configured (field '${field}') — run /first-run" >&2
      return 1
    fi
  done

  HOST=$(awk '/^- host:/ {print $3; exit}' "$profile")
  PORT=$(awk '/^- port:/ {print $3; exit}' "$profile")
  NAS_USER=$(awk '/^- user:/ {print $3; exit}' "$profile")
  CONNECT_TIMEOUT=$(awk '/^- connect_timeout_seconds:/ {print $3; exit}' "$profile")
  CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
  KEY_PATH=$(awk '/^- key_path:/ {print $3; exit}' "$profile")
  KEY_PATH="${KEY_PATH:-$HOME/.ssh/synology-manager-plus_ed25519}"
  KEY_PATH="${KEY_PATH/#\~/$HOME}"
  SLUG="$slug"

  for var in HOST PORT NAS_USER; do
    if [ -z "${!var}" ]; then
      echo "Profile field $var malformed in $profile — re-run /first-run" >&2
      return 1
    fi
  done
  [[ "$HOST" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo "Invalid host: $HOST" >&2; return 1; }
  [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || { echo "Invalid port: $PORT" >&2; return 1; }
  [[ "$NAS_USER" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "Invalid user: $NAS_USER" >&2; return 1; }
  [[ "$KEY_PATH" =~ ^[A-Za-z0-9_./~-]+$ ]] || { echo "Invalid key_path: $KEY_PATH" >&2; return 1; }
}

# smp_build_ssh — set the SSH=( ... ) array. Requires smp_load_profile first.
# shellcheck disable=SC2034  # SSH is the output, consumed by callers via "${SSH[@]}"
smp_build_ssh() {
  [ -n "${KEY_PATH:-}" ] || { echo "smp_build_ssh: call smp_load_profile first" >&2; return 1; }
  [ -f "$KEY_PATH" ] || { echo "SSH key not found: $KEY_PATH" >&2; return 1; }
  SSH=( ssh -i "$KEY_PATH" -o ConnectTimeout="$CONNECT_TIMEOUT" -p "$PORT" "$NAS_USER@$HOST" )
}

# smp_migrate — one-time, resumable, lossless migration of the legacy flat layout
# (context/nas-profile.md + siblings) into context/nas/<slug>/. Idempotent.
smp_migrate() {
  local active slug host tmp
  active=$(cat context/active-nas 2>/dev/null | head -1 || true)
  active="${active%%[[:space:]]*}"
  # 1. Already migrated?
  if smp_validate_slug "$active" && [ -f "context/nas/$active/profile.md" ]; then
    return 0
  fi
  # 2. Nothing to migrate?
  [ -f context/nas-profile.md ] || return 0

  # 3. Migrate.
  host=$(awk '/^- hostname:/ {print $3; exit}' context/nas-profile.md)
  [ "$host" = "_not" ] && host=""            # "_not configured_" placeholder
  slug=$(smp_derive_slug "$host")            # always valid, never empty

  rm -rf context/.nas-migrate.tmp
  mkdir -p "context/.nas-migrate.tmp/$slug"
  cp context/nas-profile.md "context/.nas-migrate.tmp/$slug/profile.md"
  [ -f context/storage-report.md ] && cp context/storage-report.md "context/.nas-migrate.tmp/$slug/storage-report.md"
  [ -d context/volumes ] && cp -r context/volumes "context/.nas-migrate.tmp/$slug/volumes"
  [ -d context/mounts ] && cp -r context/mounts "context/.nas-migrate.tmp/$slug/mounts"

  rm -rf -- "context/nas/${slug:?slug empty}"
  mkdir -p context/nas
  mv "context/.nas-migrate.tmp/$slug" "context/nas/$slug"

  tmp=$(mktemp)
  printf '%s\n' "$slug" > "$tmp" && mv "$tmp" context/active-nas

  rm -f context/nas-profile.md context/storage-report.md
  rm -rf context/volumes context/mounts
  rm -rf context/.nas-migrate.tmp        # remove the now-empty staging parent
  echo "[migration] single-NAS workspace migrated to context/nas/$slug/"
}
```

- [ ] **Step 2: Parse + shellcheck (must be clean)**

Run: `bash -n plugin/commands/_profile-lib.sh && shellcheck --severity=warning plugin/commands/_profile-lib.sh`
Expected: no output, exit 0. (The two `# shellcheck disable=SC2034` directives above `smp_load_profile`/`smp_build_ssh` suppress the expected "output var unused in this file" warnings.)

- [ ] **Step 3: Commit**

```bash
git commit -m "feat: add canonical _profile-lib.sh NAS resolver and migration" -- plugin/commands/_profile-lib.sh
```

---

## Task 2: Unit tests for `_profile-lib.sh`

**Files:**
- Create: `tests/unit/test-profile-lib.sh`

**Critical test-harness rule:** counters and `cd` must happen in the **current shell**, never in a `$( )` command substitution or a `( )` subshell — otherwise increments/`cd` are lost and the test reports a false "0 fail" (the bug found in review). `setup_ws` `cd`s in the current shell; assertions run in the current shell.

- [ ] **Step 1: Write the test**

```bash
#!/usr/bin/env bash
set -uo pipefail
TEST_NAME="profile-lib"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT/plugin/commands/_profile-lib.sh"

pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
no() { echo "FAIL: $1"; fail=$((fail+1)); }

WS=""
setup_ws() { WS=$(mktemp -d -t "smp-lib-XXXX"); mkdir -p "$WS/context"; cd "$WS"; }
teardown_ws() { cd "$ROOT"; [ -n "$WS" ] && rm -rf "$WS"; WS=""; }

# --- smp_validate_slug (no cwd dependency) ---
for good in main nas-01 a a1; do
  smp_validate_slug "$good" && ok "valid slug: $good" || no "valid slug rejected: $good"
done
for bad in "" "../etc" "a/b" "UPPER" "-lead" "a b"; do
  smp_validate_slug "$bad" && no "invalid slug accepted: '$bad'" || ok "invalid slug rejected: '$bad'"
done
long33=$(printf 'a%.0s' $(seq 1 33))
smp_validate_slug "$long33" && no "33-char slug accepted" || ok "33-char slug rejected"

# --- smp_derive_slug: always valid, never empty (R2-1) ---
deq() { local got; got=$(smp_derive_slug "$1"); [ "$got" = "$2" ] && ok "derive '$1' -> $2" || no "derive '$1' -> got '$got' want '$2'"; }
deq "MyNAS"   "mynas"
deq "My NAS!" "my-nas"
deq ""        "main"
deq "!!!"     "main"
deq "---"     "main"
gotlong=$(smp_derive_slug "$(printf 'X%.0s' $(seq 1 40))")
smp_validate_slug "$gotlong" && ok "derive long -> valid ($gotlong)" || no "derive long -> invalid '$gotlong'"

# --- smp_active_nas fallback rules (Sec 4.2) ---
setup_ws
smp_active_nas >/dev/null 2>&1 && no "active: empty should fail" || ok "active: empty fails"
teardown_ws

setup_ws
mkdir -p context/nas/only; echo x > context/nas/only/profile.md
out=$(smp_active_nas 2>/dev/null) && [ "$out" = "only" ] && [ -f context/active-nas ] && ok "active: single self-heals" || no "active: single failed ($out)"
teardown_ws

setup_ws
mkdir -p context/nas/a context/nas/b; echo x>context/nas/a/profile.md; echo x>context/nas/b/profile.md
smp_active_nas >/dev/null 2>&1 && no "active: multi w/o pointer should fail" || ok "active: multi w/o pointer fails"
teardown_ws

setup_ws
mkdir -p context/nas/a context/nas/b; echo x>context/nas/a/profile.md; echo x>context/nas/b/profile.md
echo b > context/active-nas
out=$(smp_active_nas 2>/dev/null); [ "$out" = "b" ] && ok "active: valid pointer honored" || no "active: pointer ignored ($out)"
teardown_ws

setup_ws
printf '# old\n- hostname: nas9\n' > context/nas-profile.md
# Capture-then-grep: smp_active_nas returns 1 here, and piping it directly into
# grep under `set -o pipefail` would make the pipeline exit 1 (false FAIL).
out=$(smp_active_nas 2>&1) || true
printf '%s\n' "$out" | grep -q "Legacy single-NAS" && ok "active: legacy hint" || no "active: no legacy hint"
teardown_ws

# --- smp_list_nas: sorted, ignores dirs without profile.md ---
setup_ws
mkdir -p context/nas/zeta context/nas/alpha context/nas/empty
echo x>context/nas/zeta/profile.md; echo x>context/nas/alpha/profile.md
out=$(smp_list_nas | tr '\n' ' '); [ "$out" = "alpha zeta " ] && ok "list: sorted, filtered" || no "list: got '$out'"
teardown_ws

# --- smp_load_profile: extracts + validates; key_path charset ---
setup_ws
mkdir -p context/nas/main
cat > context/nas/main/profile.md <<EOF
## Connection
- host: 192.168.1.10
- port: 22
- user: admin
- key_path: ~/.ssh/synology-manager-plus_ed25519
- connect_timeout_seconds: 10
EOF
echo main > context/active-nas
if smp_load_profile && [ "$HOST" = "192.168.1.10" ] && [ "$PORT" = "22" ] && [ "$NAS_USER" = "admin" ] && [ "$SLUG" = "main" ]; then
  ok "load: extracts fields"; else no "load: extraction failed"; fi
teardown_ws

setup_ws
mkdir -p context/nas/main
printf '## Connection\n- host: h\n- port: 22\n- user: u\n- key_path: /bad;rm\n' > context/nas/main/profile.md
echo main > context/active-nas
smp_load_profile >/dev/null 2>&1 && no "load: bad key_path accepted" || ok "load: bad key_path rejected"
teardown_ws

# --- smp_migrate: lossless + idempotent + resume ---
seed_legacy() {
  printf '# Synology NAS Profile\n- host: 192.168.1.10\n- port: 22\n- user: admin\n- hostname: nasbox\n' > context/nas-profile.md
  echo "report" > context/storage-report.md
  mkdir -p context/volumes context/mounts; echo v > context/volumes/v1.txt; echo m > context/mounts/current.txt
}
setup_ws
seed_legacy
smp_migrate >/dev/null
if [ -f context/nas/nasbox/profile.md ] && [ -f context/nas/nasbox/storage-report.md ] \
   && [ -f context/nas/nasbox/volumes/v1.txt ] && [ -f context/nas/nasbox/mounts/current.txt ] \
   && [ "$(cat context/active-nas)" = "nasbox" ] && [ ! -f context/nas-profile.md ] \
   && [ ! -d context/volumes ] && [ ! -d context/.nas-migrate.tmp ]; then ok "migrate: lossless"; else no "migrate: layout wrong"; fi
smp_migrate >/dev/null 2>&1 && ok "migrate: re-run idempotent" || no "migrate: re-run errored"
teardown_ws

setup_ws
seed_legacy
mkdir -p context/.nas-migrate.tmp/junk context/nas/nasbox; echo partial > context/nas/nasbox/profile.md
smp_migrate >/dev/null
[ "$(cat context/active-nas)" = "nasbox" ] && grep -q 192.168.1.10 context/nas/nasbox/profile.md \
  && [ ! -d context/.nas-migrate.tmp ] && ok "migrate: resume lossless" || no "migrate: resume failed"
teardown_ws

echo ""
echo "=== test-profile-lib: $pass pass, $fail fail ==="
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run — expect all PASS**

Run: `bash tests/unit/test-profile-lib.sh`
Expected: every line `PASS:`, final `=== test-profile-lib: N pass, 0 fail ===`, exit 0. **If any case fails, fix `_profile-lib.sh`** (the test is the correctness oracle), then re-run. There must be **zero** `FAIL:` lines — a `FAIL` line with "0 fail" in the summary means the harness is broken (the bug this rewrite fixes).

- [ ] **Step 3: Commit**

```bash
chmod +x tests/unit/test-profile-lib.sh
git commit -m "test: add unit tests for _profile-lib.sh resolver and migration" -- tests/unit/test-profile-lib.sh
```

---

## Task 3: Lint libraries in the static check

**Files:**
- Modify: `tests/static/shellcheck-commands.sh`

- [ ] **Step 1: Append lib linting before the final `if [ $fail_count -gt 0 ]` block**

```bash
# Also lint the shared *.sh libraries directly (the *.md loop above only covers
# extracted command snippets; the libs are real scripts and must pass on their own).
for lib in "$COMMANDS_DIR"/_*.sh; do
  [ -f "$lib" ] || continue
  if shellcheck --severity=warning --shell=bash "$lib"; then
    echo "PASS: $(basename "$lib")"
  else
    echo "FAIL: $(basename "$lib") (see shellcheck output above)"
    fail_count=$((fail_count + 1))
  fi
done
```

- [ ] **Step 2: Run the static check**

Run: `bash tests/static/shellcheck-commands.sh`
Expected: includes `PASS: _profile-lib.sh` and `PASS: _compose-lib.sh`; exit 0. (If `_profile-lib.sh` fails with SC2034, the disable directives in Task 1 are missing/misplaced — they must sit on the line directly above the function definition.)

- [ ] **Step 3: Commit**

```bash
git commit -m "test: shellcheck the shared command libraries directly" -- tests/static/shellcheck-commands.sh
```

---

## Task 4: Finalize the canonical inline resolver block

This block is the inline equivalent of legacy-detection + `smp_active_nas` + `smp_load_profile` + `smp_build_ssh`, **logically identical to the lib** (including the legacy-hint-on-empty-fallback behavior). It is pasted verbatim into each retrofitted command in Tasks 5–6. **Defined once here.**

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

Note: there is **no** top-level `[ -f context/nas-profile.md ] && [ ! -d context/nas ]` short-circuit — the legacy case is handled inside the empty-fallback branch, exactly as the lib does, so the inline block and lib emit the same message in every scenario (including "legacy file present + empty `context/nas/`").

- [ ] **Step 1: Sanity-check the block as it is actually consumed**

The block is consumed inside command markdown, where `tests/static/shellcheck-commands.sh` wraps each command's snippets with `# shellcheck disable=SC2154,SC2034`. Validate it the same way:

```bash
{ echo '#!/usr/bin/env bash'; echo '# shellcheck disable=SC2154,SC2034'; cat /tmp/smp-block.sh; } > /tmp/smp-wrapped.sh
shellcheck --severity=warning --shell=bash /tmp/smp-wrapped.sh
```
Expected: exit 0, no output. **Note:** a *bare* (unwrapped) shellcheck of the block reports `SC2034: SSH appears unused` — that is expected and benign (the consuming command calls `"${SSH[@]}"` in later blocks, and the real static check applies the SC2034 disable). Do not "fix" that by editing the block.

(No commit — this task only validates the reused artifact.)

---

## Task 5: Retrofit `nas-status.md` (worked example)

**Files:**
- Modify: `plugin/commands/nas-status.md`

- [ ] **Step 1: Replace the profile-extraction + SSH-array blocks**

Delete the first ```bash block (`PROFILE="context/nas-profile.md"` extraction) AND the `SSH=( ... )` array block. Insert the **canonical resolver block** (Task 4) once where the first block was. The query commands that follow (`"${SSH[@]}" "df -h"` etc.) are unchanged.

- [ ] **Step 2: Make the state-write path NAS-relative**

Change the prose + write target from `context/storage-report.md` to `context/nas/$SLUG/storage-report.md` (`$SLUG` is set by the resolver block).

- [ ] **Step 3: Update the intro prose**

Replace "Read `context/nas-profile.md` and extract values" with: "Resolve the active NAS via the canonical resolver block (mirrors `_profile-lib.sh`); it sets `HOST/PORT/NAS_USER/CONNECT_TIMEOUT/KEY_PATH/SLUG` and the `SSH` array." Keep the `NAS_USER` (not `$USER`) note.

- [ ] **Step 4: Static checks (note the differing PASS strings)**

Run: `bash tests/static/shellcheck-commands.sh && bash tests/static/frontmatter-check.sh && bash tests/static/markdown-lint.sh`
Expected: `shellcheck-commands.sh` prints `PASS: nas-status`; `frontmatter-check.sh` prints `PASS: nas-status.md` (it keeps the `.md`); `markdown-lint.sh` prints no per-file `PASS` line but exits 0. All three exit 0.

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor: nas-status uses multi-NAS resolver and per-NAS state path" -- plugin/commands/nas-status.md
```

---

## Task 6: Retrofit the remaining 12 profile-reading commands (NOT diag)

Apply the **same transformation** as Task 5 to each command below: delete its `PROFILE="context/nas-profile.md"` extraction block and its `SSH=( ... )` block, insert the **canonical resolver block** (Task 4) once, update NAS-relative state paths per the table. `diag` is handled separately in Task 7 (it must not use the exit-on-failure block).

| Command file | Special handling beyond the resolver block |
|---|---|
| `smart-status.md` | none (read-only). |
| `health-summary.md` | Its lazy `cpu_cores`/temp migration writes to the profile — change the target to `context/nas/$SLUG/profile.md`, **and** update the echo string `"[migration] cpu_cores=$NPROC written to nas-profile.md"` → `"... written to context/nas/$SLUG/profile.md"`. |
| `list-shares.md` | Volume snapshot path → `context/nas/$SLUG/volumes/<vol>-snapshot.txt`; **ensure `mkdir -p context/nas/$SLUG/volumes` before writing** (the shipped `.gitkeep` dirs are gone after Task 10). |
| `manage-mounts.md` | Mounts path → `context/nas/$SLUG/mounts/current.txt` (all references); **ensure `mkdir -p context/nas/$SLUG/mounts` before writing**. |
| `logs.md` | Keep its existing `--source/--last/--grep` arg-parsing block; only the profile/SSH blocks are replaced. |
| `dsm-update-check.md` | none. |
| `docker-list.md` | none (`/usr/local/bin/docker` absolute path unchanged). |
| `compose-list.md` | none. |
| `compose-up.md` | none. |
| `compose-logs.md` | none. |
| `compose-update.md` | none. |
| `compose-down.md` | **Preserve** its `critical_compose_projects` lazy-migration block AND its inline `is_critical_compose_project()` function. Only the `PROFILE=`/extraction/`SSH=` parts are replaced. The lazy-migration `awk ... > "$PROFILE"` now targets the resolved `$PROFILE` (= `context/nas/$SLUG/profile.md`); `CRIT_LIST` extraction stays, reading from `$PROFILE`. **Order matters:** run the resolver block first (sets `$PROFILE`), then the `critical_compose_projects` lazy-migration that mutates `$PROFILE`. Also update the user-facing Tip string `…in nas-profile.md` → `…in context/nas/$SLUG/profile.md`. |

- [ ] **Step 1:** Retrofit the no-special-handling group: `smart-status.md`, `dsm-update-check.md`, `docker-list.md`, `compose-list.md`, `compose-up.md`, `compose-logs.md`, `compose-update.md`.

- [ ] **Step 2:** Retrofit the state-path group: `health-summary.md`, `list-shares.md`, `manage-mounts.md`.

- [ ] **Step 3:** Retrofit the special cases: `logs.md` (preserve arg-parsing), `compose-down.md` (preserve critical-list logic + inline function).

- [ ] **Step 4: Static checks for all**

Run: `bash tests/static/shellcheck-commands.sh && bash tests/static/frontmatter-check.sh && bash tests/static/markdown-lint.sh`
Expected: `shellcheck-commands.sh` prints `PASS: <name>` for each; `frontmatter-check.sh` prints `PASS: <name>.md`; markdown-lint exits 0 with no per-file PASS. Fix any shellcheck warning by aligning the pasted block.

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor: route read commands through the multi-NAS resolver" -- plugin/commands/smart-status.md plugin/commands/dsm-update-check.md plugin/commands/docker-list.md plugin/commands/compose-list.md plugin/commands/compose-up.md plugin/commands/compose-logs.md plugin/commands/compose-update.md plugin/commands/health-summary.md plugin/commands/list-shares.md plugin/commands/manage-mounts.md plugin/commands/logs.md plugin/commands/compose-down.md
```

---

## Task 7: Retrofit `diag.md` (bespoke, non-fatal)

`diag` must run all 7 checks even when no NAS is configured, so it CANNOT use the exit-on-failure resolver block. Replace only its extraction prelude with a non-fatal active-NAS resolver, and update Check 1 + Check 4's key path.

**Files:**
- Modify: `plugin/commands/diag.md`

- [ ] **Step 1: Replace the `## Setup` extraction prelude bash block** (currently the `set -uo pipefail` … `PROFILE="context/nas-profile.md"` … block) with:

```bash
set -uo pipefail  # -e omitted on purpose; per-check error handling below

# Resolve the active NAS profile WITHOUT aborting (diag must run all checks).
PROFILE=""; SLUG=""; LEGACY=0
HOST=""; PORT=""; NAS_USER=""; CONNECT_TIMEOUT=""
KEY_PATH="$HOME/.ssh/synology-manager-plus_ed25519"

if [ -f context/nas-profile.md ] && [ ! -d context/nas ]; then
  LEGACY=1
elif [ -d context/nas ]; then
  ACTIVE=$(cat context/active-nas 2>/dev/null | head -1 || true)
  ACTIVE="${ACTIVE%%[[:space:]]*}"
  if [[ "$ACTIVE" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] && [ -f "context/nas/$ACTIVE/profile.md" ]; then
    PROFILE="context/nas/$ACTIVE/profile.md"; SLUG="$ACTIVE"
  else
    # No valid pointer: pick any configured NAS for diagnostics (last alphabetical
    # wins). Unreachable in Phase 1 (only one NAS exists); Phase 2 adds /nas-use.
    for d in context/nas/*/; do
      [ -f "${d}profile.md" ] && { PROFILE="${d}profile.md"; SLUG="$(basename "$d")"; }
    done
  fi
fi

if [ -n "$PROFILE" ]; then
  HOST=$(awk '/^- host:/ {print $3; exit}' "$PROFILE")
  PORT=$(awk '/^- port:/ {print $3; exit}' "$PROFILE")
  NAS_USER=$(awk '/^- user:/ {print $3; exit}' "$PROFILE")
  CONNECT_TIMEOUT=$(awk '/^- connect_timeout_seconds:/ {print $3; exit}' "$PROFILE")
  kp=$(awk '/^- key_path:/ {print $3; exit}' "$PROFILE")
  [ -n "$kp" ] && KEY_PATH="${kp/#\~/$HOME}"
  for field in host port user; do
    if grep -qE "^- ${field}: _not configured_" "$PROFILE"; then
      case $field in host) HOST="" ;; port) PORT="" ;; user) NAS_USER="" ;; esac
    fi
  done
fi
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
```

- [ ] **Step 2: Rewrite Check 1 ("Profile present")** to report on the resolver result instead of the flat file:

```bash
if [ "$LEGACY" -eq 1 ]; then
  echo "FAIL Legacy single-NAS layout — run /first-run to migrate"
elif [ -n "$PROFILE" ]; then
  echo "OK Active NAS resolvable ($SLUG)"
else
  echo "FAIL No NAS configured — run /first-run"
fi
```

- [ ] **Step 3: Check 4 — use the resolved key path.** In the `SSH_ARGS=( ... )` array, change `-i "$HOME/.ssh/synology-manager-plus_ed25519"` to `-i "$KEY_PATH"`. Keep `-o BatchMode=yes` and everything else. (Checks 2, 3, 5–7 are unchanged — they already use `$HOST/$PORT/$NAS_USER/$SSH_ARGS`.)

- [ ] **Step 4: Update the `## Setup` prose** to say it resolves the active NAS (per-NAS layout) non-fatally, still setting empty vars on missing data so checks report `FAIL`/`WARN`/`OK`.

- [ ] **Step 5: Static checks**

Run: `bash tests/static/shellcheck-commands.sh && bash tests/static/frontmatter-check.sh && bash tests/static/markdown-lint.sh`
Expected: `PASS: diag` / `PASS: diag.md`; exit 0.

- [ ] **Step 6: Commit**

```bash
git commit -m "refactor: diag resolves the active NAS non-fatally across all checks" -- plugin/commands/diag.md
```

---

## Task 8: `/first-run` — migration + per-NAS write + idempotency

**Files:**
- Modify: `plugin/commands/first-run.md`

- [ ] **Step 1: Add "Step 0. Migrate legacy layout (one-time)"** before "Step 2. Detect existing config", with this block (inline equivalent of `smp_migrate` + `smp_derive_slug`; mirrors `_profile-lib.sh`, including the staging cleanup):

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

- [ ] **Step 2: Change profile write target + idempotency detection**

- Step 2 ("Detect existing config"): detect via `context/active-nas` + `context/nas/<slug>/profile.md` (NOT `context/nas-profile.md`). If a configured NAS exists, ask Refresh/Cancel as today.
- Step 7 ("Write context files"): write the profile to `context/nas/<slug>/profile.md`, deriving `<slug>` from the discovered hostname with the exact normalize+validate logic from Step 0 (fallback `main`); set `context/active-nas` to that slug atomically (`mktemp` + `mv`). Keep `- key_path: ~/.ssh/synology-manager-plus_ed25519` for the first NAS. **Create the subdirs first: `mkdir -p context/nas/<slug>/volumes context/nas/<slug>/mounts`** (the shipped `.gitkeep` dirs are gone after Task 10). Volumes → `context/nas/<slug>/volumes/volume1-snapshot.txt`; mounts → `context/nas/<slug>/mounts/current.txt`.

- [ ] **Step 3: CLAUDE.md managed section (Phase-1 form)**

Render the same Quick Reference table as today. **Do NOT add the `Active NAS:` header or `(see /nas-list ...)` hint** — `/nas-list` does not exist until Phase 2 (spec R2-2). Leave the marker-count safety logic unchanged.

- [ ] **Step 4: Static checks**

Run: `bash tests/static/shellcheck-commands.sh && bash tests/static/frontmatter-check.sh && bash tests/static/markdown-lint.sh`
Expected: `PASS: first-run` / `PASS: first-run.md`; exit 0.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat: first-run migrates legacy layout and writes per-NAS profile" -- plugin/commands/first-run.md
```

---

## Task 9: `/setup-ssh` — concrete NAS-relative read/write

**Files:**
- Modify: `plugin/commands/setup-ssh.md`

`setup-ssh` reads connection details (steps 1, 3) and writes them (step 5). Make the layout-resolution concrete.

- [ ] **Step 1: Step 1 — resolve where to read/write the profile**

Add an explicit resolution block: determine `TARGET_PROFILE` and `SLUG`:

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

Then: if `$TARGET_PROFILE` exists, read `host`/`port`/`NAS_USER`/`CONNECT_TIMEOUT` from it (same `awk` lines as the resolver); otherwise prompt via `AskUserQuestion` (as today) and validate with the existing regexes.

- [ ] **Step 2: Key path — Phase 1 keeps the legacy key name**

Step 2's keypair (`$HOME/.ssh/synology-manager-plus_ed25519`) and step 3's test stay as-is. The first NAS's `key_path` is the legacy name (NG6), so this is consistent. (Per-NAS keys arrive in Phase 2 with `/nas-add`.)

- [ ] **Step 3: Step 5 — write to the per-NAS profile**

On successful re-verify, write/update `$TARGET_PROFILE` (instead of `context/nas-profile.md`) with `host`/`port`/`user`/`key_path: ~/.ssh/synology-manager-plus_ed25519`/`connect_timeout_seconds` (preserve existing override) + `Last Updated`. Then ensure `context/active-nas` contains `$SLUG` (atomic write) so the new profile is active.

- [ ] **Step 4: Static checks**

Run: `bash tests/static/shellcheck-commands.sh && bash tests/static/frontmatter-check.sh && bash tests/static/markdown-lint.sh`
Expected: `PASS: setup-ssh` / `PASS: setup-ssh.md`; exit 0.

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor: setup-ssh reads and writes the per-NAS profile" -- plugin/commands/setup-ssh.md
```

---

## Task 10: Update shipped `plugin/context/` scaffolding (fresh-install correctness)

The plugin ships a populated `context/` workspace. Today it ships a **flat** `nas-profile.md` (all placeholders) + `storage-report.md` + `volumes/.gitkeep` + `mounts/.gitkeep`. After the retrofit, a brand-new install would have a legacy flat file and no `context/nas/`, so every command would hit "Legacy single-NAS layout detected" before the user configures anything. Fix the shipped scaffolding so a fresh install lands on the clean "No NAS configured. Run /first-run." path.

**Files:**
- Delete: `plugin/context/nas-profile.md`, `plugin/context/storage-report.md`, `plugin/context/volumes/.gitkeep`, `plugin/context/mounts/.gitkeep`
- Create: `plugin/context/nas/.gitkeep`

- [ ] **Step 1: Replace the scaffolding**

```bash
git rm plugin/context/nas-profile.md plugin/context/storage-report.md plugin/context/volumes/.gitkeep plugin/context/mounts/.gitkeep
mkdir -p plugin/context/nas
: > plugin/context/nas/.gitkeep
```

(If `git rm` is blocked by the hook, `rm` the files and `: > plugin/context/nas/.gitkeep` manually.)

- [ ] **Step 2: Verify fresh-install resolution behaves correctly**

With the new scaffolding, `context/nas/` exists (via `.gitkeep`) and is empty → the resolver's empty-fallback prints "No NAS configured. Run /first-run." (NOT the legacy hint). Confirm by simulating in a temp copy:

Run (capture the lib's absolute path BEFORE `cd`, or it resolves into the temp dir):
```bash
LIB="$PWD/plugin/commands/_profile-lib.sh"; tmp=$(mktemp -d); cp -r plugin/context "$tmp/context"
( cd "$tmp"; bash -c "source '$LIB'; smp_active_nas; echo \"exit=\$?\"" 2>&1 ); rm -rf "$tmp"
```
Expected: `No NAS configured. Run /first-run.` and `exit=1` — NOT the "Legacy" message and NOT a 127 "command not found".

- [ ] **Step 3: Commit**

```bash
git commit -m "chore: ship empty per-NAS context scaffolding for fresh installs" -- plugin/context/
```

---

## Task 11: Keep integration smoke tests green

The 18 integration smoke tests reimplement command logic against the Mock-NAS and write the profile to `$HOME/nas-profile.md`; they do **not** exec the command markdown (verified: `run_command_snippets`/`extract_command_bash` are defined in `test-helpers.sh` but used by no test), so the retrofit does not break them.

**Files:**
- Modify: `tests/integration/lib/test-helpers.sh`

- [ ] **Step 1: Add a `hostname` line to `write_test_profile`**

In the heredoc inside `write_test_profile`, add a `## Software` section with `- hostname: mocknas` so any future test that exercises migration derives a deterministic slug (`mocknas`).

- [ ] **Step 2: Run the full suite if Docker is available**

Run: `bash tests/integration/run-all.sh`
Expected: `[run-all] PASS unit: test-profile-lib.sh` and all 18 integration tests pass. (No Docker locally → rely on CI `validate.yml`.)

- [ ] **Step 3: Commit**

```bash
git commit -m "test: include hostname in test profile for deterministic migration" -- tests/integration/lib/test-helpers.sh
```

---

## Task 12: Update stale flat-path docs

After the retrofit the canonical paths are `context/nas/<slug>/...`. README prose and the plugin's own agent-facing `CLAUDE.md` still reference the flat paths and would misdirect.

**Files:**
- Modify: `README.md`, `plugin/CLAUDE.md`

- [ ] **Step 1: README.md** — update the flat-path references (`context/nas-profile.md`, `context/volumes/`, `context/mounts/`, `context/storage-report.md`) to the per-NAS layout, and reword the migration/first-steps note to mention that `/first-run` creates `context/nas/<slug>/`. Do **not** add Phase-2 commands to the command table (those are deferred).

- [ ] **Step 2: plugin/CLAUDE.md** — in "Operational Guidelines", change "Check `context/nas-profile.md`" → "Resolve the active NAS (`context/active-nas` → `context/nas/<slug>/profile.md`)" and "refresh `context/storage-report.md`" → "refresh `context/nas/<slug>/storage-report.md`". Leave the managed-section markers and Quick Reference table structure unchanged.

- [ ] **Step 3: Static check**

Run: `bash tests/static/markdown-lint.sh`
Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
git commit -m "docs: update context paths to the per-NAS layout" -- README.md plugin/CLAUDE.md
```

---

## Task 13: Changelog + version bump

**Files:**
- Modify: `CHANGELOG.md`, `plugin/.claude-plugin/plugin.json`

- [ ] **Step 1: Add a CHANGELOG entry** (match the file's em-dash style `## [x] — date`; plain wording, no "phase", no AI phrasing)

```markdown
## [0.5.0] — 2026-05-29

### Added
- Per-NAS profile layout (`context/nas/<slug>/`) and an active-NAS pointer, preparing the plugin to manage multiple Synology NAS.
- Canonical, unit-tested NAS resolver (`plugin/commands/_profile-lib.sh`) mirrored inline by every command.
- One-time, lossless, resumable migration of existing single-NAS workspaces, performed by `/first-run`.

### Changed
- All profile-reading commands resolve the active NAS and write state under `context/nas/<slug>/`.
- `tests/static/shellcheck-commands.sh` now lints the shared `_*.sh` libraries directly.

### Notes
- Existing single-NAS users: run `/first-run` once after updating to migrate to the new layout. Single-NAS behaviour is otherwise unchanged.
```

- [ ] **Step 2: Bump the version in `plugin.json`** → `"version": "0.5.0"` (must match the CHANGELOG header — `validate-manifests.sh` greps `## \[0.5.0\]`, separator-agnostic).

- [ ] **Step 3: Validate manifests**

Run: `bash tests/static/validate-manifests.sh`
Expected: `CHANGELOG.md has entry for version 0.5.0`; "All manifest checks passed."; exit 0.

- [ ] **Step 4: Full static gate**

Run: `for s in tests/static/*.sh; do echo "== $s =="; bash "$s" || exit 1; done`
Expected: every static check exits 0.

- [ ] **Step 5: Commit**

```bash
git commit -m "chore: bump version to 0.5.0 with multi-NAS foundation changelog" -- CHANGELOG.md plugin/.claude-plugin/plugin.json
```

---

## Final Verification (Phase 1 acceptance)

- [ ] `bash tests/unit/test-profile-lib.sh` → every line PASS, `0 fail`, exit 0. **Zero `FAIL:` lines.**
- [ ] `for s in tests/static/*.sh; do bash "$s" || exit 1; done` → all PASS (incl. `_profile-lib.sh` + `_compose-lib.sh` shellchecked).
- [ ] Fresh-install check (Task 10 Step 2): a clean shipped `context/` resolves to "No NAS configured. Run /first-run." — not the legacy hint.
- [ ] `bash tests/integration/run-all.sh` (or CI) → unit + 18 integration tests PASS.
- [ ] Manual real-hardware check (DS218+): with a legacy `context/nas-profile.md`, run `/first-run` once → migrated to `context/nas/<slug>/`, `context/active-nas` set, `context/.nas-migrate.tmp` gone, `/nas-status` + `/health-summary` + `/diag` behave as before.
- [ ] Spec Phase-1 acceptance checklist (Sec 10) all satisfied.

---

## Self-Review notes (gaps the implementer must watch)

- **Inline/lib drift:** the resolver block (Task 4), the diag prelude (Task 7), the first-run migration (Task 8), and `_profile-lib.sh` (Task 1) must stay logically equivalent. Change one → change the others → re-run Task 2. The block and lib now share identical legacy-message semantics (no top-level short-circuit in the block).
- **`diag` is non-fatal by design:** never paste the exit-on-failure resolver block into it (Task 7 is bespoke).
- **`compose-down` is the trickiest bulk retrofit:** preserve the `critical_compose_projects` lazy migration AND the inline `is_critical_compose_project()`; resolver block runs first (sets `$PROFILE`), then the lazy migration mutates `$PROFILE`.
- **Migration runs only in `/first-run`:** every other command merely *detects* the legacy layout and tells the user to run `/first-run`.
- **Fresh install vs migration:** Task 10 makes a fresh install land on "No NAS configured" (clean); an existing user's configured legacy file triggers migration via `/first-run`. Both paths verified.
- **CLAUDE.md `/nas-list` hint is Phase 2:** do not reference `/nas-list` anywhere user-visible in Phase 1.
- **shellcheck SC2034:** the lib uses per-function disable directives; the inline block relies on the `shellcheck-commands.sh` wrapper's `SC2154,SC2034` disable. A bare shellcheck of the isolated block reporting SC2034 on `SSH` is expected, not a bug.
