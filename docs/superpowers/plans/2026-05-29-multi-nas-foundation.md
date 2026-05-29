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

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `plugin/commands/_profile-lib.sh` | Canonical, unit-tested NAS-resolution + migration functions. NOT sourced by commands; mirrored inline. | Create |
| `tests/unit/test-profile-lib.sh` | Unit tests for every `_profile-lib.sh` function (slug validation, derive, pointer fallback, list, load, migrate + resume). | Create |
| `tests/static/shellcheck-commands.sh` | Extend to also lint `plugin/commands/_*.sh` directly. | Modify |
| `plugin/commands/{nas-status,smart-status,health-summary,list-shares,logs,manage-mounts,diag,dsm-update-check,docker-list,compose-list,compose-up,compose-down,compose-logs,compose-update}.md` | Replace ad-hoc profile extraction with the canonical inline resolver block + NAS-relative state paths. | Modify |
| `plugin/commands/first-run.md` | Run migration first; write profile to `context/nas/<slug>/`; set sentinel; idempotency via new layout; NAS-relative volumes/mounts. | Modify |
| `plugin/commands/setup-ssh.md` | Read/write the NAS-relative profile. | Modify |
| `tests/integration/lib/test-helpers.sh` | `write_test_profile` includes `hostname` for deterministic migration in tests. | Modify |
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

# smp_active_nas — echo the active slug, or fail (exit 1) with a clear message.
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

# smp_profile_path [slug] — echo context/nas/<slug>/profile.md (default: active).
smp_profile_path() {
  local slug="${1:-}"
  [ -n "$slug" ] || { slug=$(smp_active_nas) || return 1; }
  printf 'context/nas/%s/profile.md' "$slug"
}

# smp_load_profile [slug] — set HOST PORT NAS_USER CONNECT_TIMEOUT KEY_PATH SLUG.
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
  [[ "$KEY_PATH" =~ ^[A-Za-z0-9_./-]+$ ]] || { echo "Invalid key_path: $KEY_PATH" >&2; return 1; }
}

# smp_build_ssh — set SSH=( ... ). Requires smp_load_profile to have run first.
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
  echo "[migration] single-NAS workspace migrated to context/nas/$slug/"
}
```

- [ ] **Step 2: Verify it parses + passes shellcheck**

Run: `bash -n plugin/commands/_profile-lib.sh && shellcheck --severity=warning plugin/commands/_profile-lib.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git commit -m "feat: add canonical _profile-lib.sh NAS resolver and migration" -- plugin/commands/_profile-lib.sh
```

---

## Task 2: Unit tests for `_profile-lib.sh`

**Files:**
- Create: `tests/unit/test-profile-lib.sh`

- [ ] **Step 1: Write the test**

```bash
#!/usr/bin/env bash
set -euo pipefail
TEST_NAME="profile-lib"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT/plugin/commands/_profile-lib.sh"

pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
no() { echo "FAIL: $1"; fail=$((fail+1)); }

new_workspace() { local d; d=$(mktemp -d -t "smp-lib-XXXX"); cd "$d"; mkdir -p context; printf '%s' "$d"; }

# --- smp_validate_slug ---
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
got=$(smp_derive_slug "$(printf 'X%.0s' $(seq 1 40))"); smp_validate_slug "$got" && ok "derive long -> valid ($got)" || no "derive long -> invalid '$got'"

# --- smp_active_nas fallback rules (Sec 4.2) ---
( w=$(new_workspace)
  smp_active_nas >/dev/null 2>&1 && no "active: empty should fail" || ok "active: empty fails"; rm -rf "$w" )
( w=$(new_workspace)
  mkdir -p context/nas/only/; echo x > context/nas/only/profile.md
  out=$(smp_active_nas); [ "$out" = "only" ] && [ -f context/active-nas ] && ok "active: single self-heals" || no "active: single failed ($out)"; rm -rf "$w" )
( w=$(new_workspace)
  mkdir -p context/nas/a/ context/nas/b/; echo x>context/nas/a/profile.md; echo x>context/nas/b/profile.md
  smp_active_nas >/dev/null 2>&1 && no "active: multi w/o pointer should fail" || ok "active: multi w/o pointer fails"; rm -rf "$w" )
