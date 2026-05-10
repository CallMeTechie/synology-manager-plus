# synology-manager-plus v0.2.0 — Phase 1 Design

**Status:** Draft
**Author:** Marc Backes (CallMeTechie)
**Date:** 2026-05-10
**Fork of:** [danielrosehill/synology-manager-plugin](https://github.com/danielrosehill/synology-manager-plugin) v0.1.0

---

## 1. Motivation

Das Original-Plugin v0.1.0 hat drei zentrale Probleme:

1. **Installation ist gebrochen.** Das Repo enthält kein `marketplace.json`, deshalb funktioniert weder `claude plugin install danielrosehill/synology-manager-plugin` noch `claude plugin marketplace add …` direkt. Anwender müssen die Marketplace-Struktur lokal nachbauen.
2. **`/first-run` ist konzeptionell defekt.** Der Command delegiert an einen Sub-Agenten (`synology-intake`), der über mehrere Turns interaktiv mit dem Nutzer reden soll. Sub-Agenten haben aber kein `SendMessage`-Tool und können nicht über Turns hinweg kommunizieren — der interaktive Wizard funktioniert in der Praxis nicht.
3. **SSH-Key-Setup ist manuell.** Anwender müssen Keys generieren, deployen und Connectivity testen, bevor irgendein Plugin-Command nutzbar ist. Es gibt keine Automatisierungshilfe.

Phase 1 dieses Forks behebt genau diese drei Probleme. Funktionale Erweiterungen (Docker, Hyper Backup, BTRFS, etc.) bleiben Phase 2+.

## 2. Ziele und Nicht-Ziele

### Ziele (Phase 1)

- `claude plugin marketplace add CallMeTechie/synology-manager-plus` funktioniert ohne lokale Workarounds.
- `/first-run` läuft als interaktiver Slash-Command im Main-Context und nutzt `AskUserQuestion`.
- Ein neuer `/setup-ssh` automatisiert Key-Generierung und führt durch das Deployment.
- Ein neuer `/diag` liefert einen schnellen Health-Check über alle Voraussetzungen.
- Bestehende Commands (`/nas-status`, `/list-shares`, `/manage-mounts`) bleiben funktional kompatibel, werden aber an die neue Struktur angepasst.
- GitHub Actions führen bei jedem Push/PR Validierung aus (statisch und dynamisch gegen einen Mock-NAS).

### Nicht-Ziele (Phase 1)

- Keine neuen Funktionsdomänen (Docker, Backups, Snapshots, SMART, VPN, Pakete, Logs, User/Permissions).
- Kein Wechsel weg von SSH (z. B. zu DSM-API). Bleibt SSH-basiert.
- Keine Migration des Original-`agents/synology-intake.md` — der Sub-Agent wird ersatzlos gestrichen.
- Kein automatisches `mount` an Systemstart (fstab-Manipulation bleibt bewusst manuell).

## 3. Architektur-Übersicht

### 3.1 Repo-Layout

```
synology-manager-plus/                      # GitHub-Repo (CallMeTechie)
├── .claude-plugin/
│   └── marketplace.json                    # Marketplace-Manifest (NEU)
├── plugin/
│   ├── .claude-plugin/
│   │   └── plugin.json                     # Plugin-Manifest, version 0.2.0
│   ├── CLAUDE.md                           # Workspace-Kontext
│   ├── commands/
│   │   ├── first-run.md                    # REWRITE
│   │   ├── setup-ssh.md                    # NEU
│   │   ├── diag.md                         # NEU
│   │   ├── nas-status.md                   # bleibt
│   │   ├── list-shares.md                  # bleibt
│   │   └── manage-mounts.md                # bleibt
│   └── context/
│       ├── nas-profile.md                  # auto-populated
│       ├── storage-report.md               # auto-updated
│       ├── volumes/                        # snapshots
│       └── mounts/                         # mount-state
├── tests/
│   ├── fixtures/
│   │   ├── mock-nas/                       # Dockerfile + sshd-config
│   │   └── expected-outputs/               # erwartete Command-Outputs
│   ├── static/
│   │   ├── validate-manifests.sh
│   │   ├── shellcheck-commands.sh
│   │   ├── markdown-lint.sh
│   │   └── frontmatter-check.sh
│   └── integration/
│       ├── run-all.sh
│       ├── test-setup-ssh.sh
│       ├── test-first-run.sh
│       ├── test-diag.sh
│       ├── test-nas-status.sh
│       ├── test-list-shares.sh
│       └── test-manage-mounts.sh
├── .github/
│   └── workflows/
│       ├── validate.yml                    # statische Checks
│       └── integration.yml                 # Mock-NAS Tests
├── README.md                               # neu, mit Migration vom Original
├── CHANGELOG.md                            # neu
├── LICENSE                                 # MIT (Daniel Rosehill + Marc Backes)
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-05-10-synology-manager-plus-design.md
```

Der `agents/`-Ordner aus v0.1.0 entfällt komplett. `synology-intake.md` wird gelöscht.

### 3.2 Manifest-Dateien

**`.claude-plugin/marketplace.json`:**

```json
{
  "name": "synology-manager-plus",
  "owner": { "name": "CallMeTechie" },
  "plugins": [
    {
      "name": "synology-manager-plus",
      "source": "./plugin",
      "description": "Enhanced Synology NAS plugin — fork of danielrosehill/synology-manager-plugin with working installation, automated SSH setup, and health diagnostics."
    }
  ]
}
```

**`plugin/.claude-plugin/plugin.json`:**

```json
{
  "name": "synology-manager-plus",
  "version": "0.2.0",
  "description": "Workspace plugin for Synology NAS management. Fork of synology-manager with fixed installation, automated SSH setup, and /diag health-check.",
  "author": { "name": "Marc Backes", "url": "https://github.com/CallMeTechie" },
  "license": "MIT",
  "keywords": ["synology", "nas", "sysadmin", "storage", "ssh"]
}
```

### 3.3 Datenfluss

```
User-Interaktion
    │
    ▼
┌─────────────────────┐    AskUserQuestion (mehrere Turns)
│ /first-run          ├────────────────────────────────────┐
└──────────┬──────────┘                                    │
           │                                               ▼
           ▼                                       ┌──────────────┐
   ┌────────────────┐    Bash(ssh, ssh-keygen)     │ User typing  │
   │ /setup-ssh     ├──────────────┐               │ in Claude    │
   └────────────────┘              │               └──────────────┘
                                   ▼
                          ┌────────────────┐
                          │ Synology NAS   │
                          │ (via SSH)      │
                          └────────┬───────┘
                                   │
                                   ▼
                          ┌────────────────────────┐
                          │ context/nas-profile.md │
                          │ context/volumes/*      │
                          │ context/mounts/*       │
                          │ context/storage-       │
                          │   report.md            │
                          │ CLAUDE.md (Quick-Ref)  │
                          └────────────────────────┘
```

Keine externen MCP-Server, kein State außer den Dateien im `context/`-Verzeichnis und der Quick-Reference-Tabelle in `CLAUDE.md`.

## 4. Command-Spezifikationen

### 4.1 `/setup-ssh` (NEU)

**Zweck:** SSH-Keypair sicherstellen und Key-Auth zum NAS herstellen — idempotent.

**Frontmatter:**

```yaml
---
description: Generate an SSH keypair if missing and walk through deploying the public key to the NAS for passwordless authentication.
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---
```

**Ablauf:**

1. **Verbindungsdetails ermitteln:**
   - Wenn `context/nas-profile.md` existiert und Host/Port/User enthält → diese Werte verwenden.
   - Sonst via `AskUserQuestion` nacheinander abfragen: Host (LAN-IP oder Domain), Port (Default 22), Username.

2. **Keypair sicherstellen:**
   - Prüfen ob `~/.ssh/id_ed25519` existiert.
   - Falls nicht: `ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -C "claude-code@$(hostname)"`.
   - Existierende Keys werden niemals überschrieben.

3. **Key-Auth testen:**
   - `ssh -o BatchMode=yes -o ConnectTimeout=5 -p <port> <user>@<host> "echo OK"`.
   - Bei Erfolg → Schritt 5.
   - Bei Fehlschlag → Schritt 4.

4. **Deployment-Anleitung anzeigen:**
   - Dem Anwender den exakten Befehl präsentieren:
     ```
     ! ssh-copy-id -p <port> -i ~/.ssh/id_ed25519.pub <user>@<host>
     ```
   - Erklären, dass der `!`-Prefix den Befehl im Claude-Code-Prompt ausführt und das NAS-Passwort interaktiv abgefragt wird.
   - Warten, bis der Anwender bestätigt, dass `ssh-copy-id` durchgelaufen ist (per `AskUserQuestion`).

5. **Re-Verifikation:**
   - Erneuter `BatchMode=yes`-Test.
   - Bei Erfolg: `nas-profile.md` mit Host/Port/User updaten und Key-Pfad eintragen.
   - Bei Fehlschlag: klare Fehlermeldung mit den drei häufigsten Ursachen (SSH nicht enabled in DSM, falscher Port, User existiert nicht) und Aufforderung, `/setup-ssh` erneut zu starten.

**Nichts wird zerstörerisch verändert:** vorhandene Keys bleiben unangetastet, `~/.ssh/authorized_keys` auf dem NAS wird nur per `ssh-copy-id` ergänzt (das ist non-destructive by default).

### 4.2 `/first-run` (REWRITE)

**Zweck:** Erstmaliges Setup — interaktiv, ohne Sub-Agent.

**Frontmatter:**

```yaml
---
description: First-time setup wizard. Gathers NAS details interactively, ensures SSH key auth, discovers hardware, and populates all context files.
allowed-tools: Bash, Read, Write, Edit, AskUserQuestion
---
```

**Ablauf (alles im Main-Context, kein Sub-Agent):**

1. **Begrüßung** und kurze Erklärung des Setup-Prozesses.
2. **Connection-Details abfragen** via `AskUserQuestion` (eine Frage pro Schritt):
   - LAN-Hostname/IP
   - WAN-Hostname (optional, leer = überspringen)
   - SSH-Port (Default 22)
   - SSH-Username
3. **SSH-Key-Auth herstellen** durch interne Wiederverwendung der `/setup-ssh`-Logik (gleiche Bash-Befehle, kein rekursiver Slash-Call).
4. **NAS-Discovery** via SSH (alle Befehle parallel wo möglich):
   - `cat /etc/VERSION` → DSM-Version
   - `cat /proc/sys/kernel/hostname` → Hostname
   - `uname -m && cat /proc/cpuinfo | grep -m1 "model name"` → Architektur/CPU
   - `df -h` → Storage
   - `cat /proc/mdstat` → RAID
   - `ls /volume1/` → Top-Level-Shares
   - `which docker && docker --version` → Docker-Präsenz (für Phase 2 vorbereiten)
   - `sudo -n true 2>/dev/null && echo yes || echo no` → Sudo-Status
5. **Scoped Operations auswählen** via `AskUserQuestion` mit `multiSelect: true`:
   - Volume management
   - Mount configuration
   - File operations
   - Permission management
   - System monitoring
   - Backup operations
6. **Context-Dateien schreiben:**
   - `CLAUDE.md` Quick-Reference-Tabelle befüllen (LAN, WAN, Modell, DSM-Version, Storage, SSH-User/Port, Sudo-Status).
   - `CLAUDE.md` Scoped-Operations-Checkliste mit `[x]`/`[ ]` markieren.
   - `context/nas-profile.md` mit allen gesammelten Details neu schreiben.
   - `context/volumes/volume1-snapshot.txt` mit Timestamp.
   - `context/mounts/current.txt` mit aktuellem `mount`-Output (gefiltert auf Host).
7. **Abschluss-Summary** mit Empfehlung, als Nächstes `/diag` zu laufen.

**Idempotenz:** Bei Re-Run prüft `/first-run` zuerst, ob `nas-profile.md` schon befüllt ist. Falls ja, fragt es per `AskUserQuestion`: "Profile existiert. Überschreiben mit frischer Discovery, oder abbrechen?" Bei Bestätigung wird `nas-profile.md` und die `CLAUDE.md`-Quick-Reference komplett neu geschrieben (saubere Daten). `volumes/` und `mounts/` werden nie gelöscht, nur ergänzt — die History bleibt.

### 4.3 `/diag` (NEU)

**Zweck:** Schneller Health-Check ohne State-Änderung.

**Frontmatter:**

```yaml
---
description: Run a quick health check across SSH connectivity, key auth, profile completeness, sudo availability, and mount sanity. Read-only.
allowed-tools: Bash, Read
---
```

**Checks (jeder einzeln, jeder mit klarer Pass/Fail-Ausgabe):**

| # | Check | Methode | Hinweis bei Fail |
|---|-------|---------|------------------|
| 1 | `nas-profile.md` existiert | `[ -f context/nas-profile.md ]` | "Lauf zuerst `/first-run`" |
| 2 | Profile enthält Host/Port/User | grep auf Profile | "Profile unvollständig — `/first-run` neu" |
| 3 | SSH erreichbar | `nc -z -w3 <host> <port>` | "Host/Port prüfen, NAS evtl. aus" |
| 4 | Key-Auth funktioniert | `ssh -o BatchMode=yes -o ConnectTimeout=5 ... "echo ok"` | "Lauf `/setup-ssh`" |
| 5 | Sudo verfügbar (best-effort) | `ssh ... "sudo -n true 2>/dev/null"` | Info: "kein passwortloses Sudo — manche Ops erfordern manuelle Eingabe" |
| 6 | `df -h` funktioniert | über SSH | "SSH ok, aber NAS antwortet komisch" |
| 7 | Lokale Mounts gesund | `mount \| grep <host>` und für jeden Mount `stat` | "Mount $X tot — `umount` und neu mounten" |

**Output-Format:**

```
Synology NAS Health Check
─────────────────────────
✓ Profile present
✓ Profile complete (host: nas3.local, port: 2022, user: ma.backes)
✓ SSH reachable
✓ Key authentication works
✓ Sudo available (passwordless)
✓ Disk usage query OK
⚠ Mount /mnt/nas-media is stale (run: sudo umount /mnt/nas-media)

6/7 checks passed, 1 warning.
```

Exit nach Output. Kein Schreiben in Context-Dateien.

### 4.4 Bestehende Commands — Anpassungen

**`/nas-status`, `/list-shares`, `/manage-mounts`:**

- Logik bleibt identisch zu v0.1.0.
- Header in jedem Command bekommt einen Pre-Check: "Wenn `nas-profile.md` fehlt, starte mit `/first-run`."
- SSH-Aufrufe bekommen einheitlich `-o ConnectTimeout=5` (Original hatte das inkonsistent).
- Alle SSH-Aufrufe respektieren den konfigurierten Port aus `nas-profile.md` (Original ging implizit von Port 22 aus — bricht bei nicht-Standard-Port wie 2022).

## 5. README, CHANGELOG, Migration

### 5.1 README

Sektionen:

1. **Was ist das** — Fork von synology-manager mit Fix-Liste.
2. **Was ist anders zum Original** — explizite Tabelle: gefixte Installation, /first-run rewrite, /setup-ssh, /diag.
3. **Installation** — exakte Befehle:
   ```
   claude plugin marketplace add CallMeTechie/synology-manager-plus
   claude plugin install synology-manager-plus@synology-manager-plus
   ```
4. **Erste Schritte** — `/first-run` aufrufen, Wizard durchklicken, dann `/diag`.
5. **Commands-Tabelle** — alle 6 Commands.
6. **Migration vom Original** — wer das danielrosehill-Plugin schon installiert hat:
   ```
   claude plugin uninstall synology-manager
   claude plugin marketplace add CallMeTechie/synology-manager-plus
   claude plugin install synology-manager-plus@synology-manager-plus
   ```
   Hinweis dass `context/`-Daten ggf. manuell kopiert werden müssen.
7. **Troubleshooting** — die drei häufigsten Setup-Fehler und Lösungen.
8. **Roadmap** — Phase 2+ als Bullet-Liste (Docker, Hyper Backup, BTRFS, SMART, VPN).
9. **License & Credits** — MIT, Original-Credit an Daniel Rosehill.

### 5.2 CHANGELOG.md

Format Keep-a-Changelog. v0.2.0 als erster Eintrag mit allen Änderungen vs. v0.1.0.

### 5.3 LICENSE

MIT-Standard. Copyright zwei Zeilen:

```
Copyright (c) 2026 Daniel Rosehill (original work)
Copyright (c) 2026 Marc Backes (modifications and fork)
```

## 6. Tests

### 6.1 Statische Checks (`tests/static/`)

Alle laufen bei jedem Push/PR über `.github/workflows/validate.yml`.

**`validate-manifests.sh`:**
- `jq empty .claude-plugin/marketplace.json` → JSON valide.
- `jq empty plugin/.claude-plugin/plugin.json` → JSON valide.
- Pflichtfelder vorhanden (`name`, `version`, `description`, `plugins[]`).
- `plugins[].source` zeigt auf existierendes Verzeichnis.
- Versionen in `plugin.json` und `marketplace.json` und `CHANGELOG.md` konsistent (gleiche Version-Nummer).

**`shellcheck-commands.sh`:**
- Extrahiert alle Bash-Snippets (` ```bash `-Blöcke) aus jedem `commands/*.md`.
- Läuft `shellcheck --severity=warning` darauf.
- Fail bei Errors oder Warnings.

**`markdown-lint.sh`:**
- `markdownlint-cli2` mit projekt-eigener `.markdownlint.json` (locker, aber Konsistenz-Regeln aktiv).
- Prüft README, CHANGELOG, alle Command-Markdowns, das Spec-Dokument.

**`frontmatter-check.sh`:**
- Jeder `commands/*.md` muss `description` und `allowed-tools` haben.
- `allowed-tools` darf nur dokumentierte Tools enthalten (`Bash, Read, Write, Edit, AskUserQuestion, Task`).
- `description` muss zwischen 20 und 200 Zeichen lang sein.

### 6.2 Integration-Tests (`tests/integration/`) gegen Mock-NAS

Laufen über `.github/workflows/integration.yml` in einem Job, der einen Mock-NAS-Container startet.

**Mock-NAS (`tests/fixtures/mock-nas/`):**

Ein minimaler Docker-Container basierend auf Alpine + OpenSSH:

- `Dockerfile`:
  - Alpine-Base + `openssh-server`, `bash`, `coreutils`.
  - User `nas-test` mit Passwort `test123` (klar dokumentiert als Test-Fixture).
  - SSH auf Port 2222.
  - Synology-spezifische Stub-Dateien gemockt:
    - `/etc/VERSION` mit fake DSM-7-Inhalt.
    - `/etc/synoinfo.conf` mit Stub-Modell-Eintrag (`upnpmodelname="DS218+ (mock)"`).
    - `/proc/mdstat` ist nicht mockbar in einem Container — Tests prüfen hier nur Exit-Code, nicht Inhalt.
  - `/volume1/` mit drei Test-Shares: `documents`, `media`, `backups`.
  - `df -h` und `mount` funktionieren nativ.
  - Stub-Skripte für `synoservice` (gibt eine Liste hardcodierter Services aus).

**Test-Skripte:**

Jedes Skript folgt dem Muster:
1. Mock-NAS-Container starten (`docker run -d --rm -p 12222:2222 mock-nas`).
2. Initial-SSH-Key generieren in temp-Dir (`HOME` für den Test-Lauf temporär umsetzen).
3. Key per `sshpass + ssh-copy-id` deployen (im CI-Container ist sshpass ok, weil die Credentials als Test-Fixture dokumentiert sind).
4. Einen leeren `nas-profile.md`-Stub bauen mit Host=`localhost`, Port=`12222`, User=`nas-test`.
5. Den jeweiligen Command-Markdown so verarbeiten, dass die Bash-Befehle ausgeführt werden (Extraktion + Eval — gleiche Logik wie `shellcheck-commands.sh`).
6. Erwarteten Output gegen `tests/fixtures/expected-outputs/<test>.txt` diffen (mit Toleranz für Datums-/Hostname-Strings via `sed`).
7. Container stoppen, temp-Dir aufräumen.

Ein zentraler `tests/integration/run-all.sh` startet den Container einmal, lässt alle Test-Skripte gegen denselben Container laufen (zwischen den Tests wird der State auf dem Mock-NAS zurückgesetzt) und stoppt am Ende.

**Konkrete Tests:**

- `test-setup-ssh.sh`:
  1. Frischer temp-Home ohne Keys.
  2. `/setup-ssh`-Logik läuft (mit gestubbter `AskUserQuestion`-Antwort: "ja, ssh-copy-id ist durch").
  3. Erwartet: Key generiert, Auth nach `ssh-copy-id` funktioniert, `nas-profile.md` populiert.
  4. Re-Run: kein neuer Key, Auth bleibt, idempotent.

- `test-first-run.sh`:
  1. Stub-Antworten für `AskUserQuestion` in einer Fixture-Datei (CI simuliert User-Input zeilenweise).
  2. `/first-run`-Logik läuft.
  3. Erwartet: `CLAUDE.md` Quick-Reference vollständig (`upnpmodelname` korrekt extrahiert), `nas-profile.md` populiert, `volumes/volume1-snapshot.txt` enthält die drei Test-Shares.

- `test-diag.sh`:
  1. Drei Szenarien:
     - Alles ok → 7/7 grün.
     - Mock-NAS gestoppt → SSH-Fehler korrekt erkannt, Output zeigt Schritt-3-Fehlermeldung.
     - `nas-profile.md` fehlt → Hinweis auf `/first-run`.

- `test-nas-status.sh`:
  1. Läuft `/nas-status` gegen Mock.
  2. Erwartet: `storage-report.md` aktualisiert mit Mock-`df`-Werten, Timestamp im Header.

- `test-list-shares.sh`:
  1. Läuft `/list-shares` gegen Mock.
  2. Erwartet: `volumes/volume1-snapshot.txt` enthält die drei Mock-Shares (`documents`, `media`, `backups`).

- `test-manage-mounts.sh`:
  1. Nur `list`-Subcommand testbar im CI (echtes mount im Container ist fragil und bräuchte privileged).
  2. Erwartet: Output ist leer (keine NAS-Mounts auf dem Runner), Exit-Code 0, kein Fehler.

### 6.3 GitHub Actions Workflows

**`.github/workflows/validate.yml`:**

```yaml
name: Validate
on:
  push:
    branches: [main]
  pull_request:
jobs:
  static:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install tools
        run: |
          sudo apt-get update
          sudo apt-get install -y jq shellcheck
          npm install -g markdownlint-cli2
      - name: Validate manifests
        run: bash tests/static/validate-manifests.sh
      - name: Shellcheck commands
        run: bash tests/static/shellcheck-commands.sh
      - name: Markdown lint
        run: bash tests/static/markdown-lint.sh
      - name: Frontmatter check
        run: bash tests/static/frontmatter-check.sh
```

**`.github/workflows/integration.yml`:**

```yaml
name: Integration
on:
  push:
    branches: [main]
  pull_request:
jobs:
  mock-nas:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build mock NAS image
        run: docker build -t mock-nas tests/fixtures/mock-nas/
      - name: Install test deps
        run: sudo apt-get install -y sshpass
      - name: Run integration tests
        run: bash tests/integration/run-all.sh
      - name: Upload logs on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: integration-logs
          path: tests/integration/logs/
```

### 6.4 Akzeptanzkriterien

Phase 1 gilt als abgeschlossen, wenn:

- `validate.yml` ist grün auf main.
- `integration.yml` ist grün auf main.
- Manueller End-to-End-Test gegen die echte DS218+ läuft `/first-run` durch und `/diag` ist 7/7 grün.

## 7. Sicherheits-Überlegungen

- **Keine Geheimnisse im Repo.** Mock-NAS-Credentials sind Test-only und im `Dockerfile` und `tests/README.md` klar als Fixture markiert.
- **`ssh-copy-id` statt sshpass-Hack** im Plugin selbst — Passwort wird interaktiv vom User getippt, nie im Speicher gehalten.
- **Keine Custom-Crypto** — wir nutzen ausschließlich OpenSSH-Standardwerkzeuge.
- **`BatchMode=yes` und `ConnectTimeout`** verhindern hängende Prompts in nicht-interaktiven Pfaden.
- **`StrictHostKeyChecking=accept-new`** wird explizit *nicht* gesetzt — der erste Connect zeigt den Host-Key-Prompt, der User akzeptiert ihn manuell. Defense in depth gegen MITM beim Erst-Setup.
- **Plugin schreibt nicht in `~/.ssh/known_hosts` oder `~/.ssh/config`** automatisch — das bleibt User-Verantwortung.
- **Eingaben werden vor dem Forwarding an Bash validiert.** Host/Port/User aus `AskUserQuestion` werden via Bash-Variablen-Quoting (`"$host"`) eingesetzt; ein Validierungs-Schritt prüft Host gegen `^[a-zA-Z0-9.-]+$` und Port gegen `^[0-9]{1,5}$` vor jedem SSH-Aufruf. Wer hier Sonderzeichen einträgt, bekommt einen klaren Fehler statt einer Shell-Injection-Lücke.

## 8. Out-of-Scope für Phase 1 (für spätere Specs)

- Docker-Container-Verwaltung (Liste, Start/Stop, Logs).
- Hyper Backup Job-Status und Trigger.
- BTRFS-Snapshot-Verwaltung.
- SMART-Disk-Health (`smartctl`).
- WireGuard/OpenVPN-Status.
- DSM-Update-Check.
- User- und Permissions-Verwaltung.
- Synology-Pakete (`synopkg`).
- Logs-Viewer.
- Power-Management (Wake-on-LAN, Schedule).
- Surveillance Station, Photos, Drive — alles Synology-App-spezifisch.

Jeder dieser Punkte bekommt einen eigenen Spec-Eintrag in `docs/superpowers/specs/`, sobald wir an Phase 2 gehen.

## 9. Offene Fragen

Keine blocking — alle Major-Entscheidungen wurden in der Brainstorming-Session getroffen:

- Repo-Name: `synology-manager-plus` ✓
- SSH-Deploy-Methode: `ssh-copy-id` interaktiv ✓
- Sub-Agent: ersatzlos gestrichen ✓
- Marketplace: kombiniertes Repo-Layout mit `plugin/`-Subdir ✓

Falls während der Implementation Detail-Fragen auftreten, werden sie im Implementation-Plan geklärt, nicht hier zurückprojiziert.
