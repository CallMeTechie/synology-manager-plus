# synology-manager-plus — Multi-NAS-Management

**Date:** 2026-05-29
**Author:** Marc Backes (CallMeTechie)
**Status:** Draft (awaiting user review) — gehärtet nach Devil's-Advocate-Runde 1 + 2; Architektur auf Inline-Pattern korrigiert nach Sourcing-Verifikation
**Predecessor specs:**
- `2026-05-10-synology-manager-plus-design.md` (Setup & Diagnostics)
- `2026-05-11-synology-manager-plus-phase2-design.md` (Health & Watch)
- `2026-05-12-synology-manager-plus-phase3-design.md` (Docker & Operations)

---

## 0. Kontext & zwei harte Architektur-Fakten

**Use-Case ist validiert:** Multi-NAS ist **kein** spekulatives Feature. Der User
betreibt mehrere Synology NAS Stations, und die Zielgruppe (Homelab-Enthusiasten)
hat typischerweise mehrere. Es wird vollständig gebaut.

**Sourcing-Verifikation (entscheidend, vor der Planung geklärt):** Claude-Code-Plugin-
Commands können **keine** gebündelte Shell-Lib zur Laufzeit `source`-n.
`CLAUDE_PLUGIN_ROOT` ist nur für **Hooks** dokumentiert, nicht für Commands;
`$BASH_SOURCE`/`$0` helfen nicht (Snippets werden extrahiert/ausgeführt, CWD ist der
User-Workspace, nicht das Plugin-Verzeichnis). **Bestätigt durch den eigenen Code:**
`compose-down.md` enthält `is_critical_compose_project()` **inline**, während
`_compose-lib.sh` dieselbe Funktion nur trägt, damit der Unit-Test sie isoliert
prüfen kann — **kein Command sourcet die Lib.**

**Konsequenz für dieses Design:** Der etablierte Pattern wird übernommen —
`_profile-lib.sh` ist die **kanonische, unit-getestete Source-of-Truth**; jedes
Command bettet einen **äquivalenten Inline-Block** ein. Das eliminiert die
Duplizierung **nicht** (es standardisiert sie und macht sie multi-NAS-fähig). Der
Gewinn ist Konsistenz + Multi-NAS-Fähigkeit + Testbarkeit, **nicht** Zeilen-Ersparnis.

**Bausequenz, ein Feature:** Implementierung in zwei Phasen, ausgeliefert als ein
Feature.
- **Phase 1 — Fundament:** kanonische Lib + Unit-Tests, per-NAS-Layout, Migration
  (in `/first-run`), Retrofit der profil-lesenden Commands auf das per-NAS-Layout.
  Single-NAS-Verhalten bleibt identisch. **Eigenständig mergebar.**
- **Phase 2 — Multi-NAS-UX:** `/nas-add`, `/nas-list`, `/nas-use`, `/nas-remove`,
  `--all`-Fan-out.

Abschnitte sind mit **[P1]** / **[P2]** als Bauphase markiert. **Phase 1 bekommt
einen eigenen Implementierungsplan; Phase 2 einen zweiten** (kein Mega-Plan).

## 1. Motivation

Das Plugin verwaltet heute genau **ein** NAS. Verbindungs- und Hardware-Daten
liegen in einer einzigen Datei `context/nas-profile.md`. **14 der 16 Commands**
hardcoden den Pfad `PROFILE="context/nas-profile.md"` und extrahieren `host`,
`port`, `user` jeweils inline per `awk` (mit copy-pasteter Validierung);
`/setup-ssh` liest das Profil über eine eigene Extraktion, `/first-run` erzeugt es.

Sobald ein zweites NAS ins Spiel kommt (Haupt-NAS + Backup-NAS, oder mehrere
Standorte), bricht dieses Modell: es gibt keinen Weg, zwischen NAS umzuschalten,
keinen Flotten-Überblick, und der bestehende Profil-Code müsste in jedem Command
dupliziert verzweigt werden.

Diese Erweiterung führt **Multi-NAS-Management** ein: mehrere benannte NAS-Profile,
ein „aktives" NAS mit Umschalt-Mechanik und eine optionale Fan-out-Sicht über alle
NAS für die Read-only-Übersichten. Die heute ad-hoc verstreute Profil-Extraktion
wird auf **eine kanonische, unit-getestete Implementierung** (`_profile-lib.sh`)
standardisiert, die jedes Command inline spiegelt (etablierter `_compose-lib`-Pattern).

## 2. Goals

- **G1 [P1]:** Per-NAS-Datenmodell unter `context/nas/<slug>/`, jedes NAS mit
  eigenem Profil und eigenem SSH-Key.
- **G2 [P1]:** Kanonische, unit-getestete Profil-Resolver-Implementierung in
  `_profile-lib.sh`; jedes Command bettet einen **äquivalenten Inline-Block** ein
  (`_compose-lib`-Pattern). Standardisiert die 14 ad-hoc-Extraktionen auf eine
  getestete Form und macht sie multi-NAS-fähig. **Kein** Netto-Zeilenabbau —
  Duplizierung wird vereinheitlicht, nicht eliminiert (siehe Sec 0).
- **G3 [P1]:** **Einmalige, explizite, verlustfreie & resumable** Migration
  bestehender Single-NAS-Workspaces über `/first-run`. (Kein Auto-Migrieren am Kopf
  jedes Commands — das würde 15 Zeilen Migrationscode in 14 Commands erfordern.)
