#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# Note: docs/superpowers/specs/*.md and docs/superpowers/plans/*.md are excluded
# because they are design artifacts that have been reviewed by the user and contain
# dense tables and code blocks that would require significant reformatting.
# This script focuses on linting actual repo output files (README, CHANGELOG, plugin files).

markdownlint-cli2 \
  "README.md" \
  "CHANGELOG.md" \
  "plugin/CLAUDE.md" \
  "plugin/commands/*.md"
