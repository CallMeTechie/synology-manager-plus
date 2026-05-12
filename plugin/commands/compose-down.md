---
description: Stop a Compose stack. Default 'compose stop' keeps project indexed for fast restart. Use --remove for full 'compose down' (container+network teardown). Critical projects need SM_CONFIRM_CRITICAL=yes.
argument-hint: "<project> [--remove]"
allowed-tools: Bash, Read
---

# Compose Down

Compose-Stack stoppen. Default: `compose stop` (Projekt bleibt im Index als
`exited` → `/compose-up` findet es sofort wieder). Mit `--remove`: volles
`compose down` (Container + Network entfernt, Projekt aus Index).

Schützt critical projects via Whitelist.

## Profile extraction + lazy migration

```bash
set -euo pipefail

PROFILE="context/nas-profile.md"
[ -f "$PROFILE" ] || { echo "Profile missing — run /first-run first" >&2; exit 1; }

if ! grep -q '^- critical_compose_projects:' "$PROFILE"; then
  TMP=$(mktemp)
  awk '
    /^- sudo_passwordless:/ {
      print
      print "- critical_compose_projects:"
      next
    }
    { print }
  ' "$PROFILE" > "$TMP" && mv "$TMP" "$PROFILE"
fi

for field in host port user; do
  if grep -qE "^- ${field}: _not configured_" "$PROFILE"; then
    echo "Profile not yet configured — run /first-run" >&2
    exit 1
  fi
done

HOST=$(awk '/^- host:/ {print $3; exit}' "$PROFILE")
PORT=$(awk '/^- port:/ {print $3; exit}' "$PROFILE")
NAS_USER=$(awk '/^- user:/ {print $3; exit}' "$PROFILE")
CONNECT_TIMEOUT=$(awk '/^- connect_timeout_seconds:/ {print $3; exit}' "$PROFILE")
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
CRIT_LIST=$(awk -F': ' '/^- critical_compose_projects:/ {print $2; exit}' "$PROFILE")

[[ "$HOST" =~ ^[a-zA-Z0-9.-]+$ ]] || exit 1
[[ "$PORT" =~ ^[0-9]{1,5}$ ]] || exit 1
[[ "$NAS_USER" =~ ^[a-zA-Z0-9_.-]+$ ]] || exit 1
```

## Argument parsing — project REQUIRED, --remove optional

```bash
project=""
remove_flag=0
for arg in ${ARGUMENTS:-}; do
  case "$arg" in
    --remove) remove_flag=1 ;;
    "") ;;
    -*) echo "Unknown flag: $arg" >&2; exit 1 ;;
    *)  if [ -z "$project" ]; then project="$arg"
        else echo "Multiple positional args not allowed" >&2; exit 1
        fi ;;
  esac
done

if [ -z "$project" ]; then
  echo "ERROR: <project> is required." >&2
  echo "Usage: /compose-down <project> [--remove]" >&2
  exit 1
fi
[[ "$project" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "Invalid project name" >&2; exit 1; }
```

## Critical check

```bash
is_critical_compose_project() {
  local project="$1" list="$2"
  [ -z "$list" ] && return 1
  local -a entries
  IFS=',' read -ra entries <<< "$list"
  local entry
  for entry in "${entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [ -z "$entry" ] && continue
    [ "$entry" = "$project" ] && return 0
  done
  return 1
}

if is_critical_compose_project "$project" "$CRIT_LIST"; then
  echo "WARNING: '$project' is in critical_compose_projects whitelist." >&2
  if [ "${SM_CONFIRM_CRITICAL:-no}" != "yes" ]; then
    echo "ERROR: refusing to stop critical project without SM_CONFIRM_CRITICAL=yes." >&2
    exit 1
  fi
else
  if [ -z "$CRIT_LIST" ]; then
    echo "(Tip: configure 'critical_compose_projects' in nas-profile.md to enable confirmation prompts.)" >&2
  fi
fi
```

## SSH + daemon precheck + discovery

```bash
SSH=( ssh -i "$HOME/.ssh/synology-manager-plus_ed25519" -o ConnectTimeout="$CONNECT_TIMEOUT" -p "$PORT" "$NAS_USER@$HOST" )

DOCKER_INFO=$("${SSH[@]}" "sudo -n /usr/local/bin/docker info --format '{{.ServerVersion}}' 2>&1" || true)
if ! echo "$DOCKER_INFO" | grep -q '^[0-9][0-9]*\.[0-9]'; then
  echo "ERROR: docker daemon unreachable. Run /compose-list for diagnostics." >&2
  exit 1
fi

PROJECTS=$("${SSH[@]}" "sudo -n /usr/local/bin/docker compose ls --all --format json")
ENTRY=$(echo "$PROJECTS" | jq -r --arg p "$project" '.[] | select(.Name == $p) | {Status, ConfigFiles} | @json')
if [ -z "$ENTRY" ] || [ "$ENTRY" = "null" ]; then
  echo "ERROR: project '$project' not found." >&2
  exit 1
fi
STATUS=$(echo "$ENTRY" | jq -r '.Status')
CONFIG_FILE=$(echo "$ENTRY" | jq -r '.ConfigFiles' | head -1)

if echo "$STATUS" | grep -qE "^(exited|created)"; then
  if [ "$remove_flag" -eq 1 ]; then
    echo "Project '$project' is already stopped ($STATUS), but --remove was specified — proceeding to tear down containers/network."
  else
    echo "Project '$project' is already stopped ($STATUS) — nothing to do."
    echo "(Use --remove to also clean up containers and network.)"
    exit 0
  fi
fi
```

## Stop or Down

```bash
if [ "$remove_flag" -eq 1 ]; then
  ACTION="down"
else
  ACTION="stop"
fi

# Capture exit code without `set -e` aborting prematurely.
# shellcheck disable=SC2029
if "${SSH[@]}" "sudo -n /usr/local/bin/docker compose -f '$CONFIG_FILE' $ACTION 2>&1"; then
  EXIT_CODE=0
else
  EXIT_CODE=$?
fi

if [ $EXIT_CODE -ne 0 ]; then
  echo "ERROR: 'docker compose $ACTION' failed (exit $EXIT_CODE)." >&2
  exit $EXIT_CODE
fi

sleep 1
if [ "$remove_flag" -eq 1 ]; then
  # After 'down', project disappears from compose ls --all (no
  # containers/network left). Report removal verdict.
  STILL=$("${SSH[@]}" "sudo -n /usr/local/bin/docker compose ls --all --format json" | jq -r --arg p "$project" '.[] | select(.Name == $p) | .Name')
  if [ -z "$STILL" ]; then
    echo ""
    echo "Verdict: removed (containers + network deleted, project no longer indexed)."
  else
    echo ""
    echo "Verdict: down requested, but project '$project' still in index — check raw output above."
  fi
else
  # After 'stop', project stays in index with status 'exited(N)'.
  NEW=$("${SSH[@]}" "sudo -n /usr/local/bin/docker compose ls --all --format json" | jq -r --arg p "$project" '.[] | select(.Name == $p) | .Status')
  echo ""
  echo "Verdict: stopped (status: $NEW) — project remains in index for fast /compose-up."
fi
```
