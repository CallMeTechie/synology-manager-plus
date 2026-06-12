# Design: Passwortloses Docker-sudo via DSM-Aufgabenplaner

_Spec verfasst am 2026-06-12._

## Problemstellung

Alle Container-Operationen des Plugins laufen über `sudo -n /usr/local/bin/docker …`
(siehe `docker-list.md`, `compose-up.md`, `_compose-lib.sh`). Der Docker-Daemon-Socket
auf DSM gehört `root:root`; eine brauchbare, persistente `docker`-Gruppe existiert auf
Synology nicht. `sudo` ist damit der einzige stabile Weg, und für den nicht-interaktiven
Betrieb (`sudo -n`) ist ein `NOPASSWD`-Eintrag in `/etc/sudoers.d/` zwingend.

Das Schreiben dieses Eintrags braucht selbst root — ein Henne-Ei-Problem, das das Plugin
nicht selbst lösen kann und auch nicht soll (kein Passwort-Handling, kein root-SSH).

**Verifiziert:** Der robusteste und glaubwürdigste Weg, einmalig ein root-Skript auf DSM
auszuführen, ist der **Aufgabenplaner** (Control Panel → Task Scheduler →
*Benutzerdefiniertes Skript*, Benutzer `root`). Er läuft nativ als root (kein Passwort im
Skript), umgeht das `requiretty`/tty-Problem von sudo-über-SSH, ist für den User in der
DSM-GUI nachvollziehbar, und funktioniert **auch dann, wenn der SSH-User selbst kein
sudo-Recht hat** (dedizierter Service-User). Für das empfohlene Service-User-Setup ist er
praktisch der einzige GUI-Weg.

**Einschränkung:** Eine Aufgabenplaner-Aufgabe lässt sich nicht zuverlässig per SSH/API
anlegen (`synoschedtask` ist undokumentiert und braucht selbst root). Der eine manuelle
GUI-Schritt bleibt beim User — und genau diesen Schritt macht dieses Design maximal
reibungslos: Skript generieren, Anleitung liefern, Ergebnis selbst verifizieren.

## Ziele

- First-run richtet passwortloses Docker-sudo als **Standard-Vorgehen** ohne Rumdoktern ein.
- Eigenständiges, wiederverwendbares `/setup-docker-sudo` für spätere Reparaturen
  (DSM-Updates löschen `sudoers.d`-Drop-ins regelmäßig).
- Transparente, plausible Sicherheits-Kommunikation an den User.
- Bug-Fix der bestehenden, fehlerhaften `sudo_passwordless`-Probe.

## Nicht-Ziele

- Kein programmatisches Anlegen der Aufgabenplaner-Aufgabe (technisch nicht zuverlässig).
- Kein Passwort-Handling / kein interaktives sudo über automatisiertes SSH.
- Keine Einschränkung des NOPASSWD-Scopes unter das `docker`-Binary hinaus (nicht möglich,
  ohne compose/run/exec zu brechen).

## Architektur & Komponenten

### Konvention dieses Repos

CC-Plugin-Commands können Libs **nicht zur Laufzeit sourcen**. Etablierte Lösung
(`docker-list.md:17-18`, `compose-up.md:17-18`): Eine kanonische, unit-getestete Lib ist die
Source of Truth; jede Command-Markdown bettet einen **Inline-Mirror** ein und hält ihn in
Sync. Dieses Design folgt der Konvention.

### Neue Lib `plugin/commands/_sudo-lib.sh` (kanonisch, unit-getestet)

Drei Funktionen als Single Source of Truth:

- **`smp_docker_sudo_probe`** — führt `sudo -n <docker> info` über eine SSH-Array-Referenz
  aus und klassifiziert das Ergebnis in genau einen Status:
  - `ok` — Daemon antwortet mit Versionsnummer (`ServerVersion`)
  - `password-required` — sudo verlangt Passwort (NOPASSWD fehlt)
  - `daemon-down` — „Cannot connect to the Docker daemon"
  - `not-found` — docker-Binary nicht am erwarteten Pfad
  - `unknown` — alles andere (erste 3 Zeilen der Ausgabe zur Diagnose)

  Ersetzt die fehlerhafte `sudo -n true`-Logik und wird von first-run,
  `/setup-docker-sudo` und (in Mirror-Form) vom compose-Precheck genutzt.

