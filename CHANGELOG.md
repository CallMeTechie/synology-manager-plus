# Changelog

All notable changes to synology-manager-plus are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.2.0] — 2026-05-10

### Added
- `/setup-ssh` command — generates plugin-owned SSH keypair, walks through `! ssh-copy-id` deployment, verifies key auth.
- `/diag` command — 7-point read-only health check (profile, SSH reachability, key auth, sudo, df query, mount sanity).
- `connect_timeout_seconds` field in `nas-profile.md` (default 10, range 3–60).
- `<!-- synology-manager-plus:managed-start -->` / `:managed-end` markers in `CLAUDE.md` to protect user notes during `/first-run` re-runs.
- Static CI checks: JSON manifest validation, shellcheck on extracted bash snippets, markdown lint, frontmatter enforcement.
- Mock-NAS smoke tests against an Alpine+OpenSSH+DSM-stub container, one per command.
- Anti-pattern rule: plugin must never invoke `ssh-copy-id` via the Bash tool — verified to hang without a TTY.

### Changed
- `/first-run` rewritten as a main-context slash command using `AskUserQuestion`. The previous `synology-intake` sub-agent is removed (sub-agents cannot maintain multi-turn dialogs).
- All commands now use the plugin-owned key `~/.ssh/synology-manager-plus_ed25519` (was `~/.ssh/id_ed25519`).
- Default SSH connect timeout raised from 5s to 10s for WAN/VPN tolerance.
- All commands honour the configured port from `nas-profile.md` (upstream silently assumed 22).
- Repo layout reorganised to marketplace + `plugin/` subdirectory so `claude plugin marketplace add` works without local workarounds.

### Removed
- `agents/synology-intake.md` — broken sub-agent pattern, replaced by main-context `/first-run`.

### Fixed
- Marketplace installation — repo now contains `.claude-plugin/marketplace.json`, fixing the silent failure of `claude plugin install` against the upstream repo.

### Security
- Input validation on host (`^[a-zA-Z0-9.-]+$`) and port (`^[0-9]{1,5}$`) before every shell expansion to prevent injection.
- Plugin SSH key isolated from user keys — separate path, separate rotation.

---

## [0.1.0] — Original `danielrosehill/synology-manager-plugin`

Original plugin by Daniel Rosehill. See [upstream repo](https://github.com/danielrosehill/synology-manager-plugin) for its history.
