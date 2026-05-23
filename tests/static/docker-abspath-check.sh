#!/usr/bin/env bash
set -euo pipefail

# Regression guard for the DSM "/usr/local/bin not in non-interactive SSH PATH"
# class of bug.
#
# On DSM 7.x, `ssh user@nas "command"` runs a non-interactive, non-login shell
# that does NOT source /etc/profile, so /usr/local/bin (where Container Manager
# installs docker) is absent from PATH. Bare `docker ...` therefore fails to
# resolve, and discovery wrongly reports docker as "not installed" while
# `/logs --source=docker` reports no containers — even though docker is present
# at /usr/local/bin/docker.
#
# Every command that EXECUTES docker over SSH must use the absolute path
# /usr/local/bin/docker (the convention all /compose-* commands already follow).
# This check scans the executable portions of every command file and fails if
# any of them invoke docker by bare name.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMANDS_DIR="$ROOT/plugin/commands"

fail_count=0

# Extract the parts of a command file that actually RUN:
#   - .md: only fenced ```bash / ```sh blocks (frontmatter `description:` and
#          prose are skipped — they legitimately mention "docker compose pull").
#   - .sh: the whole file.
# Then drop comment lines and diagnostic echo/printf lines, which routinely
# contain the word "docker" inside human-readable messages ("docker daemon
# unreachable", "docker info: $X") and are not executions.
extract_executable() {
  local file="$1"
  case "$file" in
    *.md)
      awk '
        /^```bash/ { capture=1; next }
        /^```sh/   { capture=1; next }
        /^```/     { capture=0; next }
        capture    { print }
      ' "$file"
      ;;
    *)
      cat "$file"
      ;;
  esac
}

scan_file() {
  local file="$1"
  local name
  name=$(basename "$file")

  local line stripped clean
  local lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))

    # Skip comment lines and pure diagnostic output lines.
    stripped="${line#"${line%%[![:space:]]*}"}"   # ltrim
    case "$stripped" in
      \#*|echo\ *|echo\"*|printf\ *) continue ;;
    esac

    # Neutralise the SAFE absolute path so it never trips the bare-docker
    # patterns below. Anything left as `docker <subcommand>` is a real bug.
    clean="${line//\/usr\/local\/bin\/docker/__ABS_DOCKER__}"

    # (1) Existence probe on bare name — the exact first-run discovery bug.
    if [[ "$clean" == *"command -v docker"* ]]; then
      echo "FAIL: $name:$lineno uses 'command -v docker' (bare) — use [ -x /usr/local/bin/docker ]"
      echo "    $line"
      fail_count=$((fail_count + 1))
      continue
    fi

    # (2) Bare docker invoked with a subcommand (ps/logs/info/compose/...).
    if [[ "$clean" =~ (^|[^/[:alnum:]_])docker[[:space:]]+(ps|logs|info|compose|version|inspect|exec|pull|images|stats|--version) ]]; then
      echo "FAIL: $name:$lineno executes bare 'docker' — use /usr/local/bin/docker"
      echo "    $line"
      fail_count=$((fail_count + 1))
    fi
  done < <(extract_executable "$file")
}

shopt -s nullglob
for f in "$COMMANDS_DIR"/*.md "$COMMANDS_DIR"/*.sh; do
  scan_file "$f"
done

if [ "$fail_count" -gt 0 ]; then
  echo ""
  echo "$fail_count bare-docker invocation(s) found. On DSM these break because"
  echo "/usr/local/bin is not in the non-interactive SSH PATH. Use the absolute"
  echo "path /usr/local/bin/docker, as all /compose-* commands already do."
  exit 1
fi

echo "All command files invoke docker via /usr/local/bin/docker."