- **G4 [P1]:** Bestehendes Single-NAS-Verhalten bleibt nach Migration funktional
  identisch (das aktive NAS *ist* das einzige NAS, wenn nur eins existiert).
- **G5 [P2]:** Ein „aktives" NAS; `/nas-use <slug>` schaltet um. Verwaltung über
  `/nas-add`, `/nas-list`, `/nas-remove`.
- **G6 [P2]:** Optionaler Fan-out (`--all`) für `/health-summary`, `/smart-status`,
  `/nas-status`: alle NAS abfragen, kompakt aggregieren, Worst-of-Verdict, mit
  Reachability-Probe gegen Hänger.
- **G7:** Konsistenz mit dem bestehenden Stil: `set -euo pipefail`, strenge
  Input-Validierung, Fail-loud, read-only-Default, Tabellen + Verdict-Zeile.

## 3. Non-Goals

- **NG1:** Keine parallele/nebenläufige Abfrage mehrerer NAS. Fan-out ist
  **sequenziell** mit Pro-NAS-Reachability-Probe (Sec 4.5).
- **NG2:** Kein Fan-out für mutierende oder zielgerichtete Commands
  (`/manage-mounts`, `/compose-*`, `/list-shares`). Diese bleiben aktiv-NAS-only.
- **NG3:** Kein Fan-out für `/logs` und `/dsm-update-check` in dieser Iteration.
- **NG4:** Kein zentrales Aggregat-Config-File. Aktiv-Pointer ist eine eigene
  Ein-Zeilen-Datei, Profile bleiben pro NAS getrennt.