( w=$(new_workspace)
  mkdir -p context/nas/a/ context/nas/b/; echo x>context/nas/a/profile.md; echo x>context/nas/b/profile.md
  echo b > context/active-nas
  out=$(smp_active_nas); [ "$out" = "b" ] && ok "active: valid pointer honored" || no "active: pointer ignored ($out)"; rm -rf "$w" )
( w=$(new_workspace)
  printf '# old\n- hostname: nas9\n' > context/nas-profile.md
  smp_active_nas 2>&1 | grep -q "Legacy single-NAS" && ok "active: legacy hint" || no "active: no legacy hint"; rm -rf "$w" )

# --- smp_list_nas: sorted, ignores dirs without profile.md ---
( w=$(new_workspace)
  mkdir -p context/nas/zeta/ context/nas/alpha/ context/nas/empty/
  echo x>context/nas/zeta/profile.md; echo x>context/nas/alpha/profile.md
  out=$(smp_list_nas | tr '\n' ' '); [ "$out" = "alpha zeta " ] && ok "list: sorted, filtered" || no "list: got '$out'"; rm -rf "$w" )

# --- smp_load_profile: extracts + validates; key_path charset ---
( w=$(new_workspace); mkdir -p context/nas/main
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
  rm -rf "$w" )
( w=$(new_workspace); mkdir -p context/nas/main
  printf '## Connection\n- host: h\n- port: 22\n- user: u\n- key_path: /bad;rm\n' > context/nas/main/profile.md
  echo main > context/active-nas
  smp_load_profile >/dev/null 2>&1 && no "load: bad key_path accepted" || ok "load: bad key_path rejected"; rm -rf "$w" )

# --- smp_migrate: lossless + idempotent + resume ---
seed_legacy() {
  printf '# Synology NAS Profile\n- host: 192.168.1.10\n- port: 22\n- user: admin\n- hostname: nasbox\n' > context/nas-profile.md
  echo "report" > context/storage-report.md
  mkdir -p context/volumes context/mounts; echo v > context/volumes/v1.txt; echo m > context/mounts/current.txt
}
( w=$(new_workspace); seed_legacy
  smp_migrate >/dev/null
  if [ -f context/nas/nasbox/profile.md ] && [ -f context/nas/nasbox/storage-report.md ] \
     && [ -f context/nas/nasbox/volumes/v1.txt ] && [ -f context/nas/nasbox/mounts/current.txt ] \
     && [ "$(cat context/active-nas)" = "nasbox" ] && [ ! -f context/nas-profile.md ] \
     && [ ! -d context/volumes ]; then ok "migrate: lossless"; else no "migrate: layout wrong"; fi
  smp_migrate >/dev/null 2>&1; ok "migrate: re-run idempotent (no error)"
  rm -rf "$w" )
( w=$(new_workspace); seed_legacy
  mkdir -p context/.nas-migrate.tmp/junk context/nas/nasbox; echo partial > context/nas/nasbox/profile.md
  smp_migrate >/dev/null
  [ "$(cat context/active-nas)" = "nasbox" ] && grep -q 192.168.1.10 context/nas/nasbox/profile.md \
    && [ ! -d context/.nas-migrate.tmp ] && ok "migrate: resume lossless" || no "migrate: resume failed"
  rm -rf "$w" )

echo ""
echo "=== test-profile-lib: $pass pass, $fail fail ==="
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run — expect PASS**

Run: `bash tests/unit/test-profile-lib.sh`
Expected: all PASS, exit 0. If any case fails, fix `_profile-lib.sh` — the test is the spec of correct behavior. Then re-run.

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
Expected: includes `PASS: _profile-lib.sh` and `PASS: _compose-lib.sh`; exit 0.

- [ ] **Step 3: Commit**

```bash
git commit -m "test: shellcheck the shared command libraries directly" -- tests/static/shellcheck-commands.sh
```

---

## Task 4: Finalize the canonical inline resolver block

This block is the inline equivalent of `smp_migrate`-detection + `smp_active_nas` + `smp_load_profile` + `smp_build_ssh`. It is pasted verbatim into each retrofitted command (Tasks 5–6). **Defined once here; later tasks reference "the canonical resolver block".**

