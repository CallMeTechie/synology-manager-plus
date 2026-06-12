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

# smp_repoint_active <removed-slug> — call AFTER context/nas/<removed-slug> is gone.
# If the removed NAS was active: 1 NAS left → make it active; >1 left → clear the
# pointer (user must /nas-use); 0 left → remove the pointer file.
smp_repoint_active() {
  local removed="$1" active
  active=$(cat context/active-nas 2>/dev/null | head -1 || true)
  active="${active%%[[:space:]]*}"
  [ "$active" = "$removed" ] || return 0   # active NAS unaffected
  local -a left=()
  local d
  if [ -d context/nas ]; then
    for d in context/nas/*/; do
      [ -f "${d}profile.md" ] && left+=("$(basename "$d")")
    done
  fi
  if [ "${#left[@]}" -eq 1 ]; then
    printf '%s\n' "${left[0]}" > context/active-nas
  else
    rm -f context/active-nas
  fi
}

# smp_verdict_rank <verdict> — map a per-NAS verdict to a numeric rank for worst-of
# aggregation. 0 = ok/pass ; 1 = warn/unreachable ; 2 = anything else (critical/fail).
smp_verdict_rank() {
  case "${1:-}" in
    ok|pass) echo 0 ;;
    warn|unreachable) echo 1 ;;
    *) echo 2 ;;
  esac
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
