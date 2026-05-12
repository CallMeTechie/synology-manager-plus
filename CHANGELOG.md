# Changelog

All notable changes to synology-manager-plus are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.3.0] — 2026-05-12

### Added

- `/smart-status` command — SMART health per disk with pass/warn/critical verdict (text-parsing for smartctl 6.5, no JSON).
- `/health-summary` command — one-page aggregate (RAID, capacity, disk temperatures, memory, load, recent critical log entries). Read-only.
- `/logs` command — filterable log viewer for DSM system, ssh, package, and docker sources. Supports `--source`, `--last`, `--grep`, `--all-levels` flags via deterministic bash arg-parser.
- `/dsm-update-check` command — read-only DSM update status check. Maps DSM status-code constants (UPGRADE_*) to update-available/up-to-date/check-failed. Never auto-installs.
- Lazy profile-migration in `/health-summary` — auto-adds `cpu_cores` field to existing `nas-profile.md` files (atomic awk+mv pattern, idempotent).
- Four new optional `nas-profile.md` fields: `cpu_cores`, `disk_warn_temp_c`, `disk_critical_temp_c`, `smartctl_device_type` (all default sensibly when missing/placeholder).
- Mock-NAS extensions: smartctl 6.5 text-format stub with three disk profiles (healthy/warning/critical), stub log files, synoupgrade state-switchable stub.
- Four new bash-smoke tests in CI, total now 10/10 in `run-all.sh`.

### Changed

- Mock-NAS container now reacts to `MOCK_SYNOUPGRADE_STATE` env var for `synoupgrade --check` behavior selection (default: "new" / update-available).

### Pre-Implementation Notes

- Phase 2 design was verified against real DS218+ hardware (DSM 7.3.1-86003 + smartctl 6.5) before the plan was written. Mock-NAS smartctl profiles are derived from real `smartctl -d ata -a /dev/sda` output, redacted of disk serial numbers.

---

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