- **NG5:** Keine NAS-übergreifenden Operationen (z. B. „mounte Share von NAS-A auf
  NAS-B").
- **NG6:** Kein Umbenennen des bestehenden SSH-Keys während der Migration —
  `~/.ssh` wird bei der Migration nicht angefasst.
- **NG7:** Keine `/nas-list --ping`-Erreichbarkeitsprüfung. `/nas-list` liest nur
  lokale Profile, kein SSH.
- **NG8:** Per-NAS-Scoping der „Scoped Operations"-Autorisierungen ist out of scope
  — diese bleiben eine **globale** Plugin-Policy (Sec 4.7). **In Phase 2 zu
  bewerten**, sobald mehrere NAS mit unterschiedlichem Vertrauensniveau verwaltet
  werden (globale Autorisierungen können „erlaube auf test, nie auf prod" nicht
  ausdrücken).
- **NG9:** Kein Sourcing einer geteilten Lib aus Commands (Sec 0) — Inline-Pattern.

## 4. Architecture

### 4.1 Datenmodell & Verzeichnis-Layout [P1]

Aus dem flachen Single-NAS-Layout wird ein Namespace pro NAS:

```
context/
  active-nas                         # eine Zeile: Slug des aktiven NAS (Completion-Sentinel der Migration)
  nas/
    <slug>/
      profile.md                     # war: context/nas-profile.md
      storage-report.md              # war: context/storage-report.md
      volumes/<volume>-snapshot.txt  # war: context/volumes/...
      mounts/current.txt             # war: context/mounts/...
```

- **NAS-Identität = Slug.** Vom User gewählter Kurzname, gleichzeitig
  Verzeichnisname und `/nas-use <slug>`-Argument.
- **Slug-Validierung:** `^[a-z0-9][a-z0-9-]{0,31}$`. **Sicherheitskritisch**
  (Sec 9): verhindert Path-Traversal (`..`, `/`), Leerzeichen, Shell-Metazeichen,
  da der Slug in Dateipfade eingesetzt wird.
- **Aktiv-Pointer / Completion-Sentinel:** `context/active-nas` enthält genau eine
  Zeile mit dem Slug. Er ist gleichzeitig das **Abschluss-Signal der Migration**
  (Sec 4.4) — bewusst, damit Guard-Logik und Recovery konsistent sind. Der gelesene
  Wert wird **vor jeder Verwendung erneut gegen Slug-Regex und Existenz von
  `context/nas/<slug>/profile.md` validiert** (Defense in Depth).
- **SSH-Key pro NAS:** `profile.md` behält `key_path`. Default für neues NAS:
  `~/.ssh/synology-manager-plus_<slug>_ed25519`.

### 4.2 Aktiv-Pointer-Auflösung (Fallback-Logik) [P1]

Die Auflösung (kanonisch `smp_active_nas` in der Lib; in Commands inline gespiegelt)
folgt dieser Priorität:

1. **`context/active-nas` valider Slug + `context/nas/<slug>/profile.md` existiert**
   → dieser Slug.
2. **Pointer fehlt/ungültig, aber genau ein NAS** (mit profile.md) unter
   `context/nas/*/` → dieses NAS (und Pointer einmalig schreiben, self-healing).
3. **Pointer fehlt/ungültig und mehrere NAS** → **fail-loud:**
   `"No active NAS selected. Run /nas-use <slug> (see /nas-list)."` exit 1.
4. **Kein NAS, aber Legacy `context/nas-profile.md` vorhanden** → **fail-loud:**
   `"Legacy single-NAS layout detected — run /first-run to upgrade to the multi-NAS layout."` exit 1.
5. **Kein NAS und keine Altdatei** → **fail-loud:** `"No NAS configured. Run /first-run."` exit 1.

### 4.3 Kanonischer Resolver `_profile-lib.sh` (test-only) + Inline-Pattern [P1]

**Kein Command sourcet diese Lib** (Sec 0). Sie ist die **kanonische,
unit-getestete Implementierung**, Geschwister zu `_compose-lib.sh` in
`plugin/commands/`. Jedes Command bettet einen **äquivalenten Inline-Block** ein.
Die Lib + ihr Unit-Test sind die Referenz, gegen die die Inline-Blöcke per Konvention
synchron gehalten werden (exakt wie heute `is_critical_compose_project` inline in
`compose-down.md` ↔ `_compose-lib.sh`).

**Kanonische Funktionen (unit-getestet, in der Lib):**

| Funktion | Verhalten | Exit/Output |
|---|---|---|
| `smp_validate_slug <s>` | prüft `<s>` gegen `^[a-z0-9][a-z0-9-]{0,31}$`. | 0 = gültig, 1 = ungültig |
| `smp_derive_slug <hostname>` | normalisiert Hostname → Slug; gated durch `smp_validate_slug`; Fallback `main`. Nie leer (R2-1). | gültiger Slug |
| `smp_active_nas` | Auflösung nach Sec 4.2. | Slug, oder exit 1 + Meldung |
| `smp_profile_path [slug]` | Echo `context/nas/<slug>/profile.md` (Default: aktiv). | Pfad |
| `smp_load_profile [slug]` | Extrahiert + validiert `host/port/user/connect_timeout/key_path`; setzt `HOST/PORT/NAS_USER/CONNECT_TIMEOUT/KEY_PATH/SLUG`. Inkl. `_not configured_`-Check, host/port/user-Regex (bestehend) **und key_path-Validierung (Sec 4.6)**. | Vars, oder exit 1 |
| `smp_list_nas` | Slugs unter `context/nas/*/` mit `profile.md`, **alphabetisch sortiert**. | je Slug eine Zeile |
| `smp_build_ssh [slug]` | setzt `SSH=( ssh -i <key> -o ConnectTimeout=<t> -p <port> <user>@<host> )`; validierter `KEY_PATH` mit `$HOME`-Expansion, Key-Existenz geprüft. | Array, oder exit 1 |
| `smp_migrate` | einmalige, resumable Migration (Sec 4.4). | 0, oder exit 1 |

**Inline-Pattern im Command** (kein `source`; der exakte Block kommt aus dem Plan
und entspricht 1:1 der Lib-Logik):

```bash
set -euo pipefail
# --- Resolve active NAS profile (multi-NAS layout). Mirrors _profile-lib.sh. ---
# Legacy single-NAS layout? Direct user to migrate once via /first-run.
if [ -f context/nas-profile.md ] && [ ! -d context/nas ]; then
  echo "Legacy single-NAS layout detected — run /first-run to upgrade." >&2; exit 1
fi
# ... active-pointer resolution (Sec 4.2) → PROFILE + SLUG ...
# ... extract + validate host/port/user/connect_timeout/key_path (Sec 4.6) ...
# ... build SSH=( ... ) array ...
```

**Drift-Risiko:** Inline-Blöcke und Lib können auseinanderlaufen — das ist der
akzeptierte `_compose-lib`-Tradeoff, da Commands nicht sourcen können. Mitigation:
(a) der Inline-Block ist **wörtlich aus der Lib kopierbar** strukturiert; (b) der
Unit-Test prüft die Lib-Funktionen als kanonische Wahrheit; (c) der Plan liefert den
exakten Block einmal, jedes Command nutzt ihn identisch.

### 4.4 Migration bestehender Single-NAS-Workspaces — einmalig, resumable, verlustfrei [P1]

**Trigger geändert (Inline-Konsequenz):** Migration läuft **nicht** am Kopf jedes
Commands (das würde 15 Zeilen Migrationscode ×14 erfordern). Sie läuft an **einer**
Stelle: `/first-run`. Die 13 anderen profil-lesenden Commands **erkennen** das
Legacy-Layout nur und weisen den User an, `/first-run` einmal auszuführen (Sec 4.2
Regel 4, ~3 Zeilen inline). Kanonische Logik: `smp_migrate` in der Lib (unit-getestet).

> **G5-Tradeoff (bewusst):** Migration ist „einmalig explizit über /first-run"
> statt „transparent bei jedem Command". Akzeptabel, weil /first-run der
> dokumentierte (Re-)Setup-Einstieg ist und die Bestandsnutzerzahl klein ist. Die
> Detektion gibt eine klare, umsetzbare Anweisung statt eines kryptischen Fehlers.

**Invarianten:**
- **Completion-Sentinel ist `context/active-nas`** (nicht die bloße Existenz von
  `context/nas/`). Solange er fehlt, gilt die Migration als unfertig.
- **Legacy-Originale bleiben unangetastet, bis der Sentinel committed ist** — es
  wird **kopiert, nicht verschoben**; Altdateien werden erst NACH dem Sentinel entfernt.
- **Staging + atomarer Rename** statt mehrerer riskanter `mv`.

**Algorithmus (`smp_migrate`, aufgerufen von `/first-run`):**

1. Wenn `context/active-nas` existiert und gültig (Slug + Ziel-profile.md) → **no-op**.
2. Wenn `context/nas-profile.md` **nicht** existiert:
   - `context/nas/*/` enthält bereits ein NAS → no-op (frischer New-Layout-Workspace).
   - sonst → no-op (nichts zu migrieren; `/first-run` legt frisch an).
3. Sonst (Legacy-Datei vorhanden, Migration unfertig):
   1. `SLUG=$(smp_derive_slug <hostname-aus-Profil>)` — gated durch `smp_validate_slug`,
      Fallback `main`. **Garantie (R2-1): `SLUG` ist danach immer ein gültiger,
      nicht-leerer Slug**, bevor er in IRGENDEINEN Pfad (insb. `rm -rf`) eingeht.
   2. Staging aus früherem Abbruch entfernen: `rm -rf context/.nas-migrate.tmp`.
   3. Staging per **copy** befüllen: `mkdir -p context/.nas-migrate.tmp/"$SLUG"`,
      dann `cp` von `nas-profile.md` → `profile.md` sowie `storage-report.md`,
      `volumes/`, `mounts/` (falls vorhanden) ins Staging.
   4. Partielles Ziel aus früherem Abbruch entfernen:
      `rm -rf -- "context/nas/${SLUG:?slug empty}"` (der `${SLUG:?}`-Guard bricht bei
      leerer Variable ab, statt das Elternverzeichnis zu treffen; gefahrlos, da Legacy
      noch authoritativ ist). `mkdir -p context/nas`, dann **ein atomarer Rename:**
      `mv context/.nas-migrate.tmp/"$SLUG" context/nas/"$SLUG"`.
   5. **Sentinel committen:** `context/active-nas` = `"$SLUG"` (atomar via `mktemp` + `mv`).
   6. **Erst jetzt** Legacy entfernen: `rm -f context/nas-profile.md
      context/storage-report.md`, `rm -rf context/volumes context/mounts` (nur die
      alten flachen Pfade).
   7. Einzeiler: `[migration] single-NAS workspace migrated to context/nas/<slug>/`.
4. **Key bleibt unverändert** (NG6): `synology-manager-plus_ed25519` bleibt als
   `key_path` im migrierten Profil; nur neue NAS bekommen das `_<slug>_`-Schema.

**Recovery bei Abbruch:** Sentinel fehlt → nächster `/first-run`-Lauf re-entert
Schritt 3, räumt Staging (3.2) und etwaiges partielles `nas/<slug>` (3.4) auf,
Legacy ist noch da → verlustfreier Neuversuch. Eigener Test-Fall (Sec 7.3).

### 4.5 Fan-out für Read-only-Übersichten [P2]

`--all`-Flag für **genau drei** Commands: `/health-summary`, `/smart-status`,
`/nas-status`.

- **Ohne `--all`:** aktives NAS, Verhalten unverändert.
- **Mit `--all`:** über `smp_list_nas` iterieren (sortiert, deterministisch).
- **Reachability-Probe zuerst (Concern 3):** pro NAS ein einzelner SSH mit
  **kurzem** ConnectTimeout (3s, unabhängig vom Profil-Timeout) als Vorab-Check.
  Schlägt er fehl → NAS sofort als `unreachable` abhaken, **keine** der ~6
  Folge-Queries ausführen. Verhindert, dass ein abgeschaltetes NAS den
  „Schnell"-Überblick um `6 × ConnectTimeout` verlängert.
- Erreichbare NAS: bestehende Single-NAS-Logik ausführen, kompakter Block pro NAS.
- **Aggregat-Verdict nach Worst-of** (`critical` > `warn` > `ok`); `unreachable`
  zählt wie `warn`.

### 4.6 SSH-Pattern & key_path-Validierung [P1]

Unverändert, mit zwei Generalisierungen:
- Key-Pfad kommt aus dem `key_path`-Feld des Profils (statt hardcoded); der
  Inline-Block baut das `SSH=( ... )`-Array (kanonisch `smp_build_ssh`).
- **key_path-Validierung (Concern 7):** `profile.md` ist handeditierbar, `key_path`
  fließt in `ssh -i`. Array-Quoting verhindert Injection (kein `eval`), aber zusätzlich:
  Charset auf Pfad-Zeichen beschränkt (`^[A-Za-z0-9_./~-]+$`, keine
  Newlines/Shell-Metazeichen), danach `$HOME`-Expansion, danach Existenzprüfung der
  Datei. Fail-loud bei Verstoß.

### 4.7 Per-NAS vs. globale Policy (Concern 5) [P1-Entscheidung]

Das Datenmodell trennt bewusst:

- **Per-NAS (im Profil):** `critical_compose_projects` (Schutz-Whitelist für
  `/compose-down`). Liegt korrekt im Profil und wird von `/compose-down` **zur
  Command-Zeit aus dem aktiven Profil** gelesen — ein `/nas-use`-Wechsel nutzt
  automatisch die richtige Whitelist, ohne Zusatz-Verdrahtung. **Die CLAUDE.md-
  Section ist nur ein menschenlesbarer Spiegel**, nicht die Quelle der Wahrheit (Sec 6).
- **Global (Plugin-Policy):** die „Scoped Operations"-Autorisierungen (CLAUDE.md-
  Managed-Section, Checkboxen). Bleiben **global** und werden **nicht** ins per-NAS-
  Profil verschoben (NG8). In Phase 2 zu bewerten, sobald NAS mit unterschiedlichem
  Vertrauensniveau verwaltet werden.

