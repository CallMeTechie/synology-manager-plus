#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMANDS_DIR="$ROOT/plugin/commands"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

fail_count=0

for md in "$COMMANDS_DIR"/*.md; do
  name=$(basename "$md" .md)
  awk '
    /^```bash/ { capture=1; next }
    /^```sh/ { capture=1; next }
    /^```/ { capture=0; next }
    capture { print }
  ' "$md" > "$TMPDIR/${name}.sh"

  [ -s "$TMPDIR/${name}.sh" ] || continue

  # Wrap snippets WITHOUT pre-defining variables — that would hide real
  # bugs (undefined vars, word-splitting). Use shellcheck disable directives
  # only for the things we genuinely cannot test in isolation:
  #   SC2154 — variables come from a parent context (the command's profile-
  #            extraction prelude, which is in a separate code block).
  #   SC2034 — "appears unused" — same reason; vars are referenced across
  #            multiple snippets within the same command.
  {
    echo '#!/usr/bin/env bash'
    echo '# shellcheck disable=SC2154,SC2034'
    cat "$TMPDIR/${name}.sh"
  } > "$TMPDIR/${name}-wrapped.sh"

  if shellcheck --severity=warning --shell=bash "$TMPDIR/${name}-wrapped.sh"; then
    echo "PASS: $name"
  else
    echo "FAIL: $name (see shellcheck output above)"
    fail_count=$((fail_count + 1))
  fi
done

if [ $fail_count -gt 0 ]; then
  echo "$fail_count command(s) failed shellcheck."
  exit 1
fi

echo "All command shell snippets pass shellcheck."