```bash
set -euo pipefail

# === synology-manager-plus: resolve active NAS profile (multi-NAS layout) ===
# Mirrors plugin/commands/_profile-lib.sh (canonical, unit-tested). Commands
# cannot source libs, so this block is embedded inline. Keep in sync with the lib.
SMP_SLUG_RE='^[a-z0-9][a-z0-9-]{0,31}$'

if [ -f context/nas-profile.md ] && [ ! -d context/nas ]; then
  echo "Legacy single-NAS layout detected — run /first-run to upgrade to the multi-NAS layout." >&2
  exit 1
fi

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
    echo "No NAS configured. Run /first-run." >&2; exit 1
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
[[ "$KEY_PATH" =~ ^[A-Za-z0-9_./-]+$ ]] || { echo "Invalid key_path: $KEY_PATH" >&2; exit 1; }
[ -f "$KEY_PATH" ] || { echo "SSH key not found: $KEY_PATH" >&2; exit 1; }

SSH=( ssh -i "$KEY_PATH" -o ConnectTimeout="$CONNECT_TIMEOUT" -p "$PORT" "$NAS_USER@$HOST" )
# === end resolver block ===
```

- [ ] **Step 1: Sanity-check the block in isolation before pasting it 14×**

Save the block to `/tmp/smp-block.sh`, prepend `#!/usr/bin/env bash`, run:
`shellcheck --severity=warning --shell=bash /tmp/smp-block.sh`
Expected: exit 0 (no warnings). If a warning appears, fix the block here and update Task 1's lib to match, then re-run Task 2.

(No commit — this task only validates the reused artifact.)

---

## Task 5: Retrofit `nas-status.md` (worked example)

**Files:**
- Modify: `plugin/commands/nas-status.md`

- [ ] **Step 1: Replace the profile-extraction + SSH-array blocks**

In `nas-status.md`, the first ```bash block (the `PROFILE="context/nas-profile.md"` extraction) AND the `SSH=( ... )` array block are replaced by the **canonical resolver block** (Task 4). Delete both old blocks; insert the resolver block once where the first block was. The query commands that follow (`"${SSH[@]}" "df -h"` etc.) are unchanged — the block provides the same `SSH` array.

- [ ] **Step 2: Make the state-write path NAS-relative**

Change the prose + write target from `context/storage-report.md` to `context/nas/$SLUG/storage-report.md` (`$SLUG` is set by the resolver block).

- [ ] **Step 3: Update the intro prose**

Replace "Read `context/nas-profile.md` and extract values" with: "Resolve the active NAS via the canonical resolver block (mirrors `_profile-lib.sh`); it sets `HOST/PORT/NAS_USER/CONNECT_TIMEOUT/KEY_PATH/SLUG` and the `SSH` array." Keep the `NAS_USER` (not `$USER`) note.

- [ ] **Step 4: Static check**

Run: `bash tests/static/shellcheck-commands.sh && bash tests/static/frontmatter-check.sh && bash tests/static/markdown-lint.sh`
Expected: `PASS: nas-status` in each; exit 0.

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor: nas-status uses multi-NAS resolver and per-NAS state path" -- plugin/commands/nas-status.md
```

---

## Task 6: Retrofit the remaining 13 profile-reading commands

Apply the **exact same transformation** as Task 5 to each command below: delete its `PROFILE="context/nas-profile.md"` extraction block and its `SSH=( ... )` block, insert the **canonical resolver block** (Task 4) once, and update NAS-relative state paths per the table. The transformation is mechanical and identical; only the state-path column differs.

