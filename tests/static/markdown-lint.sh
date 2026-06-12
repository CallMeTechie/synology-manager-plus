#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# Lints the repository's published markdown: README, CHANGELOG, and plugin files.

markdownlint-cli2 \
  "README.md" \
  "CHANGELOG.md" \
  "plugin/CLAUDE.md" \
  "plugin/commands/*.md"
