# synology-manager-plus

A Claude Code plugin for managing one or more Synology NAS via SSH. Commands for setup, diagnostics, storage, SMART health, logs, DSM update monitoring, Docker/Compose, and multi-NAS management — all SSH-based, no DSM Web API required.

**This is a fork** of [`danielrosehill/synology-manager-plugin`](https://github.com/danielrosehill/synology-manager-plugin). The fork addresses three blockers in the upstream v0.1.0 and grows the command set over successive releases. Original credit to Daniel Rosehill.

**Latest version:** v0.8.0. Baseline verified against DSM 7.3.1-86003 on a DS218+.

## What's different from the original

|Area|Original v0.1.0|This fork (current)|
|---|---|---|
|Installation|`claude plugin install danielrosehill/...` did not work — no marketplace manifest in repo|Marketplace manifest included; `claude plugin marketplace add` works directly|
|`/first-run`|Sub-agent that could not maintain a multi-turn dialog|Slash command in main context using `AskUserQuestion`|
|SSH setup|Manual: keygen, copy-id, profile editing|Guided `/setup-ssh` with copy-paste `!`-prefix flow|
|Health checks|Absent|`/diag` (setup), `/health-summary` (runtime), `/smart-status` (disks)|
|SMART disk monitoring|Absent|`/smart-status` with pass/warn/critical verdict per disk|
|Log viewer|Absent|`/logs` with source/timeframe/grep filters|
|DSM update check|Absent|`/dsm-update-check` (read-only, never auto-installs)|
|SSH key|Used `~/.ssh/id_ed25519`, conflicted with user keys|Plugin-owned `~/.ssh/synology-manager-plus_ed25519`|
|Connect timeout|Hard-coded 5s, broke on WAN/VPN|Default 10s, configurable per-profile|
|User notes in CLAUDE.md|Could be overwritten by `/first-run` re-run|Protected via managed-section markers|
|Tests|None|Static checks + Mock-NAS smoke suite + unit tests (profile-lib, sudo-lib, compose) in CI|
|Docker management|Absent|6 /compose-* and /docker-list commands; `/setup-docker-sudo` installs the passwordless sudoers drop-in via the DSM Task Scheduler|

## Installation

```bash
claude plugin marketplace add CallMeTechie/synology-manager-plus
claude plugin install synology-manager-plus@synology-manager-plus
```

## First steps

1. Open the plugin workspace as your Claude Code project.
2. Run `/first-run` — answer host, port, user, follow the `! ssh-copy-id ...` instruction (type it literally including the `!`).
3. Run `/diag` to verify all 7 health checks pass.

## Commands

|Command|Description|
|---|---|
|`/first-run`|Interactive setup wizard (one-time, idempotent)|
|`/setup-ssh`|Standalone SSH key setup|
|`/setup-docker-sudo`|Guided passwordless docker-sudo setup via DSM Task Scheduler|
|`/diag`|7-point health check (read-only)|
|`/nas-status`|Disk usage, RAID, services, load (`--all` for fleet view)|
|`/list-shares`|List shared folders, refresh volume snapshots|
|`/manage-mounts`|View/add/remove NFS or SMB mounts|
|`/smart-status`|SMART health per disk (text-parsing, smartctl 6.5) (`--all` for fleet view)|
|`/health-summary`|One-page NAS health aggregate (`--all` for fleet view)|
|`/logs`|Filterable log viewer (system/ssh/package/docker)|
|`/dsm-update-check`|Read-only DSM update status|
|`/compose-list`|List all Compose projects (running + stopped)|
|`/docker-list`|Flat container listing with Compose-label awareness|
|`/compose-logs`|Filter-able Compose-Logs-Viewer|
|`/compose-up`|Start a stopped Compose stack|
|`/compose-down`|Stop a Compose stack (with critical-project whitelist)|
|`/compose-update`|Pull + restart a Compose stack atomically|
|`/nas-list`|List configured NAS, mark active|
|`/nas-use`|Switch the active NAS|
|`/nas-add`|Add another NAS (own key + discovery)|
|`/nas-remove`|Remove a NAS profile|

## Managing multiple NAS

The plugin tracks one **active NAS** (`context/active-nas`); every command targets it
by default. Each NAS lives under `context/nas/<slug>/`, with its own SSH key.

- `/nas-list` — show all configured NAS and which is active.
- `/nas-add` — add another NAS (prompts for a slug, generates a dedicated key, discovers hardware).
- `/nas-use <slug>` — switch the active NAS; the workspace Quick Reference updates to match.
- `/nas-remove <slug>` — delete a NAS profile (optionally its key), with confirmation.

Read-only overviews accept `--all` to sweep every configured NAS with a fleet verdict.

## Migration from `danielrosehill/synology-manager-plugin`

```bash
claude plugin uninstall synology-manager
claude plugin marketplace add CallMeTechie/synology-manager-plus
claude plugin install synology-manager-plus@synology-manager-plus
```

If your old plugin had a populated `context/` directory with snapshots, copy them manually into the new plugin workspace's `context/nas/<slug>/volumes/` and `context/nas/<slug>/mounts/` — the new install starts blank and `/first-run` creates `context/nas/<slug>/` and refills the rest.

## Troubleshooting

**`/setup-ssh` says my password is wrong, but I'm sure it's right.**
Make sure you typed the command with `!` at the start. Without `!`, Claude tries to run it as a normal Bash call, which has no terminal for password entry and hangs. The `!` opens an interactive terminal where the password prompt actually works.

**`/diag` says SSH is unreachable, but I can SSH manually.**
Check `connect_timeout_seconds` in `context/nas/<slug>/profile.md`. Default is 10. For VPN tunnels with cold-start latency, raise it to 20–30. Range 3–60.

**Re-running `/first-run` deleted my notes in `CLAUDE.md`.**
Notes outside the `<!-- synology-manager-plus:managed-start -->` and `:managed-end` markers are protected. If your CLAUDE.md does not have those markers (e.g. migrated from upstream), `/first-run` shows you a diff and asks before touching anything.

**`/smart-status` says "SMART support: Unavailable" or all disks fall to the schema-drift path.**
DSM ships smartmontools 6.5 and identifies SATA disks via `--scan` as SCSI, which doesn't return SMART attributes. Set `smartctl_device_type: ata` (or `sat` on newer drives) in `context/nas/<slug>/profile.md` under `## Hardware`. The plugin uses this hint via `smartctl -d <type>` for every disk read.

**`/smart-status` or `/dsm-update-check` need a password.**
Both commands need passwordless sudo for `smartctl` and `synoupgrade`. DSM has no `visudo`, so use a sudoers drop-in:

```bash
ssh your-nas
echo 'YOUR_USER ALL=(ALL) NOPASSWD: /usr/bin/smartctl, /usr/syno/sbin/synoupgrade' \
  | sudo tee /etc/sudoers.d/synology-manager-plus
sudo chmod 0440 /etc/sudoers.d/synology-manager-plus
```

DSM may reset `/etc/sudoers.d/` after a major DSM upgrade — the commands will surface the same diagnostic and you can re-apply the drop-in.

**`/logs --source=system` says "permission denied".**
DSM's `/var/log/messages` is `root:log` mode 660, and `/var/log/synolog/*` is often root-only. The plugin offers two options in the error message: add your user to the `log` group (`sudo synogroup --member add log YOUR_USER`, log out and back in), or extend the sudoers drop-in with `NOPASSWD: /usr/bin/tail` (broader scope, easier to undo).

**`/logs --source=docker` says "permission denied while trying to connect to the Docker daemon".**
The DSM default user is not in the `docker` group. The plugin shows the same two options (group membership vs. sudoers entry on `/usr/local/bin/docker`).

**`/dsm-update-check` says "Status: UNKNOWN".**
Synology can change `synoupgrade --check` status-code constants without notice. The plugin fails loud with the raw status code and the first 200 chars of output instead of silently mapping to "up-to-date" — that would risk missed security updates. Open DSM Web UI → Control Panel → Update & Restore to verify manually, and (if you have time) open an issue with the unknown code so I can extend the mapping.

**`/compose-list` says "passwordless sudo for /usr/local/bin/docker is not configured".**
Run `/setup-docker-sudo` — it generates a root script and walks you through the DSM
Task Scheduler (the only reliable way to run a one-off root script on DSM) to install
the `NOPASSWD: /usr/local/bin/docker` drop-in, then verifies it.

Advanced/manual alternative (admin users who prefer to do it over SSH):

```bash
ssh your-nas
echo "$USER ALL=(ALL) NOPASSWD: /usr/local/bin/docker" | \
  sudo tee /etc/sudoers.d/synology-manager-plus-docker
sudo chmod 0440 /etc/sudoers.d/synology-manager-plus-docker
```

For DSM users already in `administrators` (which is `(ALL) ALL`),
the NOPASSWD override only adds **passwordless** access for docker —
it does not expand what the user could already do.

**Docker commands say "a password is required".**

Passwordless sudo for `/usr/local/bin/docker` is missing (DSM updates wipe the
`sudoers.d` drop-in). Run `/setup-docker-sudo` — it generates a root script, walks
you through the DSM Task Scheduler (the only reliable way to run a one-off root
script on DSM), and verifies the result.

**`/compose-update` aborts with ".env unreadable".**
On DSM, Compose projects created via Container-Manager UI sometimes
leave the `.env` as `root:root` mode `600`. The plugin fails loud
rather than letting Compose silently substitute `${VARS}` to empty
strings. Fix:

```bash
ssh your-nas
sudo chmod 0640 /volume1/docker/<project>/.env
sudo chown :docker /volume1/docker/<project>/.env
```

**`/compose-down` won't stop my project even with `<project>` argument.**
The project is in `critical_compose_projects` whitelist. Either remove
it from `context/nas/<slug>/profile.md`, or invoke with
`SM_CONFIRM_CRITICAL=yes` as an environment variable. Critical projects
are protected from accidental `down`.

**`docker compose pull` fails for one of my services.**
If a service has `build:` instead of `image:`, Compose's `pull` returns
non-zero. `/compose-update` aborts before `up -d` runs. For build-based
services, run manually:

```bash
ssh your-nas
cd /volume1/docker/<project> && docker compose build && docker compose up -d
```

**`/compose-up <project>` says "not found" after I used `/compose-down --remove`.**
`--remove` runs `docker compose down` which deletes containers + network +
removes the project from the Compose index. The plugin then can't
discover it. To restart, run one manual command — afterwards the plugin
re-discovers it:

```bash
ssh your-nas
sudo -n /usr/local/bin/docker compose -f /volume1/docker/<project>/docker-compose.yml up -d
```

The default `/compose-down` (without `--remove`) avoids this — it uses
`compose stop`, so the project stays in the index as `exited` and
`/compose-up` works immediately.

**My NAS disk is filling up after many `/compose-down`/`/compose-up` cycles.**
The default `compose stop` keeps container writable layers, logs, and
networks for fast restart. Periodically clean up unused artifacts:

```bash
ssh your-nas
sudo -n /usr/local/bin/docker system prune    # removes stopped containers + unused networks
sudo -n /usr/local/bin/docker image prune     # removes dangling images
```

(The plugin does not auto-clean — explicit user action only.)

## Roadmap

### Shipped

- Docker and Compose operations (v0.4.0): `/compose-list`, `/compose-up`, `/compose-down`,
  `/compose-update`, `/compose-logs`, `/docker-list`.
- Multi-NAS management (v0.7.0): per-NAS profiles under `context/nas/<slug>/`, `/nas-list`,
  `/nas-use`, `/nas-add`, `/nas-remove`, and `--all` fleet fan-out on the overview commands.
- Passwordless docker-sudo setup (v0.8.0): `/setup-docker-sudo` installs the
  `NOPASSWD: /usr/local/bin/docker` drop-in via the DSM Task Scheduler, with verification.

### Planned

#### Backup and snapshots

- BTRFS snapshot management (list, create, restore)
- Hyper Backup integration (requires the DSM Web API)

#### Security and audit

- WireGuard / VPN status
- User and permissions management
- Failed-login audit, active sessions, security scan

#### DSM Web API layer

- SID-based auth with 2FA awareness
- Hyper Backup status/trigger, snapshot replication, app permissions

Design notes for each area live under `docs/superpowers/specs/`.

## License

MIT — see [LICENSE](LICENSE). Original work copyright © 2026 Daniel Rosehill. Modifications and fork copyright © 2026 Marc Backes.