| Command file | Special handling beyond the resolver block |
|---|---|
| `smart-status.md` | none (read-only). |
| `health-summary.md` | Its lazy `cpu_cores`/temp migration writes to the profile — change the target to `context/nas/$SLUG/profile.md`. |
| `list-shares.md` | Volume snapshot path → `context/nas/$SLUG/volumes/<vol>-snapshot.txt`. |
| `manage-mounts.md` | Mounts path → `context/nas/$SLUG/mounts/current.txt` (all references). |
| `logs.md` | Keep its existing `--source/--last/--grep` arg-parsing block; only the profile/SSH blocks are replaced. |
| `dsm-update-check.md` | none. |
| `docker-list.md` | none (`/usr/local/bin/docker` absolute path unchanged). |
| `compose-list.md` | none. |
| `compose-up.md` | none. |
| `compose-logs.md` | none. |
| `compose-update.md` | none. |
| `compose-down.md` | **Preserve** its `critical_compose_projects` lazy-migration block AND its inline `is_critical_compose_project()` function. Only the `PROFILE=`/extraction/`SSH=` parts are replaced. The lazy-migration `awk ... > "$PROFILE"` now targets the resolved `$PROFILE` (= `context/nas/$SLUG/profile.md`); `CRIT_LIST` extraction stays, reading from `$PROFILE`. |
| `diag.md` | Replace `[ -f context/nas-profile.md ]` with the resolver block; the "Profile present/missing" health line becomes "Active NAS resolvable" (success when the block resolves; failure message when it exits). |

- [ ] **Step 1:** Retrofit the no-special-handling group: `smart-status.md`, `dsm-update-check.md`, `docker-list.md`, `compose-list.md`, `compose-up.md`, `compose-logs.md`, `compose-update.md`.

- [ ] **Step 2:** Retrofit the state-path group: `health-summary.md`, `list-shares.md`, `manage-mounts.md`.

- [ ] **Step 3:** Retrofit the special cases: `logs.md` (preserve arg-parsing), `compose-down.md` (preserve critical-list logic + inline function), `diag.md` (rework profile health line).

- [ ] **Step 4: Static checks for all**

Run: `bash tests/static/shellcheck-commands.sh && bash tests/static/frontmatter-check.sh && bash tests/static/markdown-lint.sh`
Expected: `PASS` for every command; exit 0. Fix any shellcheck warning by aligning the pasted block.

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor: route all read commands through the multi-NAS resolver" -- plugin/commands/smart-status.md plugin/commands/dsm-update-check.md plugin/commands/docker-list.md plugin/commands/compose-list.md plugin/commands/compose-up.md plugin/commands/compose-logs.md plugin/commands/compose-update.md plugin/commands/health-summary.md plugin/commands/list-shares.md plugin/commands/manage-mounts.md plugin/commands/logs.md plugin/commands/compose-down.md plugin/commands/diag.md
```

---

## Task 7: `/first-run` — migration + per-NAS write + idempotency

**Files:**
- Modify: `plugin/commands/first-run.md`

- [ ] **Step 1: Add a migration step at the very top of the command body**

Before "Step 2. Detect existing config", add "Step 0. Migrate legacy layout (one-time)" with this bash block (inline equivalent of `smp_migrate` + `smp_derive_slug`; mirrors `_profile-lib.sh`):

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
  rm -rf context/volumes context/mounts
  echo "[migration] single-NAS workspace migrated to context/nas/$smp_slug/"
fi
```

- [ ] **Step 2: Change profile write target + idempotency detection**

- Step 2 ("Detect existing config"): detect via `context/active-nas` + `context/nas/<slug>/profile.md` (NOT `context/nas-profile.md`). If configured, ask Refresh/Cancel as today.
- Step 7 ("Write context files"): write the profile to `context/nas/<slug>/profile.md` (derive `<slug>` from discovered hostname using the same normalize+validate logic, fallback `main`); set `context/active-nas` to that slug atomically. Keep `- key_path: ~/.ssh/synology-manager-plus_ed25519` for the first NAS. Volumes → `context/nas/<slug>/volumes/volume1-snapshot.txt`; mounts → `context/nas/<slug>/mounts/current.txt`.

- [ ] **Step 3: CLAUDE.md managed section (Phase-1 form)**

Render the same Quick Reference table as today. **Do NOT add the `Active NAS:` header or the `(see /nas-list ...)` hint** — `/nas-list` does not exist until Phase 2 (spec R2-2). Leave the marker-count safety logic unchanged.

- [ ] **Step 4: Static checks**

