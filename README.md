Deutsch | [English](README.en.md)

# PABO – Paperless-Borg Backup Orchestrator

PABO (Paperless-Borg Backup Orchestrator) sichert eine Paperless-ngx-Instanz automatisch. Die Daten landen verschlüsselt in einem lokalen Borg-Repository und danach per rclone auf beliebig vielen Cloud-Zielen. Eine wöchentliche Integritätsprüfung, ein wöchentlicher Restore-Test und Telegram-Meldungen gehören dazu.

## Hintergrund

Ich betreibe seit Jahren eine eigene Paperless-ngx-Instanz. Als sie gewachsen war, reichte ein simples `cp` nicht mehr: Das Backup sollte automatisch laufen, verschlüsselt speichern und im Ernstfall wiederherstellbar sein. Auf BorgBackup bin ich über Vorträge aus dem CCC-Umfeld gestoßen. Deduplizierung, Verschlüsselung und Effizienz haben mich überzeugt. PABO ist das Skript, das daraus entstanden ist.

## Inhaltsverzeichnis

- [Funktionsübersicht](#funktionsübersicht)
- [Voraussetzungen](#voraussetzungen)
- [Installation](#installation)
- [Ersteinrichtung](#ersteinrichtung)
- [Täglicher Betrieb](#täglicher-betrieb)
- [Manuelle Aktionen](#manuelle-aktionen)
- [Restore](#restore)
- [Konfigurationsreferenz](#konfigurationsreferenz)
- [Architektur](#architektur)
- [Sicherheitshinweise](#sicherheitshinweise)
- [Fehlerbehandlung & Exit-Codes](#fehlerbehandlung--exit-codes)
- [Häufige Probleme](#häufige-probleme)

## Funktionsübersicht

| Bereich | Verhalten |
|---|---|
| Verschlüsselung | AES-256 über BorgBackup `repokey` |
| Cloud-Ziele | Ein Archiv pro Lauf, danach ein Upload pro rclone-Remote |
| Datenbank | PostgreSQL-Dump mit `pg_dump --clean --if-exists` |
| Deduplizierung | Borg-intern, Kompression LZ4 |
| Retention | 14 täglich, 8 wöchentlich, 6 monatlich |
| Upload-Schutz | Preflight und `--max-delete` vor jedem `rclone sync` |
| Platzschutz | Abbruch vor `borg create`, wenn weniger als `BACKUP_MIN_FREE_MB` frei ist (Standard 4096 MB) |
| Integritätsprüfung | `borg check --verify-data`, wöchentlich |
| Restore-Test | Wöchentlicher Dry-Run |
| Benachrichtigungen | Telegram bei Erfolg und Fehler |
| Timer | systemd, ohne cron |

## Voraussetzungen

### System

- Debian- oder Ubuntu-Linux (apt wird verwendet)
- Docker und Docker Compose
- Root-Zugriff

### Software

Installiert das Setup von selbst:

- `borgbackup` ab 1.4
- `rclone`
- `jq`
- `curl`
- `postgresql-client`

### Cloud-Speicher

Es braucht mindestens einen konfigurierten rclone-Remote. Gibt es noch keinen, startet das Setup `rclone config` von selbst. Unterstützt sind alle rclone-Remotes, darunter Google Drive, Dropbox, S3, Backblaze B2, OneDrive, SFTP und WebDAV.

## Installation

```bash
# Repository klonen
git clone https://github.com/ArnaudFeld/pabo.git /opt/pabo

# Symlink setzen
ln -s /opt/pabo/pabo.sh /usr/local/sbin/pabo.sh
chmod 755 /opt/pabo/pabo.sh
```

### Updates

```bash
cd /opt/pabo && git pull
```

### Update von 1.0.5 auf 1.1.0

1. Neue Version holen:

```bash
cd /opt/pabo && git pull
```

2. Setup starten und Modus 2 wählen (Scripts und Timer neu generieren). Das entfernt die alten Skripte und Timer pro Ziel und legt die neue Struktur an; Konfiguration, Borg-Repository und Passphrase bleiben unangetastet.
3. Mit `config-check` prüfen. Zwei neue Schlüssel bekommen automatisch Standardwerte (`RCLONE_MAX_DELETE=500`, `BACKUP_MIN_FREE_MB=4096`); wer davon abweichen will, trägt sie in `/etc/paperless-backup.conf` ein oder richtet die Ziele über Modus 1 neu ein.

Vier Verhaltensänderungen betreffen bestehende Installationen. Die Prüfung ist strenger als früher: Pfade mit Leerzeichen, `..` oder doppelten Schrägstrichen sowie ein Bot-Token ohne `<id>:<token>`-Form brechen den Lauf jetzt ab. Exit-Code 10 meldet zusätzlich Abbrüche wegen fehlender Container oder zu wenig freiem Platz. Es gibt nur noch einen Backup-Timer für alle Ziele statt einem Timer pro Ziel. Nach einem Restore fragt das Skript, ob das heruntergeladene Repository in `/backup/restore-repo` gelöscht werden soll.

## Ersteinrichtung

```bash
sudo pabo.sh
# → Menüpunkt 1) setup wählen
```

Der Assistent fragt der Reihe nach ab:

1. Abhängigkeiten installieren
2. rclone-Remotes erkennen oder neu anlegen
3. Cloud-Ziele wählen (Remote plus Zielpfad, mehrere möglich)
4. Docker-Container erkennen (Paperless und PostgreSQL)
5. Pfade bestätigen (Media, Data, Export, Compose-Datei)
6. Warnung, falls Borg-Repo und Daten auf demselben Laufwerk liegen
7. Telegram konfigurieren (Bot-Token und Chat-ID)
8. rclone-Optionen (Bandbreitenlimit, Transfers, Checker, Lösch-Limit, Mindestfreiraum)
9. Borg-Excludes (Logs, NLTK-Daten, temporäre Dateien)
10. Borg-Repository initialisieren (AES-256)
11. Passphrase anzeigen und extern sichern
12. Systemd-Timer einrichten; ab da läuft alles automatisch

Eingaben werden direkt geprüft; ungültige Werte lehnt der Assistent ab und fragt erneut. Existiert das Borg-Repository schon, bleibt es samt Passphrase unangetastet.

### Passphrase sichern

Das Setup legt die Passphrase in `/root/.borg_passphrase` ab (nur root lesbar, Mode 600) und zeigt sie einmal im Terminal. Ohne sie ist das Repository dauerhaft unlesbar. Lege sie in einem Passwortmanager ab (Bitwarden, 1Password, KeePass) oder drucke sie aus und verwahre sie getrennt vom Server.

## Täglicher Betrieb

Nach dem Setup läuft alles über systemd-Timer:

| Timer | Zeitplan | Aktion |
|---|---|---|
| `paperless-backup.timer` | Täglich 02:00 Uhr | Ein Archiv erstellen, Upload in alle Ziele |
| `paperless-borg-check.timer` | Sonntags 03:00 Uhr | Borg-Integritätsprüfung |
| `paperless-restore-test.timer` | Sonntags 04:00 Uhr | Automatischer Restore-Test |

Alle Timer haben `RandomizedDelaySec=900`, starten also bis zu 15 Minuten nach dem Termin. Die Services laufen ohne Zeitlimit (`TimeoutStartSec=infinity`), weil ein Backup länger dauern kann als die systemd-Vorgabe von 90 Sekunden.

### Timer-Status prüfen

```bash
systemctl list-timers | grep paperless
```

### Logs einsehen

```bash
# Backup-Log
tail -50 /var/log/paperless-backup.log

# Borg Check-Log
tail -50 /var/log/paperless-borg-check.log

# Restore-Test-Log
tail -50 /var/log/paperless-restore-test.log

# Systemd Journal
journalctl -u paperless-backup.service -n 50
```

## Manuelle Aktionen

```bash
sudo pabo.sh
```

Das Menü bietet setup (Einrichtung oder Ziele ändern), restore (interaktiver Assistent), test (Backup, Check oder Restore-Test von Hand starten), status (Übersicht über Container, Timer, Archive und Logs) und config-check (Konfiguration und Erreichbarkeit prüfen).

Das Untermenü von test enthält ein echtes Backup, einen Dry-Run, einen reinen Upload in ein einzelnes Ziel, den Borg-Check und den Restore Dry-Run Test.

Bei vorhandener `/etc/paperless-backup.conf` hat setup zwei Modi: Modus 1 ändert nur die Cloud-Ziele und lässt Borg-Repo und Passphrase unverändert; Modus 2 erzeugt Scripts und Timer neu und fasst die Config nicht an.

Ein rotiertes Telegram-Token gehört von Hand in die Config; danach Scripts und Timer neu erzeugen:

```bash
sudo pabo.sh  # → 1) setup → 2)
```

## Restore

```bash
sudo pabo.sh
# → Menüpunkt 2) restore
```

Der Assistent fragt erst Cloud-Ziel und Archiv, danach den Restore-Typ: Voll-Restore (Media, Data, docker-compose.yml und Datenbank), nur Datenbank, nur Media, nur Data, oder Staging in ein alternatives Verzeichnis, das das laufende System nicht anfasst.

Der Ablauf:

1. Platzprüfung: das Remote wird per `rclone size` vermessen; erst ab Repo-Größe mal 1,1 freiem Platz startet der Download.
2. Download des Repositorys aus der Cloud nach `/backup/restore-repo`; das laufende Repository unter `BORG_REPO` bleibt unangetastet.
3. `borg check` über das heruntergeladene Repository.
4. Archivauswahl; der Name muss in der Archivliste stehen.
5. Bei Ziel `/` muss der Archivname zur Bestätigung ein zweites Mal eingegeben werden.
6. Der Paperless-Container wird vor dem Extrahieren gestoppt und danach wieder gestartet.
7. Nachfrage, ob das heruntergeladene Restore-Repo bleiben soll; Standard ist Löschen.

### Manueller Restore bei totalem Systemverlust

```bash
# 1. Abhängigkeiten installieren
apt-get install -y borgbackup rclone jq curl postgresql-client

# 2. Passphrase wiederherstellen
echo "DEINE_PASSPHRASE" > /root/.borg_passphrase
chmod 600 /root/.borg_passphrase

# 3. Borg-Repo von Cloud herunterladen
rclone copy onedrive:/Paperless-Borg-Encrypted /backup/restore-repo

# 4. Archive anzeigen
export BORG_PASSCOMMAND="cat /root/.borg_passphrase"
borg list /backup/restore-repo

# 5. Restore starten
sudo pabo.sh  # → 2) restore
```

### Datenbank manuell leeren

Der Restore spielt den Dump mit `ON_ERROR_STOP` ein und stoppt beim ersten SQL-Fehler; eine stille Teilwiederherstellung gibt es nicht. Schlägt das Einspielen fehl, leere die Datenbank zuerst von Hand. Der `DROP`-Befehl muss über die `postgres`-Datenbank laufen, nicht über `paperless`:

```bash
docker exec db psql -U paperless -d postgres -c "DROP DATABASE paperless;"
docker exec db psql -U paperless -d postgres -c "CREATE DATABASE paperless OWNER paperless;"
```

Die Warnung `collation version mismatch` beim Verbinden betrifft nur interne Sortierungsmetadaten und blockiert weder Backup noch Restore.

## Konfigurationsreferenz

Die Konfiguration steht in `/etc/paperless-backup.conf` und ist nur für root lesbar (Mode 600).

Die Datei wird zeilenweise als Text gelesen, nicht als Shellcode ausgeführt. Jeder Schlüssel steht auf einer Whitelist, jeder Wert wird gegen ein festes Muster geprüft; Unbekanntes oder Ungültiges bricht den Lauf ab. Das setzt die Grenzen: keine Leerzeichen, kein `..` und keine doppelten Schrägstriche in Pfaden; der Bot-Token muss die Form `<id>:<token>` haben, die Chat-ID eine Ganzzahl.

```bash
# PABO – Paperless Backup Konfiguration

PAPERLESS_CONTAINER="paperless-webserver"   # Docker Container Name
DB_CONTAINER="paperless-db"                 # PostgreSQL Container Name
COMPOSE_FILE="/home/paperless/docker-compose.yml"

DB_NAME="paperless"
DB_USER="paperless"

MEDIA_DIR="/data/paperless/media"
DATA_DIR="/data/paperless/data"
EXPORT_DIR="/data/paperless/export"
BORG_REPO="/backup/paperless-borg"          # Lokales Borg-Repository
BACKUP_TMP="/backup/paperless-tmp"          # Temporär für DB-Dump

# Bei Token-Rotation: setup → Modus 2 (neu generieren)
TELEGRAM_TOKEN="123456:ABC..."
TELEGRAM_CHAT_ID="987654321"

BACKUP_TARGETS=(
  onedrive:/Paperless-Borg-Encrypted        # Format: remote:/pfad
  gdrive:/Backups/Paperless
)

RCLONE_BWLIMIT="2M"                        # Leer = kein Limit, z.B. "2M", "500K"
RCLONE_TRANSFERS="4"
RCLONE_CHECKERS="8"
RCLONE_MAX_DELETE="500"                    # Sicherheitsnetz für rclone sync
BACKUP_MIN_FREE_MB="4096"                  # Mindestfreiraum in MB, sonst Abbruch

BORG_EXCLUDES=(
  "/data/paperless/data/log"
  "/data/paperless/data/nltk"
  "*.tmp"
  "*.swp"
  "*.lock"
)

ENABLE_DOCUMENT_EXPORTER="false"           # true = document_exporter vor Backup
EXPORTER_DEST="/usr/src/paperless/export"
```

## Architektur

```
pabo.sh
│
├── /etc/paperless-backup.conf          ← Zentrale Konfiguration (chmod 600, wird nur gelesen)
├── /root/.borg_passphrase              ← Borg-Passphrase (chmod 600)
├── /run/pabo/                          ← Locks (chmod 700, nur root)
│
├── /usr/local/lib/
│   └── paperless-backup-common.sh     ← Shared Library, aus pabo.sh extrahiert
│
├── /usr/local/bin/
│   ├── paperless-backup.sh            ← Täglich: Archiv + Upload in alle Ziele
│   ├── paperless-borg-check.sh        ← Wöchentlicher Integritätscheck
│   └── paperless-restore-test.sh      ← Wöchentlicher Restore Dry-Run
│
└── /etc/systemd/system/
    ├── paperless-backup.{service,timer}
    ├── paperless-borg-check.{service,timer}
    └── paperless-restore-test.{service,timer}
```

Die drei Scripts in `/usr/local/bin` enthalten nur Aufruf und Log-Pfad; die eigentliche Logik steht einmal in der Library, die das Setup aus `pabo.sh` extrahiert.

### Backup-Ablauf

```
flock (/run/pabo/backup.lock)
  │
  ├── Platzprüfung (BACKUP_MIN_FREE_MB, Standard 4096 MB)
  ├── Container-Prüfung (Paperless und Datenbank laufen?)
  ├── [optional] document_exporter
  ├── pg_dump → $BACKUP_TMP/paperless-db.sql (chmod 600, wird danach gelöscht)
  ├── borg create (Media + Data + DB-Dump + compose.yml)
  ├── borg prune (14d/8w/6m)
  ├── borg compact
  └── pro Ziel:
        ├── Preflight: config + Archive + Segmente vorhanden?
        └── rclone sync --max-delete → Cloud
```

## Sicherheitshinweise

| Bereich | Verhalten |
|---|---|
| Verschlüsselung | AES-256 über `repokey`; ohne Passphrase sind die Cloud-Daten unlesbar |
| Konfiguration | Nur root lesbar, wird als Text gelesen und gegen Muster geprüft |
| Passphrase | Nur als Lesebefehl in der Umgebung (`BORG_PASSCOMMAND`), nie als Klartext; die Datei wird vor jeder Nutzung geprüft (vorhanden, kein Symlink, gehört root, Mode 600) |
| Telegram | Token liegt in einer Config mit Mode 600, nicht in der Kommandozeile; ein Ausfall bricht kein Backup ab, der Fehler landet nur im Log; bei Kompromittierung über @BotFather rotieren und Scripts neu erzeugen |
| Locks | `/run/pabo` mit Mode 700, nicht das für alle schreibbare `/var/lock` |
| Upload-Schutz | Preflight und `--max-delete` vor jedem `rclone sync`; ein leeres oder nicht eingehängtes Repo löscht nichts in der Cloud |
| Platzschutz | Abbruch vor `borg create` unter `BACKUP_MIN_FREE_MB` freiem Platz (Standard 4096 MB); Restore-Test braucht Archivgröße mal 1,2, Restore-Download Repo-Größe mal 1,1 |
| Restore | Download in ein eigenes Verzeichnis, Archivname gegen die Liste geprüft, Container gestoppt, Ziel `/` verlangt Bestätigung |
| Secrets | `umask 077` im ganzen Script, PostgreSQL-Dump mit Mode 600, danach gelöscht |
| Passphrase-Verlust | Ohne sie ist das Backup dauerhaft verloren, extern sichern |

## Fehlerbehandlung & Exit-Codes

| Code | Bedeutung |
|---|---|
| 0 | Erfolgreich |
| 10 | Backup abgebrochen (DB-Dump, fehlender Container oder zu wenig Platz) |
| 11 | Borg create/check fehlgeschlagen |
| 12 | rclone Upload zu mindestens einem Ziel fehlgeschlagen |
| 13 | Restore fehlgeschlagen |
| 14 | Restore-Test fehlgeschlagen |

Jeder Fehler löst eine Telegram-Meldung mit Exit-Code und betroffener Komponente aus.

## Häufige Probleme

### Passphrase-Datei fehlt

Die Datei `/root/.borg_passphrase` fehlt. Manuell erstellen:

```bash
echo "DEINE_PASSPHRASE" > /root/.borg_passphrase
chmod 600 /root/.borg_passphrase
```

### Backup läuft bereits

Ein anderer Backup-Prozess ist noch aktiv (`Backup läuft bereits (Lock aktiv)` im Log). Prüfen mit:

```bash
ps aux | grep paperless-backup
ls /run/pabo/
```

### Borg-Repository nicht erreichbar

```bash
export BORG_PASSCOMMAND="cat /root/.borg_passphrase"
borg info /backup/paperless-borg
```

### Upload abgebrochen

Der Schutz vor Datenverlust hat gegriffen: Das lokale Repository hatte keine `config`, keine Archive oder keine Datensegmente. Ursache klären:

```bash
ls -la /backup/paperless-borg
export BORG_PASSCOMMAND="cat /root/.borg_passphrase"
borg list /backup/paperless-borg
```

Solange der Preflight fehlschlägt, wird nichts in die Cloud synchronisiert.

### rclone-Remote fehlt

```bash
rclone listremotes
rclone config  # Remote neu einrichten
sudo pabo.sh  # → 1) setup → 1) Ziele ändern
```

### Telegram-Nachrichten kommen nicht an

Token und Chat-ID von Hand testen:

```bash
curl -s "https://api.telegram.org/bot<TOKEN>/getMe"
curl -s "https://api.telegram.org/bot<TOKEN>/sendMessage" \
  -d "chat_id=<CHAT_ID>&text=Test"
```

### Borg Check schlägt fehl

```bash
export BORG_PASSCOMMAND="cat /root/.borg_passphrase"
borg check --repair /backup/paperless-borg
# Wenn nicht reparierbar: Restore vom letzten funktionierenden Cloud-Backup
```

### `ERROR: cannot drop the currently open database`

Der `DROP`-Befehl darf nicht über die zu löschende Datenbank selbst laufen. Stattdessen über `postgres` verbinden:

```bash
docker exec db psql -U paperless -d postgres -c "DROP DATABASE paperless;"
docker exec db psql -U paperless -d postgres -c "CREATE DATABASE paperless OWNER paperless;"
```

### `WARNING: collation version mismatch`

Diese Warnung erscheint, wenn die PostgreSQL-Collation-Version des Containers nicht zur Version des Betriebssystems passt. Sie blockiert weder Backup noch Restore. Optional beheben mit:

```bash
docker exec db psql -U paperless -d postgres -c "ALTER DATABASE paperless REFRESH COLLATION VERSION;"
docker exec db psql -U paperless -d postgres -c "ALTER DATABASE template1 REFRESH COLLATION VERSION;"
```
