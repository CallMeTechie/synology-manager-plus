---
description: Remove a Synology NAS profile, optionally delete its SSH key, and repoint the active NAS. Destructive, double-confirmed.
allowed-tools: Bash, Read, AskUserQuestion
argument-hint: "<slug>"
---

# NAS Remove

Delete a NAS profile. Destructive — confirmed twice (profile, then key separately).

## Validate + gather

```bash
set -euo pipefail
set -- ${ARGUMENTS:-}
slug="${1:-}"
[ -n "$slug" ] || { echo "Usage: /nas-remove <slug>   (see /nas-list)" >&2; exit 1; }
[[ "$slug" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo "Invalid slug: $slug" >&2; exit 1; }
[ -d "context/nas/$slug" ] || { echo "NAS '$slug' not found. See /nas-list." >&2; exit 1; }
host=$(awk '/^- host:/ {print $3; exit}' "context/nas/$slug/profile.md" 2>/dev/null || true)
key=$(awk '/^- key_path:/ {print $3; exit}' "context/nas/$slug/profile.md" 2>/dev/null || true)
key="${key/#\~/$HOME}"
total=$(find context/nas -mindepth 2 -maxdepth 2 -name profile.md 2>/dev/null | wc -l)
echo "About to remove '$slug' ($host). $total NAS configured."
```

## Confirm (two separate questions)

1. `AskUserQuestion`: "Remove NAS '<slug>' (<host>)? This deletes `context/nas/<slug>/`." — read `$total` from the live shell; if it is `1`, append " This is the last configured NAS — the workspace will be empty afterwards." Options: "Yes, remove" / "Cancel". If "Cancel" → stop.
2. `AskUserQuestion`: "Also delete the SSH key `<key>`?" Options: "Keep key (default)" / "Delete key". Set `DELETE_KEY=1` only if the user chose "Delete key".

## Perform removal

```bash
# Shared-key guard: never delete a key another profile still references (protects the migrated legacy key).
shared=0
for d in context/nas/*/; do
  [ "$d" = "context/nas/$slug/" ] && continue
  okp=$(awk '/^- key_path:/ {print $3; exit}' "${d}profile.md" 2>/dev/null || true)
  okp="${okp/#\~/$HOME}"
  [ "$okp" = "$key" ] && shared=1
done

rm -rf -- "context/nas/${slug:?slug empty}"

if [ "${DELETE_KEY:-0}" = "1" ] && [ "$shared" = "0" ] && [ -n "$key" ] && [ -f "$key" ]; then
  rm -f "$key" "${key}.pub"
  echo "Deleted SSH key $key"
elif [ "${DELETE_KEY:-0}" = "1" ] && [ "$shared" = "1" ]; then
  echo "Kept SSH key $key — still referenced by another NAS profile."
fi

# Repoint active (mirrors smp_repoint_active in _profile-lib.sh).
active=$(cat context/active-nas 2>/dev/null | head -1 || true); active="${active%%[[:space:]]*}"
if [ "$active" = "$slug" ]; then
  left=()
  if [ -d context/nas ]; then
    for d in context/nas/*/; do [ -f "${d}profile.md" ] && left+=("$(basename "$d")"); done
  fi
  if [ "${#left[@]}" -eq 1 ]; then
    printf '%s\n' "${left[0]}" > context/active-nas
    echo "Active NAS is now '${left[0]}'."
  else
    rm -f context/active-nas
    [ "${#left[@]}" -gt 1 ] && echo "No active NAS — run /nas-use <slug> (see /nas-list)."
  fi
fi
echo "Removed NAS '$slug'."
```
