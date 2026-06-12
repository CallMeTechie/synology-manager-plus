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

- **`smp_render_sudoers_script`** — Parameter `username`, `docker_path`, `home_path`.
  Gibt das root-Skript auf stdout aus (siehe Abschnitt „Root-Skript"). `home_path`
  wird für den absoluten Pfad des Result-Markers (und ggf. der Upload-Datei) benötigt —
  niemals `~`, da das Skript als root läuft und `~` zu roots Home expandiert.

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
- `smp_render_sudoers_script`: User + Pfad korrekt interpoliert; **konditionaler**
  `visudo`-Branch vorhanden (visudo ist optional, nicht unbedingt); Mode `0440`, Owner
  `root:root`; finaler Drop-in-Name enthält **keinen Punkt** (sudoers ignoriert Dateien
  mit `.` im Namen); Temp-Datei wird in `/etc/sudoers.d` mit Punkt-Präfix angelegt.
- `smp_docker_sudo_probe`: korrekte Klassifizierung gegen gemockte `docker info`-Ausgaben
  (ok / password-required / daemon-down / not-found / unknown).
- `smp_render_sudoers_script`: Result-Marker-Pfad ist absolut (kein `~`); Skript prüft
  `@includedir`/`#includedir`; Skript ist busybox-tauglich (kein `install`-Flag-Zwang).

### Plattform-Annahmen (vor Implementierung auf echter DSM-Box verifizieren)

DSM hat ein gemischtes Userland (teils BusyBox, teils GNU). Das root-Skript darf sich
**nicht** auf GNU-spezifische Flags verlassen:

- `visudo` ist möglicherweise nicht vorhanden → wenn `command -v visudo` leer ist,
  Validierung überspringen und das im Result-Marker vermerken (`validated=no`). Die
  generierte Zeile ist maschinell-simpel, das Restrisiko gering; fail-closed bleibt es,
  weil ein kaputtes Drop-in die Post-Install-Probe sofort als `password-required` zeigt.
- `install -o -g -m` wird **nicht** verwendet (BusyBox-`install` kann die Flags ggf.
  nicht). Stattdessen `mktemp` → `printf` → `chown root:root` → `chmod 0440` → `mv -f`.
- Vor der Umsetzung per SSH prüfen: `command -v visudo install mktemp chown chmod mv`.

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
   - *Upload + Einzeiler* → Skript per bestehender SSH ins **User-Home** laden (Home-Pfad
     vorab via `echo "$HOME"` über SSH ermitteln); die Aufgabe ruft den **absoluten**
     Pfad `bash <home_path>/smp-setup-docker-sudo.sh` — **niemals `~`** (expandiert im
     root-Task zu roots Home, nicht zum User-Home). Vor Ausführung die hochgeladene Datei
     auf `chmod 0700` setzen (TOCTOU-Fläche minimieren: ein als root ausgeführtes, für
     andere schreibbares Skript ist eine Eskalations-Lücke). Cleanup-Hinweis ausgeben.
8. **Stale-Marker löschen** (Proof-of-this-run) — **vor** der GUI-Anleitung, damit der
   User die Aufgabe noch nicht ausgeführt hat: das Plugin löscht einen evtl. vorhandenen
   alten Marker per SSH (`rm -f <home_path>/smp-sudo-setup.result`). Der SSH-User besitzt
   sein Home-Verzeichnis und darf die root-owned `0644`-Datei daher unlinken. Danach ist
   jeder gefundene Marker garantiert aus diesem Lauf.
9. **GUI-Schritte** (kopierfertig):
   > Systemsteuerung → Aufgabenplaner → Erstellen → Geplante Aufgabe →
   > Benutzerdefiniertes Skript. Benutzer: **root**. Reiter „Aufgabeneinstellungen" →
   > Skript einfügen. Speichern → Aufgabe markieren → **Ausführen** → bestätigen.
   > Danach kann die Aufgabe gelöscht werden.
10. **Verifikation**: nach „fertig" zuerst den **Result-Marker** über SSH lesen
   (`<home_path>/smp-sudo-setup.result`), dann Re-Probe mit Retry (3 Versuche, kurzer
   Abstand) via `smp_docker_sudo_probe`:
   - Marker `rc=0` **und** Probe `ok` → Profil `sudo_passwordless: yes` setzen (atomarer
     Edit), `render_claude_md` neu rendern, Erfolg melden.
   - Marker `rc=1` → den echten Fehler aus `stage=`/`msg=` direkt anzeigen
     (z. B. `stage=includedir`, `stage=visudo`) — kein Rätselraten.
   - Kein Marker vorhanden → da der alte Marker in Step 8 gelöscht wurde, heißt das
     **definitiv**: die Aufgabe wurde (noch) nicht ausgeführt **oder** nicht als root
     angelegt. Das ist der häufigste Fall und wird **zuerst** genannt.
   - Marker `rc=0`, aber Probe ≠ `ok` → Diagnose nach realer Häufigkeit:
     1. Aufgabe wirklich als **root** ausgeführt (nicht als anderem User)?
     2. `validated=no` im Marker → visudo fehlte, Syntax ungeprüft — Zeile sichten.
     3. Username im Eintrag = SSH-User (`$USER_NAME` == Profil-`user`)?
     4. `@#includedir /etc/sudoers.d` aktiv (Marker hätte sonst `stage=includedir`)?
     5. `not-found` → Docker-Pfad anpassen; `daemon-down` → Container Manager starten.

## Root-Skript (Sicherheit)

Läuft als root via Aufgabenplaner. Schreibt einen **Result-Marker**, den das Plugin
über SSH liest — der Aufgabenplaner verwirft stdout/stderr, daher ist der Marker der
einzige Weg, den echten Ausgang zu erfahren.

```sh
#!/bin/sh
# synology-manager-plus: NOPASSWD nur für das docker-Binary.
USER_NAME="<profile.user>"
DOCKER_BIN="/usr/local/bin/docker"
DROPIN="/etc/sudoers.d/synology-manager-plus-docker"   # kein '.' im Namen!
MARKER="<profile.home_path>/smp-sudo-setup.result"     # absolut, reboot-fest, plugin-lesbar
LINE="$USER_NAME ALL=(ALL) NOPASSWD: $DOCKER_BIN"

fail() { echo "rc=1 stage=$1 msg=$2" > "$MARKER"; chmod 0644 "$MARKER" 2>/dev/null; exit 1; }

# 0. sudoers.d muss von /etc/sudoers inkludiert sein, sonst ist das Drop-in ein No-Op.
grep -Eq '^[@#]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers \
  || fail includedir "/etc/sudoers includes keine /etc/sudoers.d"

# 1. Temp-Datei IM Zielverzeichnis (Same-FS!) mit Punkt-Praefix — sudoers ignoriert
#    '.'-Dateien, das transiente File ist also waehrend des Fensters inaktiv.
TMP="$(mktemp /etc/sudoers.d/.smp-XXXXXX)" || fail mktemp "mktemp nicht verfuegbar"
printf '%s\n' "$LINE" > "$TMP"

# 2. Validieren VOR Aktivierung, falls visudo existiert; sonst Hinweis im Marker.
if command -v visudo >/dev/null 2>&1; then
  visudo -cf "$TMP" || { rm -f "$TMP"; fail visudo "Syntaxpruefung fehlgeschlagen"; }
  VALIDATED=yes
else
  VALIDATED=no
fi

# 3. Atomar aktivieren: chown/chmod auf der inaktiven Temp-Datei, dann Same-FS-rename.
#    'mv' im selben Verzeichnis ist rename(2) — atomar, kein copy+unlink, kein
#    Fenster fuer eine halb geschriebene Zeile in sudoers.d (Lockout-Schutz).
chown root:root "$TMP" && chmod 0440 "$TMP" || { rm -f "$TMP"; fail perms "chown/chmod"; }
mv -f "$TMP" "$DROPIN" || { rm -f "$TMP"; fail install "rename nach sudoers.d"; }

echo "rc=0 stage=done validated=$VALIDATED user=$USER_NAME bin=$DOCKER_BIN" > "$MARKER"
chmod 0644 "$MARKER" 2>/dev/null
echo "OK: NOPASSWD fuer $USER_NAME -> $DOCKER_BIN aktiv."
```

Sicherheits-Eigenschaften:
- **`@#includedir`-Check zuerst** — schlägt früh und sichtbar (im Marker) fehl, wenn das
  Drop-in wirkungslos wäre, statt still zu scheitern.
- **`visudo -cf` vor Aktivierung** (falls vorhanden) — ein Syntaxfehler in `sudoers.d`
  würde sonst das gesamte sudo-System lahmlegen (Lockout-Schutz). Fehlt `visudo`, wird
  `validated=no` im Marker vermerkt.
- **busybox-tauglich** — `mktemp`/`chown`/`chmod`/`mv` statt `install -o -g -m`.
- **Atomares Same-FS-rename** — Temp-Datei wird in `/etc/sudoers.d` selbst angelegt
  (Punkt-Präfix → von sudo ignoriert), sodass das finale `mv` ein echtes `rename(2)` ist.
  Verhindert, dass ein cross-filesystem copy+unlink eine halbe Zeile in `sudoers.d`
  hinterlässt (Lockout-Restrisiko des visudo-Schutzes geschlossen).
- **Drop-in-Name ohne Punkt** — `sudoers.d` ignoriert Dateien mit `.` im Namen. Mode `0440`,
  Owner `root:root` — sudo ignoriert Drop-ins mit falschem Mode/Owner.
- **Result-Marker** (`rc=…`, `stage=…`, `validated=…`) — vom Plugin lesbar, Mode `0644`,
  macht den als root laufenden Job diagnostizierbar (löst die Output-Blindheit).
- **Username aus dem Profil eingesetzt** — Re-Run überschreibt deterministisch (idempotent).
- **Scope = nur `/usr/local/bin/docker`** — minimal möglich; nicht enger, da compose/run/exec
  alle benötigt werden (alle laufen als das eine Binary mit Argumenten).

## Bug-Fix: Probe-Semantik

Die bisherige Probe `sudo -n true` (`first-run.md:145`) testet **globales** passwortloses
sudo. Sobald scoped `NOPASSWD: /usr/local/bin/docker` eingerichtet ist, schlägt
`sudo -n true` weiterhin fehl (kein NOPASSWD für `true`), während `sudo -n docker`
funktioniert — das Profil würde fälschlich `sudo_passwordless: no` melden.

`sudo_passwordless` wird daher umdefiniert auf **„passwortloses sudo für das docker-Binary"**
(was jeder Consumer real braucht) und an `docker_available` gekoppelt:

Eine Wahrheit: an `docker_available` koppeln. Ist Docker **nicht** installiert →
`sudo_passwordless: n/a` (gar nicht erst proben). Sonst yes/no aus dem echten
docker-Probe:

```bash
# alt: SUDO_OK=$(discover sudo "sudo -n true 2>/dev/null && echo yes || echo no")
# neu (nur proben wenn Docker da ist, sonst n/a):
if [ "$DOCKER_OK" = "not installed" ]; then
  SUDO_OK="n/a"
else
  SUDO_OK=$(discover sudo "sudo -n /usr/local/bin/docker info >/dev/null 2>&1 && echo yes || echo no")
fi
```

Gleiche Änderung in `nas-add.md`.

**Das Profilfeld ist nur ein Cache.** Der Compose-Precheck probet ohnehin bei jedem Lauf
live, daher fängt er ein nach DSM-Update gelöschtes Drop-in auf (Feld sagt noch `yes`,
Realität `no`). Der Zeitstempel kommt in ein **separates** Feld, damit die bestehende
`render_claude_md`-Extraktion (`awk -F': ' … print $2`) unverändert nur `yes`/`no`/`n/a`
liest:

```
- sudo_passwordless: yes
- sudo_checked_at: <ISO 8601 UTC>
```

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
der Erstlauf „ohne Rumdoktern" durchläuft (explizites User-Ziel). Das eigenständige
Command dient späteren Reparaturen. Beide betten denselben Inline-Mirror ein.

**Reihenfolge ist kritisch (Resumability).** Die interaktive GUI-Übergabe ist die
langsamste, fragilste, user-abhängige Phase — der User wechselt minutenlang in die
DSM-GUI. Sie darf **nicht** vor dem atomaren Profil-Write liegen, sonst gehen alle
Discovery-Ergebnisse (in-memory) bei Abbruch verloren und der Wizard muss komplett neu
laufen. Daher:

1. Discovery (Step 5) → Profil **zuerst** atomar schreiben (Step 7) mit dem aktuellen
   Probe-Ergebnis (`sudo_passwordless: no` + `sudo_checked_at`).
2. **Danach** (neuer Step 8, vor der Summary) der Setup-Flow — gated auf
   `docker_available` ≠ not installed **und** Probe ≠ `ok`. Bei Erfolg wird nur das eine
   Feld `sudo_passwordless` auf `yes` aktualisiert (atomarer Edit) + `render_claude_md`.
3. Bricht der User in der GUI-Phase ab, ist das Profil bereits vollständig und korrekt
   (nur Docker-sudo noch offen); `/setup-docker-sudo` setzt später nahtlos fort.

## Im Plan zu klären (offene Implementierungs-Entscheidungen)

Diese Punkte sind bewusst nicht in der Spec festgenagelt, müssen aber im
Implementierungsplan explizit entschieden und nicht stillschweigend übergangen werden:

- **Zwei Docker-Klassifizierer reconcilen.** `_compose-lib.sh` hat bereits
  `docker_daemon_precheck` (eigene Inline-Klassifizierung, return 0/1 + Print); neu kommt
  `smp_docker_sudo_probe` (Status-String). Entscheiden: precheck in Begriffen der neuen
  Probe neu implementieren (eine Wahrheit, Mirror) **oder** Trennung explizit dokumentieren
  mit Begründung. Nicht implizit zwei divergierende Klassifizierer stehen lassen.
- **`set -e`-Sicherheit des Inline-Setup-Flows in first-run.** first-run läuft mit
  `set -euo pipefail`. grep-basierte Klassifizierung liefert exit 1 bei No-Match und würde
  den Wizard abbrechen — gerade im erwarteten `password-required`-Pfad. Jeder
  Klassifizierungs-/grep-Aufruf muss geguardet sein (`|| true` / explizite Exit-Erfassung)
  bzw. der Setup-Flow in einer Subshell ohne `-e` laufen. `smp_docker_sudo_probe` muss
  intern set-e-sicher sein.
- **`home_path`: live ermittelt, nicht persistiert.** Empfehlung: zum Render-Zeitpunkt live
  via `discover home "echo \$HOME"` (neuer Schritt in first-run) bzw. live-Probe in
  `/setup-docker-sudo` — **kein** persistiertes Profilfeld. Falls der Plan stattdessen
  persistieren will, bewusst ins Schema aufnehmen. Eine Variante festlegen.

## Betroffene Dateien (Zusammenfassung)

| Datei | Änderung |
| - | - |
| `plugin/commands/_sudo-lib.sh` | **neu** — kanonische Lib (3 Funktionen) |
| `plugin/commands/setup-docker-sudo.md` | **neu** — eigenständiges Command |
| `plugin/commands/first-run.md` | Probe-Fix; Profil-Schema um `sudo_checked_at`; inline Setup-Flow als **neuer Step 8** (nach atomarem Profil-Write, vor Summary) |
| `plugin/commands/nas-add.md` | Probe-Fix + Angebot |
| `plugin/commands/_compose-lib.sh` | stale `sudo tee`-Hinweis → Verweis auf Command |
| `plugin/CLAUDE.md` | Command-Tabelle, Sudo-Zeilen-Semantik |
| `README` / `CHANGELOG` | Command-Liste, Changelog-Eintrag |
| `tests/unit/test-sudo-lib.sh` | **neu** — Unit-Tests der Lib |
