#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMMANDS_DIR="$ROOT/plugin/commands"
ALLOWED_TOOLS="Bash Read Write Edit AskUserQuestion"

fail_count=0

for md in "$COMMANDS_DIR"/*.md; do
  name=$(basename "$md")
  fm=$(awk 'BEGIN{c=0} /^---$/{c++; next} c==1{print} c==2{exit}' "$md")

  if ! echo "$fm" | grep -q '^description:'; then
    echo "FAIL: $name missing 'description:' field"
    fail_count=$((fail_count + 1))
    continue
  fi

  desc=$(echo "$fm" | sed -n 's/^description: *//p' | head -1)
  desc_len=${#desc}
  if [ "$desc_len" -lt 20 ] || [ "$desc_len" -gt 200 ]; then
    echo "FAIL: $name description length $desc_len not in [20,200]"
    fail_count=$((fail_count + 1))
  fi

  if ! echo "$fm" | grep -q '^allowed-tools:'; then
    echo "FAIL: $name missing 'allowed-tools:' field"
    fail_count=$((fail_count + 1))
    continue
  fi

  tools=$(echo "$fm" | sed -n 's/^allowed-tools: *//p' | head -1)
  for t in $(echo "$tools" | tr ',' ' '); do
    t_trim=$(echo "$t" | xargs)
    if ! echo "$ALLOWED_TOOLS" | grep -qw "$t_trim"; then
      echo "FAIL: $name uses undocumented tool '$t_trim'"
      fail_count=$((fail_count + 1))
    fi
  done

  echo "PASS: $name"
done

if [ $fail_count -gt 0 ]; then
  echo "$fail_count frontmatter problem(s) found."
  exit 1
fi
echo "All command frontmatter is valid."
