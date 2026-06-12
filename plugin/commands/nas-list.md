---
description: List all configured Synology NAS profiles (slug, host, model, DSM) and mark the active one. Read-only, no SSH.
allowed-tools: Bash, Read
---

# NAS List

Show every configured NAS and which one is active. Reads only local profiles — no SSH.

```bash
set -euo pipefail
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [ ! -d context/nas ] || [ -z "$(find context/nas -mindepth 2 -maxdepth 2 -name profile.md 2>/dev/null | head -1)" ]; then
  if [ -f context/nas-profile.md ]; then
    echo "Legacy single-NAS layout detected — run /first-run to upgrade to the multi-NAS layout." >&2
  else
    echo "No NAS configured. Run /first-run." >&2
  fi
  exit 1
fi

ACTIVE=$(cat context/active-nas 2>/dev/null | head -1 || true)
ACTIVE="${ACTIVE%%[[:space:]]*}"

echo "Configured NAS — ${TS}"
echo ""
printf '   %-12s %-18s %-10s %s\n' "SLUG" "HOST" "MODEL" "DSM"
for d in context/nas/*/; do
  [ -f "${d}profile.md" ] || continue
  slug=$(basename "$d"); p="${d}profile.md"
  host=$(awk '/^- host:/ {print $3; exit}' "$p")
  model=$(awk -F': ' '/^- model:/ {print $2; exit}' "$p"); model="${model:-?}"
  dsm=$(awk -F': ' '/^- dsm_version:/ {print $2; exit}' "$p"); dsm="${dsm:-?}"
  if grep -qE "^- (host|port|user): _not configured_" "$p"; then host="(incomplete)"; fi
  mark="  "; [ "$slug" = "$ACTIVE" ] && mark=" ●"
  printf '%s %-12s %-18s %-10s %s\n' "$mark" "$slug" "${host:-?}" "$model" "$dsm"
done
echo ""
echo "Active: ${ACTIVE:-<none>}   (switch with /nas-use <slug>)"
```