Run: `bash tests/static/shellcheck-commands.sh && bash tests/static/frontmatter-check.sh && bash tests/static/markdown-lint.sh`
Expected: `PASS: first-run`; exit 0.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat: first-run migrates legacy layout and writes per-NAS profile" -- plugin/commands/first-run.md
```

---

## Task 8: `/setup-ssh` — NAS-relative profile

**Files:**
- Modify: `plugin/commands/setup-ssh.md`

- [ ] **Step 1: Resolve + write the active NAS profile**

- Step 1: resolve the active profile path. If `context/active-nas` + `context/nas/<slug>/profile.md` exist, read from there; if legacy `context/nas-profile.md` exists with no per-NAS layout, print the legacy hint and tell the user to run `/first-run`; if nothing exists, ask (as today) and target `context/nas/main/profile.md` with `context/active-nas=main`.
- Step 5 (on success): write/update `context/nas/<slug>/profile.md` instead of `context/nas-profile.md`, preserving the `key_path`/`connect_timeout_seconds` rules.

- [ ] **Step 2: Static checks**

Run: `bash tests/static/shellcheck-commands.sh && bash tests/static/frontmatter-check.sh && bash tests/static/markdown-lint.sh`
Expected: `PASS: setup-ssh`; exit 0.

- [ ] **Step 3: Commit**

```bash
git commit -m "refactor: setup-ssh reads and writes the per-NAS profile" -- plugin/commands/setup-ssh.md
```

---

## Task 9: Keep integration smoke tests green

The 18 integration smoke tests reimplement command logic against the Mock-NAS and write the profile to `$HOME/nas-profile.md` (they do **not** exec the command markdown), so the retrofit does not break them.

**Files:**
- Modify: `tests/integration/lib/test-helpers.sh`

- [ ] **Step 1: Add a `hostname` line to `write_test_profile`**

In the heredoc inside `write_test_profile`, add a `## Software` section with `- hostname: mocknas` so any test that exercises migration derives a deterministic slug (`mocknas`).

- [ ] **Step 2: Run the full suite if Docker is available**

Run: `bash tests/integration/run-all.sh`
Expected: `[run-all] PASS unit: test-profile-lib.sh` and all 18 integration tests pass. (No Docker locally → rely on CI `validate.yml`.)

- [ ] **Step 3: Commit**

```bash
git commit -m "test: include hostname in test profile for deterministic migration" -- tests/integration/lib/test-helpers.sh
```

---

## Task 10: Docs + version bump

**Files:**
- Modify: `CHANGELOG.md`, `plugin/.claude-plugin/plugin.json`

- [ ] **Step 1: Add a CHANGELOG entry** (plain, factual; no "phase", no AI phrasing)

```markdown
## [0.5.0] - 2026-05-29

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

- [ ] **Step 2: Bump the version in `plugin.json`** → `"version": "0.5.0"` (must match the CHANGELOG header — `validate-manifests.sh` enforces).

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

- [ ] `bash tests/unit/test-profile-lib.sh` → all PASS.
- [ ] `for s in tests/static/*.sh; do bash "$s" || exit 1; done` → all PASS (incl. `_profile-lib.sh` + `_compose-lib.sh` shellchecked).
- [ ] `bash tests/integration/run-all.sh` (or CI) → unit + 18 integration tests PASS.
- [ ] Manual real-hardware check (DS218+): with a legacy `context/nas-profile.md`, run `/first-run` once → workspace migrated to `context/nas/<slug>/`, `context/active-nas` set, `/nas-status` and `/health-summary` behave exactly as before.
- [ ] Spec Phase-1 acceptance checklist (Sec 10) all satisfied.

---

## Self-Review notes (gaps the implementer must watch)

- **Inline/lib drift:** the resolver block (Task 4) and `_profile-lib.sh` (Task 1) must stay logically equivalent. Change one → change both → re-run Task 2.
- **`compose-down` is the trickiest retrofit:** preserve the `critical_compose_projects` lazy migration AND the inline `is_critical_compose_project()`; only swap profile-extraction/SSH parts.
- **Migration runs only in `/first-run`:** every other command merely *detects* the legacy layout and tells the user to run `/first-run`. Do not paste the migration block into the 14 read commands.
- **CLAUDE.md `/nas-list` hint is Phase 2:** do not reference `/nas-list` anywhere user-visible in Phase 1.
- **Profiles that predate `hostname`:** the migration treats a missing/`_not configured_` hostname as empty → slug `main`. Real migrated profiles keep their `key_path` (`synology-manager-plus_ed25519`) unchanged (NG6).
