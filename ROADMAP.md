# Roadmap — synology-manager-plus

This roadmap tracks the features still ahead. It grows out of the same brainstorming
that produced multi-NAS management; the three big items below are the original ideas
that were deferred, plus the smaller follow-ups that surfaced while building multi-NAS.

## Shipped

- **Multi-NAS management** (v0.7.0) — per-NAS profile layout under `context/nas/<slug>/`,
  one-line active-NAS pointer, lossless `/first-run` migration, the `/nas-list`,
  `/nas-use`, `/nas-add`, `/nas-remove` command family, and `--all` fleet fan-out on
  `/health-summary`, `/smart-status`, and `/nas-status`. The per-NAS layout is the data
  foundation the items below build on.
- **Passwordless docker-sudo setup** (v0.8.0) — `/setup-docker-sudo` plus the canonical
  `_sudo-lib.sh`. Generates a `visudo`-validated, busybox-safe root script that the user runs
  once via the DSM Task Scheduler to install `NOPASSWD: /usr/local/bin/docker`, with a
  result-marker for diagnosable verification. `/first-run` runs it after the atomic profile
  write (resumable); the old `sudo -n true` probe was fixed to be docker-specific.

## Guiding principles

- **Read-only by default.** Mutation is the exception — it must be explicit, confirmed,
  scoped, and reversible.
- **Commands are self-contained.** Each command inlines its logic; tricky/shared logic is
  mirrored in a unit-tested `_*.sh` (Claude Code commands cannot source bundled libs at
  runtime). See `_profile-lib.sh` / `_compose-lib.sh`.
- **Per-NAS aware.** Anything that stores state lives under `context/nas/<slug>/`.
- **Process.** Each feature: spec (`docs/superpowers/specs/`) → plan
  (`docs/superpowers/plans/`) → multi-round review → subagent-driven implementation → CI green.

## 1. Synology-AI-Ops — recommended next

**What:** A read-only analysis command that ingests data the plugin already collects —
system/ssh/package/docker logs, SMART attributes, RAID state, load/CPU, DSM update status —
and produces a structured root-cause analysis: what is wrong, the most likely cause, a
suggested (not executed) remediation, and a severity.

**Value:** Highest immediate payoff. Works on a single NAS today and turns the raw data the
plugin already gathers into actionable insight.

**Risk:** 🟢 Low — read-only, no mutation. The analysis is structured synthesis over existing
command outputs, deterministic-rules-first with an LLM narrative on top.

**Dependencies:** None. Becomes the *detection* layer that Auto-Repair later consumes.

**Per-NAS:** runs against the active NAS; a `--all` fleet analysis is a natural extension.

**Rough deliverables:**

- `/ai-ops` (analysis) command: gather inputs (reuse the existing health-summary /
  smart-status / logs queries), present a structured report.
- A symptom → likely-cause → suggested-fix mapping grounded in the *actual* data (no
  hallucinated specifics).
- Optional: persist each analysis under `context/nas/<slug>/` for trend reference.

**Open questions:** which inputs in v1 (start with SMART + RAID + storage + critical logs?);
how much deterministic rule vs LLM synthesis (lean deterministic-first).

## 2. DSM-Config-Diff

**What:** Snapshot a defined set of DSM configuration (shared folders, mounts, scheduled
tasks, package list, selected `/etc` files, network/firewall where readable) into
`context/nas/<slug>/`, then a diff command that answers "what changed since `<snapshot>`?".

**Value:** Catch configuration drift, audit changes, and provide the "before" state that a
future Auto-Repair needs in order to roll back.

**Risk:** 🟢 Low — read-only snapshot + local diff.

**Dependencies:** None. Pairs naturally with AI-Ops (a config change is often the root cause
AI-Ops is looking for).

**Per-NAS:** snapshots live under `context/nas/<slug>/snapshots/<timestamp>/`.

**Rough deliverables:**

- `/config-snapshot`: capture the defined config sources to a timestamped directory.
- `/config-diff [<from> [<to>]]`: structured diff with a human summary (added / removed / changed).
- A documented, **security-reviewed allow-list** of what is snapshotted (must avoid secrets).

**Open questions:** exactly which config sources (security review required to avoid capturing
credentials); snapshot retention/rotation.

## 3. Auto-Repair-Agent — build last

**What:** Detect a problem (e.g. a volume warning, a stale mount, a stopped critical
container), propose a fix, and — only on explicit confirmation — execute it, with a rollback
path.

**Value:** The headline "self-healing" capability — but only safe once detection and rollback
exist.

**Risk:** 🔴 High — mutating, runs against the user's NAS, and cuts against the project's
read-only-by-default philosophy. Needs the most careful safety design: dry-run preview,
approval gates, scoping, rollback, and an audit trail.

**Dependencies:** **Synology-AI-Ops** (detection) **and DSM-Config-Diff** (before/after +
rollback baseline). Build those first.

**Per-NAS:** acts only on the active NAS; a mutation is **never** fanned out across NAS.

**Rough deliverables (likely split across sub-specs):**

- A constrained, vetted repair catalogue. Each repair has: detection, dry-run preview,
  confirmation, execution, verification, and rollback.
- Hard safety boundaries: scoped-operations authorization, critical-resource whitelists
  (reuse the `critical_compose_projects` pattern), no destructive default.

**Open questions:** which repairs are in scope for v1 (start with the safest, most common,
fully-reversible ones); the authorization model (likely ties into per-NAS scoped-operations,
below).

## Foundation follow-ups

Smaller items surfaced while building multi-NAS:

- **Real-hardware acceptance** — multi-NAS against two or more live NAS (switching, fan-out,
  remove), and the `/setup-docker-sudo` end-to-end flow (the real DSM Task Scheduler run) —
  only runnable by the maintainer against physical hardware.
- **Per-NAS scoped-operations.** The "Scoped Operations" authorizations are currently a single
  global policy. Revisit before managing NAS of different trust levels (prod vs test) — a global
  "file operations allowed" can't express "allow on test, never on prod". Relevant to
  Auto-Repair's authorization model.
- **`--all` fan-out for `/logs` and `/dsm-update-check`** — deferred; a nice-to-have once the
  fan-out pattern is proven.
- **Fleet top-table output.** The `--all` summary is currently a streamed `Fleet summary:`
  footer; optionally add a columnar top table (per-NAS storage/raid/disks/load/verdict).
- **Ship `plugin/CLAUDE.md`?** It is currently git-excluded (`**/CLAUDE.md`), so its
  command-table updates are not tracked. Decide whether the workspace template should ship.
- **Test hygiene.** `test-fanout.sh` appends the mock host key to the user's `known_hosts`
  without cleanup (minor).

## Suggested order

1. **Synology-AI-Ops** — fast win, read-only, and the detection layer for Auto-Repair.
2. **DSM-Config-Diff** — read-only building block and rollback baseline.
3. **Auto-Repair-Agent** — last, on top of (1) + (2), with a dedicated safety-design pass.

Each item is independent enough to ship on its own; (3) should not start until (1) and (2)
exist.
