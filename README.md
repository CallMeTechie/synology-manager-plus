# synology-manager-plus

A Claude Code plugin for managing a Synology NAS via SSH. Ten commands for setup, diagnostics, storage, SMART health, logs, and DSM update monitoring — all SSH-based, no DSM Web API required.

**This is a fork** of [`danielrosehill/synology-manager-plugin`](https://github.com/danielrosehill/synology-manager-plugin). The fork addresses three blockers in the upstream v0.1.0 and grows the command set across phases. Original credit to Daniel Rosehill.

**Latest version:** v0.3.0 (Phase 2 — Health & Watch). Verified against DSM 7.3.1-86003 on a DS218+.

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
|Tests|None|Static checks + 10 Mock-NAS smoke tests in CI|

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
|`/diag`|7-point health check (read-only)|
|`/nas-status`|Disk usage, RAID, services, load|
|`/list-shares`|List shared folders, refresh volume snapshots|
|`/manage-mounts`|View/add/remove NFS or SMB mounts|
|`/smart-status`|SMART health per disk (text-parsing, smartctl 6.5)|
|`/health-summary`|One-page NAS health aggregate|
|`/logs`|Filterable log viewer (system/ssh/package/docker)|
|`/dsm-update-check`|Read-only DSM update status|

## Migration from `danielrosehill/synology-manager-plugin`

```bash
claude plugin uninstall synology-manager
claude plugin marketplace add CallMeTechie/synology-manager-plus
claude plugin install synology-manager-plus@synology-manager-plus
```

If your old plugin had a populated `context/` directory with snapshots, copy them manually into the new plugin workspace's `context/volumes/` and `context/mounts/` — the new install starts blank and `/first-run` will refill the rest.

## Troubleshooting

**`/setup-ssh` says my password is wrong, but I'm sure it's right.**
Make sure you typed the command with `!` at the start. Without `!`, Claude tries to run it as a normal Bash call, which has no terminal for password entry and hangs. The `!` opens an interactive terminal where the password prompt actually works.

**`/diag` says SSH is unreachable, but I can SSH manually.**
Check `connect_timeout_seconds` in `context/nas-profile.md`. Default is 10. For VPN tunnels with cold-start latency, raise it to 20–30. Range 3–60.

**Re-running `/first-run` deleted my notes in `CLAUDE.md`.**
Notes outside the `<!-- synology-manager-plus:managed-start -->` and `:managed-end` markers are protected. If your CLAUDE.md does not have those markers (e.g. migrated from upstream), `/first-run` shows you a diff and asks before touching anything.

**`/smart-status` says "SMART support: Unavailable" or all disks fall to the schema-drift path.**
DSM ships smartmontools 6.5 and identifies SATA disks via `--scan` as SCSI, which doesn't return SMART attributes. Set `smartctl_device_type: ata` (or `sat` on newer drives) in `context/nas-profile.md` under `## Hardware`. The plugin uses this hint via `smartctl -d <type>` for every disk read.

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

## Roadmap

### Phase 3 — Docker & Operations

- Docker container management (list, start/stop, logs, update)
- Package management (synopkg-Wrapper)

### Phase 4 — Backup & Snapshots

- BTRFS snapshot management (list, create, restore)
- Hyper Backup integration (Phase 6 — requires DSM Web API)

### Phase 5 — Security & Audit

- WireGuard / VPN status
- User and permissions management
- Failed-login audit, active sessions, security scan

### Phase 6+ — DSM Web API Layer

- SID-based auth + 2FA awareness
- Hyper Backup status/trigger, snapshot replication, app permissions

Each phase lands as its own spec under `docs/superpowers/specs/`.

## License

MIT — see [LICENSE](LICENSE). Original work copyright © 2026 Daniel Rosehill. Modifications and fork copyright © 2026 Marc Backes.