- **`smp_render_sudoers_script`** — Parameter `username`, `docker_path`. Gibt das
  visudo-validierte root-Skript auf stdout aus (siehe Abschnitt „Root-Skript").

- **`smp_user_is_admin_probe`** — liefert das SSH-Payload-Schnipsel
  `id -Gn 2>/dev/null | grep -qw administrators && echo admin || echo standard`,
  um Service- vs. Admin-User für die Tonalität der Empfehlung zu unterscheiden.

### Neues Command `plugin/commands/setup-docker-sudo.md`

Eigenständig, jederzeit ausführbar. `allowed-tools: Bash, Read, Write, Edit, AskUserQuestion`.

### Geänderte Dateien

- `first-run.md` — Probe-Fix (Abschnitt „Bug-Fix") + inline geführter Setup-Flow.
- `_compose-lib.sh` — der stale `sudo tee`-Hinweis (Z. 36-41) wird durch die
  Klassifizierungs-Semantik + Verweis „Run `/setup-docker-sudo` to fix." ersetzt.
- `nas-add.md` — gleiche Probe-Semantik + Angebot, den Flow für die neue NAS zu fahren.
- `plugin/CLAUDE.md` (Command-Tabelle, Semantik der Sudo-Zeile), `README`, `CHANGELOG`.

### Test

`tests/unit/test-sudo-lib.sh`:
- `smp_render_sudoers_script`: User + Pfad korrekt interpoliert; `visudo -cf` vorhanden;
  Mode `0440`, Owner `root:root`; Drop-in-Name enthält **keinen Punkt**
  (sudoers ignoriert Dateien mit `.` im Namen).
- `smp_docker_sudo_probe`: korrekte Klassifizierung gegen gemockte `docker info`-Ausgaben
  (ok / password-required / daemon-down / not-found / unknown).

## Flow: `/setup-docker-sudo`

1. **Aktive NAS auflösen** (Inline-Mirror des profile-lib-Resolvers wie in den anderen
   Commands).
2. **Ist-Zustand proben** via `smp_docker_sudo_probe`:
   - `ok` → melden „bereits eingerichtet", beenden (**idempotent**).
   - Docker nicht installiert (`docker_available` = not installed) → freundlich beenden.
   - sonst → weiter.
3. **Docker-Pfad** = Konstante `/usr/local/bin/docker` (konsistent mit gesamtem Code).
   Bei `not-found`: gezielter Hinweis, `which docker` auf der NAS zu prüfen und den Pfad
   anzupassen.
4. **User-Modell erkennen** via `smp_user_is_admin_probe`:
   - `standard` (Service-User) → Botschaft „Aufgabenplaner ist **zwingend**".
   - `admin` → Botschaft „Aufgabenplaner ist der **empfohlene** Weg"; reaktiver
     interaktiver sudo-Edit nur als Fortgeschrittenen-Fußnote.
5. **Sicherheits-Hinweis** (transparent, vor Skript-Ausgabe): NOPASSWD auf `docker` ist
   effektiv Root auf der NAS; lässt sich nicht enger fassen.
6. **Skript generieren** via `smp_render_sudoers_script` mit exaktem Username + Pfad.
7. **Aufgabenplaner-Anleitung** ausgeben **und Liefermechanik per `AskUserQuestion` wählen
   lassen** (dem User die Wahl):
   - *Vollskript einfügen* → Skript im Chat ausgeben **und** Kopie nach
     `context/nas/<slug>/setup-docker-sudo.sh` schreiben (Referenz). User fügt es 1:1 ins
     Skriptfeld der Aufgabe ein.
   - *Upload + Einzeiler* → Skript per bestehender SSH ins **User-Home** laden (nicht
     `/tmp` — reboot-fest); die Aufgabe ruft nur `bash ~/smp-setup-docker-sudo.sh`.
     Cleanup-Hinweis ausgeben.
8. **GUI-Schritte** (kopierfertig):
   > Systemsteuerung → Aufgabenplaner → Erstellen → Geplante Aufgabe →
   > Benutzerdefiniertes Skript. Benutzer: **root**. Reiter „Aufgabeneinstellungen" →
   > Skript einfügen. Speichern → Aufgabe markieren → **Ausführen** → bestätigen.
   > Danach kann die Aufgabe gelöscht werden.
9. **Verifikation**: nach „fertig" Re-Probe mit Retry (3 Versuche, kurzer Abstand) via
   `smp_docker_sudo_probe`:
   - Erfolg → Profil `sudo_passwordless: yes` setzen (atomarer Edit), `render_claude_md`
     neu rendern, Erfolg melden.
   - Misserfolg → gezielte Diagnose anhand des Probe-Status:
     - `password-required` → Username im Eintrag ≠ SSH-User? Task als falschem User
       gelaufen (nicht root)? Drop-in-Name mit Punkt?
     - `not-found` → Docker-Pfad anpassen.
     - `daemon-down` → Container Manager nicht gestartet.

## Root-Skript (Sicherheit)

```sh
#!/bin/sh
set -e
USER_NAME="<profile.user>"
DOCKER_BIN="/usr/local/bin/docker"
DROPIN="/etc/sudoers.d/synology-manager-plus-docker"   # kein '.' im Namen!
TMP="$(mktemp)"
printf '%s ALL=(ALL) NOPASSWD: %s\n' "$USER_NAME" "$DOCKER_BIN" > "$TMP"
visudo -cf "$TMP"                                       # validieren VOR Aktivierung
install -m 0440 -o root -g root "$TMP" "$DROPIN"
rm -f "$TMP"
echo "OK: NOPASSWD fuer $USER_NAME -> $DOCKER_BIN aktiv."
```

Sicherheits-Eigenschaften:
- **`visudo -cf` vor Aktivierung** — ein Syntaxfehler in `sudoers.d` würde sonst das
  gesamte sudo-System lahmlegen (Lockout-Schutz).
- **`install -m 0440 -o root -g root`** atomar in einem Schritt — sudo ignoriert Drop-ins
  mit falschem Mode/Owner.
- **Drop-in-Name ohne Punkt** — `sudoers.d` ignoriert Dateien mit `.` im Namen.
- **Username aus dem Profil eingesetzt** — Re-Run überschreibt deterministisch (idempotent).
- **Scope = nur `/usr/local/bin/docker`** — minimal möglich; nicht enger, da compose/run/exec
  alle benötigt werden.

## Bug-Fix: Probe-Semantik

Die bisherige Probe `sudo -n true` (`first-run.md:145`) testet **globales** passwortloses
sudo. Sobald scoped `NOPASSWD: /usr/local/bin/docker` eingerichtet ist, schlägt
`sudo -n true` weiterhin fehl (kein NOPASSWD für `true`), während `sudo -n docker`
funktioniert — das Profil würde fälschlich `sudo_passwordless: no` melden.

`sudo_passwordless` wird daher umdefiniert auf **„passwortloses sudo für das docker-Binary"**
(was jeder Consumer real braucht) und an `docker_available` gekoppelt:

```bash
# alt: SUDO_OK=$(discover sudo "sudo -n true 2>/dev/null && echo yes || echo no")
# neu:
SUDO_OK=$(discover sudo "[ -x /usr/local/bin/docker ] && sudo -n /usr/local/bin/docker info >/dev/null 2>&1 && echo yes || echo no")
```

Ist Docker nicht installiert, wird `n/a` gespeichert. Gleiche Änderung in `nas-add.md`.

## Fehlerbehandlung & Edge-Cases

- **DSM beschränkt SSH standardmäßig auf die `administrators`-Gruppe** — ein echter
  Service-User ohne Admin-Recht kann sich evtl. gar nicht per SSH einloggen. Da first-run
  diesen Flow erst nach erfolgreichem SSH erreicht, ist SSH hier bereits nachgewiesen; der
  Flow warnt jedoch beim **Empfehlen** des Service-User-Modells explizit über die nötige
  DSM-Freigabe (Terminal & SNMP / Benutzergruppen-Rechte).
- **Kein DSM-Admin-Zugang / kein Aufgabenplaner verfügbar** → dokumentierter Fallback:
  manueller `sudoers`-Edit per Admin-SSH (nur für Admin-User sinnvoll).
- **Docker-Pfad-Varianz über DSM-Versionen** → Konstante + `not-found`-Diagnose
  (Verhalten konsistent mit bestehendem `_compose-lib.sh`).
- **Re-Run / Idempotenz** → Probe-Gate beendet bei `ok` sauber; Skript überschreibt das
  Drop-in deterministisch.
- **Upload-Variante** nutzt das User-Home statt `/tmp` (reboot-fest) und gibt einen
  Cleanup-Hinweis.

## Integration in first-run

First-run **treibt den Flow inline** (Inline-Mirror der `_sudo-lib`-Funktionen plus
GUI-/Liefer-/Verifikations-Schritte), statt an `/setup-docker-sudo` zu delegieren — damit
der Erstlauf „ohne Rumdoktern" durchläuft (explizites User-Ziel). Gating: nur wenn
`docker_available` ≠ not installed **und** Probe ≠ `ok`. Das eigenständige Command dient
späteren Reparaturen. Beide betten denselben Inline-Mirror ein.

## Betroffene Dateien (Zusammenfassung)

| Datei | Änderung |
| - | - |
| `plugin/commands/_sudo-lib.sh` | **neu** — kanonische Lib (3 Funktionen) |
| `plugin/commands/setup-docker-sudo.md` | **neu** — eigenständiges Command |
| `plugin/commands/first-run.md` | Probe-Fix + inline Setup-Flow (Step ~5.5) |
| `plugin/commands/nas-add.md` | Probe-Fix + Angebot |
| `plugin/commands/_compose-lib.sh` | stale `sudo tee`-Hinweis → Verweis auf Command |
| `plugin/CLAUDE.md` | Command-Tabelle, Sudo-Zeilen-Semantik |
| `README` / `CHANGELOG` | Command-Liste, Changelog-Eintrag |
| `tests/unit/test-sudo-lib.sh` | **neu** — Unit-Tests der Lib |