## 5. Command Specifications

### 5.0 Retrofit der bestehenden Commands [P1]

Diese 14 Commands (mit `PROFILE=`-Lese-Boilerplate) ersetzen ihre ad-hoc-Extraktion
durch den **kanonischen Inline-Resolver-Block** (Sec 4.3; exakter Block im Plan).
**Verhalten bei genau einem NAS bleibt funktional identisch:**

`compose-down`, `compose-list`, `compose-logs`, `compose-update`, `compose-up`,
`diag`, `docker-list`, `dsm-update-check`, `health-summary`, `list-shares`,
`logs`, `manage-mounts`, `nas-status`, `smart-status`.

Zusätzlich die beiden **Profil-Schreiber**: `/first-run` (Erzeuger + Migration, 5.1)
und `/setup-ssh` (liest + schreibt) — beide auf NAS-relatives Layout.

Konkrete Änderungen pro Command:
- `PROFILE="context/nas-profile.md"` + Inline-`awk` + Validierung → **kanonischer
  Inline-Resolver-Block** (Legacy-Detektion + Aktiv-Pointer-Auflösung → `PROFILE`,
  `SLUG`, `HOST/PORT/NAS_USER/CONNECT_TIMEOUT/KEY_PATH` + `SSH=( … )`).
- State-Schreibpfade NAS-relativ:
  - `nas-status`: `context/storage-report.md` → `context/nas/$SLUG/storage-report.md`.
  - `list-shares`, `first-run`: `context/volumes/<vol>-snapshot.txt` →
    `context/nas/$SLUG/volumes/<vol>-snapshot.txt`.
  - `manage-mounts`, `first-run`: `context/mounts/current.txt` →
    `context/nas/$SLUG/mounts/current.txt`.
