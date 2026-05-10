# synology-manager-plus

A Claude Code plugin for managing a Synology NAS via SSH.

**This is a fork** of [`danielrosehill/synology-manager-plugin`](https://github.com/danielrosehill/synology-manager-plugin). The fork addresses three blockers in the upstream v0.1.0 and adds a guided diagnostic command. Original credit to Daniel Rosehill.

## What's different from the original

| Area | Original v0.1.0 | This fork v0.2.0 |
|------|-----------------|------------------|
| Installation | `claude plugin install danielrosehill/...` did not work — no marketplace manifest in repo | Marketplace manifest included; `claude plugin marketplace add` works directly |
| `/first-run` | Sub-agent that could not maintain a multi-turn dialog | Slash command in main context using `AskUserQuestion` |
| SSH setup | Manual: keygen, copy-id, profile editing | Guided `/setup-ssh` with copy-paste `!`-prefix flow |
| Health check | Absent | `/diag` 7-point health check |
| SSH key | Used `~/.ssh/id_ed25519`, conflicted with user keys | Plugin-owned `~/.ssh/synology-manager-plus_ed25519` |
| Connect timeout | Hard-coded 5s, broke on WAN/VPN | Default 10s, configurable per-profile |
| User notes in CLAUDE.md | Could be overwritten by `/first-run` re-run | Protected via managed-section markers |
| Tests | None | Static checks + Mock-NAS smoke tests in CI |

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

| Command | Description |
|---------|-------------|
| `/first-run` | Interactive setup wizard (one-time, idempotent) |
| `/setup-ssh` | Standalone SSH key setup |
| `/diag` | 7-point health check (read-only) |
| `/nas-status` | Disk usage, RAID, services, load |
| `/list-shares` | List shared folders, refresh volume snapshots |
| `/manage-mounts` | View/add/remove NFS or SMB mounts |

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

## Roadmap (Phase 2+)

- Docker container management (list, start/stop, logs)
- Hyper Backup job status and trigger
- BTRFS snapshot management
- SMART disk health (`smartctl`)
- WireGuard / VPN status
- DSM update check
- User and permissions management
- Synology packages (`synopkg`)
- Logs viewer
- Power management (Wake-on-LAN, schedule)

Each will land as its own spec under `docs/superpowers/specs/`.

## License

MIT — see [LICENSE](LICENSE). Original work copyright © 2026 Daniel Rosehill. Modifications and fork copyright © 2026 Marc Backes.
