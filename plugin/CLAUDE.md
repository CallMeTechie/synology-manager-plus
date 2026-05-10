# Claude Synology Manager Plus

This repository is your workspace for managing a Synology NAS via Claude Code. It provides persistent context and memory for NAS administration tasks across sessions.

<!-- synology-manager-plus:managed-start -->

## Quick Reference

| Field | Value |
| - | - |
| NAS Host (LAN/WAN) | _not configured_ |
| SSH Port | _not configured_ |
| SSH User | _not configured_ |
| SSH Key | `~/.ssh/synology-manager-plus_ed25519` |
| Connect Timeout | 10s (default) |
| Model | _not configured_ |
| DSM Version | _not configured_ |
| Total / Available Storage | _not configured_ |
| Sudo (passwordless) | _not configured_ |
| Docker Available | _not configured_ |

## Scoped Operations

Authorized categories (set during `/first-run`):

- [ ] Volume management (create/delete shared folders)
- [ ] Mount configuration (NFS/SAMBA)
- [ ] File operations (copy, move, delete)
- [ ] Permission management
- [ ] System monitoring
- [ ] Backup operations

<!-- synology-manager-plus:managed-end -->

## First Run

If the Quick Reference above shows `_not configured_`, run `/first-run` to populate NAS details interactively.

## Available Commands

| Command | Description |
| - | - |
| `/first-run` | Interactive setup wizard |
| `/setup-ssh` | Generate keypair and walk through key deployment |
| `/diag` | Health check (7 points) |
| `/nas-status` | Disk usage, RAID, services |
| `/list-shares` | List shared folders |
| `/manage-mounts` | View/add/remove NFS/SAMBA mounts |

## Operational Guidelines

### Before Operations

1. Check `context/nas-profile.md` for connection details.
2. If unsure, run `/diag` first.
3. Review relevant cached state in `context/`.

### During Operations

1. Use SSH for direct file/system operations (always with `-i ~/.ssh/synology-manager-plus_ed25519`).
2. Prefer non-destructive operations (list before delete, backup before modify).

### After Operations

1. Update relevant context files when state changes.
2. If storage changed significantly, refresh `context/storage-report.md`.

## Notes

_Space for session notes and observations — anything below this line is preserved across `/first-run` re-runs:_

---