- `diag`: Check `[ -f context/nas-profile.md ]` → Aktiv-NAS-Auflösung (Sec 4.2).
- `health-summary`: Lazy-Migration für `cpu_cores` etc. bleibt, schreibt aber ins
  NAS-relative Profil (`context/nas/$SLUG/profile.md`).
- `setup-ssh`: liest/schreibt das NAS-relative Profil statt `context/nas-profile.md`.
- `compose-down`: behält seine bestehende `critical_compose_projects`-Lazy-Migration,
  jetzt am NAS-relativen Profil.

### 5.1 `/first-run` [P1 — Retrofit + Migration; P2 — Mehrfach-NAS-Awareness]

**Rolle:** Erst-Setup **und** alleiniger Migrations-Trigger (Sec 4.4). Ablauf:
1. **Migration zuerst:** `smp_migrate`-Logik inline ausführen (Legacy → per-NAS-Layout).
2. Auf frischem Workspace das erste NAS anlegen: Slug (Default aus Hostname) +
   Connection, per-NAS-Key, `ssh-copy-id`-Flow, Discovery, atomarer Write nach
   `context/nas/<slug>/profile.md`, Sentinel `context/active-nas` setzen, CLAUDE.md-
   Section rendern (Sec 6).

**Idempotenz nach neuem Layout (Concern 6):** Die „already configured"-Erkennung
liest **nicht** mehr `context/nas-profile.md`, sondern prüft Aktiv-Pointer /
`context/nas/*/`. Ist bereits ein NAS konfiguriert → fragt wie heute, ob neu
aufgesetzt werden soll — überschreibt nie unbeabsichtigt ein migriertes Profil.
Gemeinsamer Intake-Code mit `/nas-add` (5.4).

### 5.2 `/nas-use <slug>` [P2]

**Purpose:** Aktives NAS umschalten. **Schreibend** (`context/active-nas` + CLAUDE.md).

**Arguments:** `<slug>` (positional, **required**, via `${ARGUMENTS:-}`).

**Behaviour:** Slug validieren → Existenz `context/nas/<slug>/profile.md` prüfen
(sonst fail, Hinweis auf `/nas-list`) → `context/active-nas` atomar schreiben →
CLAUDE.md-Section für neues aktives NAS rendern → bestätigen
`Active NAS is now '<slug>' (<host>).`

**Edge cases:** Slug nicht vorhanden → fail, kein Pointer-Update. Bereits aktiv →
„already active", kein Fehler.

> **Argument-Mechanik (erste Aufgabe in Phase 2):** Wie Slash-Commands Argumente
> erhalten, ist über `$ARGUMENTS` zu nutzen (wie `/logs` heute, mit `${ARGUMENTS:-}`
> gegen unbound). Phase 2 verifiziert das zuerst für required-positional und Flags.

### 5.3 `/nas-list` [P2]

**Purpose:** Tabelle aller konfigurierten NAS. **Read-only, kein SSH** (NG7).

**Behaviour:** liest jedes `context/nas/*/profile.md`, extrahiert Slug, Host,
Modell, DSM; markiert aktives NAS.

**Output:**
```
Configured NAS — 2026-05-29T18:00:00Z

   SLUG        HOST              MODEL      DSM
 ● main        192.168.1.10      DS218+     7.3.1-86003
   backup      192.168.1.11      DS220j     7.2.2-72806

Active: main   (switch with /nas-use <slug>)
```

**Edge cases:** kein NAS → `"No NAS configured. Run /first-run."`. Profil mit
`_not configured_` → Zeile als `(incomplete)`, nicht hart fehlschlagen.

