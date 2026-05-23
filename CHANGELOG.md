# Changelog

All notable changes to synology-manager-plus are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.4.1] — 2026-05-23

### Fixed

- `/first-run` docker discovery and `/logs --source=docker` invoked docker by
  bare name. On DSM, a non-interactive SSH session does not source
  `/etc/profile`, so `/usr/local/bin` (where Container Manager installs docker)
  is not on PATH — discovery wrongly reported `docker_available: not installed`
  and the docker log source found no containers, even though docker was present
  at `/usr/local/bin/docker`. Both now use the absolute path, matching every
  `/compose-*` command. (Reported against DSM 7.3.1.)
- `/nas-status` invoked `synoservice` by bare name. `synoservice` lives in
  `/usr/syno/sbin`, also absent from the non-interactive SSH PATH, so the
  service list silently came back empty. It now uses the absolute path and
  degrades cleanly when the listing needs root.

### Added

- `tests/static/docker-abspath-check.sh` — CI guard that fails if any command
  executes docker by bare name. Wired into the Validate workflow.
- Integration coverage for the previously-untested service-discovery branches
  of `/first-run`, `/logs`, and `/nas-status` (each run against a PATH that
  omits `/usr/local/bin` and `/usr/syno/sbin`), plus the matching mock-NAS
  `docker version`/`logs`/`ps --format` and `synoservice` stubs.

## [0.4.0] — 2026-05-12

### Added

- `/compose-list` — read-only Compose-project overview
- `/compose-up [project]` — start a stopped stack
- `/compose-down <project>` — stop a stack, protected by
  `critical_compose_projects` whitelist
- `/compose-update <project>` — pull + restart in single SSH roundtrip
  with `&&`-chain (best-effort atomicity), JSON-diff verdict
- `/compose-logs <project>` — Compose-Logs-Viewer with tail/since/service
  filters
- `/docker-list` — flat container listing with Compose-label awareness
- `critical_compose_projects` profile field with lazy migration
- Pure-bash unit test for the critical-project predicate (no SSH)
- Mock-NAS docker + docker-compose stubs with daemon-state controls

### Security

- Plugin uses sudoers Drop-in for /usr/local/bin/docker (DSM has no
  pre-created docker-group; for users already in administrators with
  `(ALL) ALL`, the NOPASSWD override is a usability win, not a
  privilege expansion)
- Fail-loud on unreadable `.env` (Compose's silent variable-empty
  substitution would break stacks)
- `/compose-down` refuses to stop critical projects without explicit
  confirmation (`SM_CONFIRM_CRITICAL=yes`)

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

- This release was verified against real DS218+ hardware (DSM 7.3.1-86003 + smartctl 6.5) before the plan was written. Mock-NAS smartctl profiles are derived from real `smartctl -d ata -a /dev/sda` output, redacted of disk serial numbers.

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
