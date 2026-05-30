---
description: Switch the active Synology NAS to the given slug and refresh the workspace Quick Reference. Local-only, no SSH.
allowed-tools: Bash, Read, Write, Edit
argument-hint: "<slug>"
---

# NAS Use

Switch which NAS subsequent commands target. Writes `context/active-nas` and re-renders the CLAUDE.md Quick Reference for the new active NAS (preserving the global Scoped Operations checklist and any user notes after the end marker).

```bash
set -euo pipefail

# --- parse the required positional <slug> ---
set -- ${ARGUMENTS:-}
slug="${1:-}"
[ -n "$slug" ] || { echo "Usage: /nas-use <slug>   (see /nas-list)" >&2; exit 1; }
[[ "$slug" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo "Invalid slug: $slug" >&2; exit 1; }
[ -f "context/nas/$slug/profile.md" ] || { echo "NAS '$slug' not found. See /nas-list." >&2; exit 1; }

ACTIVE=$(cat context/active-nas 2>/dev/null | head -1 || true)
ACTIVE="${ACTIVE%%[[:space:]]*}"
if [ "$ACTIVE" = "$slug" ]; then
  echo "Active NAS is already '$slug'."
  exit 0
fi

# --- switch the active pointer atomically ---
tmp=$(mktemp); printf '%s\n' "$slug" > "$tmp" && mv "$tmp" context/active-nas

# --- re-render CLAUDE.md (paste the canonical render_claude_md from the plan's shared section VERBATIM) ---
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
render_claude_md "$slug" || echo "(warning) Active NAS switched, but CLAUDE.md was not re-rendered — see message above." >&2

host=$(awk '/^- host:/ {print $3; exit}' "context/nas/$slug/profile.md")
echo "Active NAS is now '$slug' ($host)."
```