### 5.4 `/nas-add` [P2]

**Purpose:** Weiteres NAS hinzufügen; teilt Intake-Code mit `/first-run`.

**Behaviour:** Slug abfragen + validieren + Kollision ausschließen → Connection
(host/port/user, timeout Default 10) → per-NAS-Key
`~/.ssh/synology-manager-plus_<slug>_ed25519` erzeugen (falls fehlend),
`ssh-copy-id`-Flow → Discovery → atomarer Profil-Write → fragen, ob aktiv setzen.

**Edge cases:** Slug-Kollision → fail, Hinweis auf `/nas-use`. Key existiert bereits
→ wiederverwenden, nicht überschreiben (kein Keymaterial-Verlust).

### 5.5 `/nas-remove <slug>` [P2]

**Purpose:** NAS-Profil entfernen. **Destruktiv.**

**Arguments:** `<slug>` (positional, **required** — kein Default-Wahl, „oops"-Risiko).

**Behaviour:**
1. Slug validieren + Existenz prüfen.
2. `AskUserQuestion`: `"Remove NAS '<slug>' (<host>)? This deletes context/nas/<slug>/."`
   (Yes / Cancel).
3. **Separate** Frage: `"Also delete the SSH key <key_path>?"` (Yes / Keep).
   Default: **Keep** (konservativ).
4. `context/nas/<slug>/` löschen; falls bestätigt: `key_path` + `.pub` entfernen —
   aber **nur, wenn kein anderes Profil denselben key_path referenziert** (schützt
   den geteilten Alt-Key des migrierten NAS).
5. War es das aktive NAS: genau ein NAS übrig → das aktiv setzen; mehrere →
   Pointer leeren + Hinweis `/nas-use`; keins → Pointer entfernen.

**Edge cases:** letztes NAS → zusätzliche Warnung im Confirm:
`"This is the last configured NAS — the workspace will be empty afterwards."`.

### 5.6 `--all` für die drei Übersichts-Commands [P2]

`/health-summary --all`, `/smart-status --all`, `/nas-status --all`.

**Argument-Parsing:** `--all` ist das einzige akzeptierte Argument; Unbekanntes →
Usage-Hinweis, exit 1; `${ARGUMENTS:-}` gegen unbound.

**Verhalten:** Reachability-Probe + sequenzieller Fan-out + Worst-of (Sec 4.5).

**Output-Schema (`/health-summary --all`, Beispiel):**
```
NAS Fleet Health — 2026-05-29T18:00:00Z

  SLUG     STORAGE   RAID   DISKS   LOAD   VERDICT
  main     62% ok    ok     38C ok  ok     ok
  backup   91% crit  ok     41C ok  ok     critical
  archive  —         —      —       —      unreachable

Fleet verdict: critical (worst of 3 NAS; 1 unreachable)

── main ──   (bestehender Single-NAS-Block) …
── backup ── (bestehender Single-NAS-Block) …
```

## 6. CLAUDE.md Quick Reference (Managed-Section) [P1 Render-Pfad; P2 nas-use]

Die Managed-Section zwischen `synology-manager-plus:managed-start/end` zeigt **das
aktive NAS** — dieselbe Tabelle wie heute. **In Phase 1** (nur ein NAS) ohne
zusätzliche Hinweise. **In Phase 2** kommen Kopfzeile `Active NAS: <slug>` und
Hinweiszeile `(see /nas-list for all configured NAS)` dazu — der Verweis auf
`/nas-list` erst, wenn dieses Command existiert (R2-2: kein Dangling-Reference in
Phase 1). Geschrieben von `/first-run` (P1) und `/nas-use`/`/nas-add` (P2). Bleibt
**kompakt** (wächst nicht mit der NAS-Anzahl); Flottensicht lebt in `/nas-list`.

**Wichtig (Concern 5):** Die gespiegelten Felder (inkl. `critical_compose_projects`)
sind **Anzeige**, nicht Quelle der Wahrheit — Commands lesen Policy/Whitelist zur
Laufzeit aus dem aktiven Profil. Die „Scoped Operations"-Checkboxen bleiben global
(Sec 4.7). Der User-Notes-Bereich unterhalb des Managed-End-Markers bleibt unangetastet.

## 7. Mock-NAS Extensions & Testing

### 7.1 Static checks [P1]
- **`shellcheck-commands.sh` erweitern:** Es lintet heute **nur `*.md`** (extrahierte
  Bash), NICHT `_*.sh`-Libs — d. h. weder `_compose-lib.sh` noch `_profile-lib.sh`
  werden statisch geprüft. Phase 1 erweitert den Check, sodass er zusätzlich
  `plugin/commands/_*.sh` direkt mit shellcheck prüft. (Schließt nebenbei eine
  bestehende Lücke für `_compose-lib.sh`.)
- Neue Commands [P2] durch `frontmatter-check.sh`; ggf. `validate-manifests.sh`.
- `markdown-lint.sh`, `docker-abspath-check.sh` bleiben grün.

### 7.2 Unit tests (bash-function-level, kein SSH) [P1]
Neue `tests/unit/test-profile-lib.sh` (analog `test-is-critical-compose-project.sh`,
sourcet `$ROOT/plugin/commands/_profile-lib.sh`):
- **Slug-Validierung:** gültig (`main`, `nas-01`); ungültig (`../etc`, `a/b`, `UPPER`,
  leer, 33 Zeichen, führender Bindestrich) → abgelehnt. **Path-Traversal explizit.**
- **`smp_derive_slug` (R2-1):** Hostname leer/garbage/Sonderzeichen → immer gültiger
  Slug (Fallback `main`), **nie leer** (Schutz vor `rm -rf` auf leerem Pfad).
- **key_path-Validierung (Concern 7):** gültige Pfade vs. Newline/Metazeichen/leer.
- **Aktiv-Pointer-Fallback (Sec 4.2):** alle fünf Regeln gegen temp-dir-Fixtures.
- **`smp_list_nas`:** Sortier-Determinismus, Dirs ohne `profile.md` ignoriert.
- **`smp_migrate` (Sec 4.4):** Legacy-Layout in temp-CWD seeden → migriert nach
  `context/nas/<slug>/`, Sentinel gesetzt, Legacy entfernt, Re-Run idempotent.
- **`smp_migrate` Resume (Concern 1):** Abbruch simulieren (Sentinel fehlt, Staging
  oder partielles `nas/<slug>` vorhanden, Legacy intakt) → nächster Lauf verlustfrei.

### 7.3 Integration tests (mock-NAS)
**[P1]**
- Die bestehenden 18 Single-NAS-Smoke-Tests reimplementieren die Command-Logik gegen
  den Mock und schreiben das Profil heute nach `$HOME/nas-profile.md` (sie führen die
  Command-Markdown **nicht** aus). Sie bleiben grün; wo sie das Profil-Layout
  abbilden, werden Helfer (`write_test_profile`, `test-helpers.sh`) auf den
  per-NAS-Pfad aktualisiert, damit sie das migrierte Verhalten spiegeln.
- Migration ist über die **Unit-Tests** (7.2) abgedeckt (reine lokale FS-Operationen,
  kein SSH nötig) — kein separater Integrationstest erforderlich.

**[P2]**
- `test-nas-add.sh`, `test-nas-use.sh`, `test-nas-list.sh`, `test-nas-remove.sh`
  (diese neuen Commands sind selbstständig/inline → per `run_command_snippets`
  ausführbar, mit temp-CWD-`context/`-Fixture).
- `test-fanout.sh` (**Concern 4**): **zwei** Mock-NAS-Instanzen mit
  **unterschiedlichen** smartctl-Profilen — eine `healthy`, eine `critical` (Fixtures
  `tests/fixtures/mock-nas/smartctl-profiles/{healthy,critical}.txt` existieren
  bereits). Assert: Aggregat-Verdict `critical` UND korrekte Pro-NAS-Zeile. Gleicher
  Mock unter zwei Slugs würde Worst-of NICHT prüfen. Plus ein `unreachable`-Fall.

### 7.4 Real-Hardware-Acceptance (Constraint: Test-Setup)
- **[P1] Migration + Single-NAS unverändert:** gegen die DS218+ verifiziert.
- **[P2] Multi-NAS-Pfade:** mehrere echte NAS vorhanden; gegen mindestens zwei
  verschiedene NAS verifizieren (Umschalten, Fan-out, Worst-of). Fallback bei nur
  einem erreichbaren NAS: Doppel-Registrierung (LAN-IP + Hostname).

## 8. Build-Reihenfolge

Ein Feature, zwei Pläne. **Phase 1 bekommt jetzt den Plan**; Phase 2 danach.

### Phase 1 — Fundament (eigener Plan, eigenständig mergebar)
1. `_profile-lib.sh` (kanonische Funktionen) + Unit-Tests zuerst (TDD): Slug-/key_path-
   Validierung, `smp_derive_slug`, Pointer-Fallback, `smp_list_nas`, `smp_migrate`
   (inkl. Resume).
2. `shellcheck-commands.sh` um `_*.sh`-Linting erweitern (deckt auch `_compose-lib.sh`).
3. Kanonischen Inline-Resolver-Block finalisieren (1× im Plan, wörtlich kopierbar).
4. Retrofit der 14 profil-lesenden Commands auf den Inline-Block + NAS-relative
   State-Pfade. Bestehende 18 Smoke-Tests + Helfer entsprechend grün halten.
5. `/first-run`: Migration (`smp_migrate`-Logik inline) + per-NAS-Write + Idempotenz
   über neues Layout. `/setup-ssh`: NAS-relativer Profil-Write.
6. CLAUDE.md Aktiv-NAS-Render-Pfad (von `/first-run`, ohne `/nas-list`-Verweis).
7. Per-NAS vs. global Policy (Sec 4.7) festziehen. Docs (CHANGELOG), Version-Bump.

### Phase 2 — Multi-NAS-UX (eigener Plan)
8. Argument-Mechanik verifizieren (`$ARGUMENTS`, required-positional + Flag).
9. `/nas-list`, `/nas-use`, `/nas-add`, `/nas-remove` (+ Integrationstests).
10. `--all`-Fan-out mit Reachability-Probe (+ Zwei-Instanzen-Fan-out-Test, Concern 4).
11. `/nas-use`/`/nas-add` schreiben CLAUDE.md-Section; `/nas-list`-Verweis ergänzen.
12. Docs (README-Command-Tabelle + Multi-NAS-Abschnitt, CHANGELOG), Version-Bump.

## 9. Security

- **Slug = Pfadkomponente → strenge Validierung** an jeder Eingangsstelle
  (Pointer-Read, Migration-Ableitung, `/nas-use`, `/nas-add`, `/nas-remove`). Regex
  `^[a-z0-9][a-z0-9-]{0,31}$` als primäre Traversal-/Injection-Grenze; Unit-Test
  deckt Traversal ab. `smp_derive_slug` garantiert nie-leer (R2-1) vor `rm -rf`.
- **key_path-Validierung (Concern 7):** Charset- + Existenz-geprüft, nur als
  `ssh -i`-Array-Element (kein `eval`).
- **Pro-NAS-Key = Isolation:** Kompromittierung/Rotation betrifft nur ein NAS.
- **`/nas-remove`** ist die einzige neue destruktive Operation: doppelte Bestätigung
  (Profil + Key separat, Key-Behalten als Default) + Schutz geteilter Keys.
- **Migration fasst `~/.ssh` nicht an** (NG6) und ist **verlustfrei/resumable**
  (Sec 4.4) — Legacy-Originale überleben bis zum Sentinel-Commit.
- **Per-NAS-Whitelist zur Laufzeit** (Sec 4.7): `/compose-down` liest
  `critical_compose_projects` aus dem aktiven Profil, nicht aus der CLAUDE.md-Anzeige.
- **Fan-out ist read-only.** Keine mutierende Operation läuft je über mehrere NAS.

## 10. Acceptance Criteria

### Phase 1 (eigenständig mergebar)
- [ ] `_profile-lib.sh` implementiert; **alle Funktionen unit-getestet** (Slug- +
  key_path-Validierung inkl. Traversal, `smp_derive_slug` nie-leer, Pointer-Fallback,
  `smp_list_nas`, `smp_migrate` inkl. Resume).
- [ ] `shellcheck-commands.sh` lintet zusätzlich `plugin/commands/_*.sh`; alle Libs grün.
- [ ] Kanonischer Inline-Resolver-Block in allen 14 profil-lesenden Commands
  identisch eingesetzt; Single-NAS-Verhalten funktional unverändert; bestehende 18
  Smoke-Tests + Unit-Tests grün.
- [ ] `/first-run` migriert Legacy→per-NAS verlustfrei/resumable und ist idempotent
  (kein Überschreiben migrierter Profile, Concern 6); `/setup-ssh` schreibt
  NAS-relativ.
- [ ] NAS-relative State-Pfade (storage-report/volumes/mounts) in allen Schreibern.
- [ ] Per-NAS vs. global Policy (Sec 4.7) umgesetzt; CLAUDE.md rendert aktives NAS
  ohne `/nas-list`-Verweis; User-Notes unangetastet.
- [ ] Statische Checks grün; Real-Hardware: Migration + Single-NAS unverändert gegen
  DS218+. CHANGELOG + Version-Bump.

### Phase 2
- [ ] Argument-Mechanik verifiziert (required-positional + Flag).
- [ ] `/nas-add`, `/nas-list`, `/nas-use`, `/nas-remove` implementiert, dokumentiert,
  Integrationstests grün.
- [ ] `--all`-Fan-out mit Reachability-Probe (Concern 3); Worst-of + `unreachable`.
- [ ] **`test-fanout.sh` mit zwei Instanzen unterschiedlicher Profile** (Concern 4):
  prüft Worst-of echt.
- [ ] Real-Hardware gegen ≥2 NAS; CLAUDE.md `/nas-list`-Verweis ergänzt; README +
  CHANGELOG; Version-Bump.

## 11. Known Limitations

- **Inline-Duplizierung (Sec 0):** Die Resolver-Logik wird über die 14 Commands +
  den Lib-Spiegel repliziert (CC-Commands können nicht sourcen). Synchron gehalten
  durch Unit-Tests + Konvention — der akzeptierte `_compose-lib`-Tradeoff. **Kein**
  Netto-Cleanup; der Wert ist Konsistenz + Multi-NAS + Testbarkeit.
- **Migration ist einmalig explizit über `/first-run`** (nicht transparent bei jedem
  Command), bewusste Inline-Konsequenz (G5-Tradeoff, Sec 4.4).
- **Fan-out ist sequenziell** (NG1); Reachability-Probe gegen Hänger (Sec 4.5), aber
  bei vielen erreichbaren NAS dauert `--all` ~N × Single-NAS-Laufzeit.
- **Smoke-Tests reimplementieren Command-Logik** (führen die Markdown nicht aus);
  die Lib/Migration-Korrektheit ruht auf den Unit-Tests, die Multi-NAS-Korrektheit
  auf den P2-Integrationstests + Real-Hardware.
- **Single-Session-Annahme.** Zwei gleichzeitige Sessions sind nicht koordiniert
  (Aktiv-Pointer/Migration). Solo-User-Annahme bleibt explizit.
- **Migrierter Alt-Key behält historischen Namen** (`synology-manager-plus_ed25519`),
  neue NAS das `_<slug>_`-Schema — bewusste Inkonsistenz zugunsten „kein
  `~/.ssh`-Eingriff bei Migration".
- **Scoped Operations bleiben global** (NG8); per-NAS-Scoping in Phase 2 zu bewerten.
- **Kein Fan-out für `/logs`/`/dsm-update-check`** (NG3).
```
