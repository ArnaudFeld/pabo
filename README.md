🇩🇪 Deutsch | [🇬🇧 English](README.en.md)

---

# PABO – Paperless-Borg Backup Orchestrator

**PABO** (*Paperless-Borg Backup Orchestrator*) ist ein vollautomatisches Backup-System für [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) – powered by [BorgBackup](https://borgbackup.readthedocs.io/) und [rclone](https://rclone.org/). Unterstützt mehrere Cloud-Ziele gleichzeitig, verschlüsselte lokale Backups, automatische Integritätsprüfungen und wöchentliche Restore-Tests.

## Hintergrund

Ich betreibe seit Jahren eine eigene [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx)-Instanz, die über die Zeit ordentlich gewachsen ist. Irgendwann war klar: ein simples `cp` reicht nicht mehr – ich wollte etwas Zuverlässiges, das automatisch läuft, verschlüsselt speichert und im Ernstfall wirklich wiederherstellbar ist.

Auf BorgBackup bin ich durch Vorträge aus dem CCC-Umfeld gestoßen. Die Kombination aus Deduplizierung, Verschlüsselung und Effizienz hat mich überzeugt. PABO ist das Ergebnis davon: ein Skript, das genau das tut was ich für meine Instanz brauche – nicht mehr, nicht weniger.

---

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

---

## Funktionsübersicht

| Funktion | Details |
|---|---|
| 🔐 Verschlüsselung | AES-256 via BorgBackup `repokey` |
| ☁️ Multi-Cloud | Beliebig viele rclone-Remotes gleichzeitig |
| 🗄️ Datenbank | PostgreSQL-Dump via `pg_dump --clean --if-exists` |
| 📦 Deduplizierung | Borg-interne Deduplizierung + LZ4-Kompression |
| 🔁 Retention | 14 täglich / 8 wöchentlich / 6 monatlich |
| ✅ Integritätsprüfung | Wöchentlicher `borg check --verify-data` |
| 🧪 Restore-Test | Wöchentlicher automatischer Dry-Run |
| 📱 Benachrichtigungen | Telegram bei Erfolg und Fehler |
| ⏰ Automatisierung | Systemd Timer (kein cron notwendig) |

---

## Voraussetzungen

### System
- Debian/Ubuntu-basiertes Linux (apt wird verwendet)
- Docker + Docker Compose
- Root-Zugriff

### Software (wird automatisch installiert)
- `borgbackup` ≥ 1.2
- `rclone`
- `jq`
- `curl`
- `postgresql-client`

### Cloud-Speicher
Mindestens ein konfigurierter rclone-Remote. Falls noch keiner vorhanden ist, startet das Setup automatisch `rclone config`.

Unterstützte Anbieter (Auswahl): Google Drive, Dropbox, S3, Backblaze B2, OneDrive, SFTP, WebDAV – [alle rclone-Remotes](https://rclone.org/overview/).

---

## Installation

```bash
# Script herunterladen
curl -o /usr/local/sbin/pabo.sh \
  https://raw.githubusercontent.com/ArnaudFeld/pabo/main/pabo.sh

# Ausführbar machen
chmod 755 /usr/local/sbin/pabo.sh
```

---

## Ersteinrichtung

```bash
sudo pabo.sh
# → Menüpunkt 1) setup wählen
```

Der Setup-Assistent führt durch folgende Schritte:

1. **Abhängigkeiten installieren** – borgbackup, rclone, jq, curl, postgresql-client
2. **rclone Remotes erkennen** – oder `rclone config` starten falls keiner vorhanden
3. **Cloud-Ziele auswählen** – ein oder mehrere Remotes + Zielpfad
4. **Docker-Container erkennen** – Paperless + PostgreSQL werden automatisch erkannt
5. **Pfade bestätigen** – Media, Data, Export, Compose-Datei
6. **Filesystem-Warnung** – falls Borg-Repo auf demselben Laufwerk wie die Daten liegt
7. **Telegram konfigurieren** – Bot-Token + Chat-ID
8. **rclone-Optionen** – Bandbreitenlimit, parallele Transfers
9. **Borg-Excludes** – Logs, NLTK-Daten, temporäre Dateien
10. **Borg-Repository initialisieren** – AES-256 verschlüsselt
11. **Passphrase anzeigen** – **muss extern gesichert werden!**
12. **Systemd Timer einrichten** – automatischer Betrieb ab sofort

### ⚠️ Passphrase sichern

Nach dem Setup wird eine zufällige Passphrase generiert und in `/root/.borg_passphrase` gespeichert. Diese Datei ist der einzige Schlüssel zum Borg-Repository.

```
┌─────────────────────────────────────────┐
│  ⚠️  BORG PASSPHRASE – SICHER AUFBEWAHREN │
│  xK9mP2...                              │
│  Gespeichert: /root/.borg_passphrase    │
│  → extern sichern!                     │
└─────────────────────────────────────────┘
```

**Empfehlung:** Passphrase in einem Passwortmanager (Bitwarden, 1Password, KeePass) oder ausgedruckt an einem sicheren Ort aufbewahren.

---

## Täglicher Betrieb

Nach dem Setup läuft alles automatisch über Systemd Timer:

| Timer | Zeitplan | Aktion |
|---|---|---|
| `paperless-backup-<remote>.timer` | Täglich 02:00 Uhr | Backup + Upload |
| `paperless-borg-check.timer` | Sonntags | Borg-Integritätsprüfung |
| `paperless-restore-test.timer` | Sonntags | Automatischer Restore-Test |

Bei mehreren Cloud-Zielen werden die Backup-Timer automatisch gestaffelt (02:00, 02:30, 03:00, …).

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
journalctl -u paperless-backup-<remote>.service -n 50
```

---

## Manuelle Aktionen

```bash
sudo pabo.sh
```

| Menüpunkt | Aktion |
|---|---|
| `1) setup` | Ersteinrichtung oder Ziele ändern |
| `2) restore` | Interaktiver Restore-Assistent |
| `3) test` | Manuellen Backup/Check/Restore-Test starten |
| `4) status` | Systemübersicht (Container, Timer, Archive, Logs) |
| `5) config-check` | Konfiguration und Erreichbarkeit prüfen |

### Setup-Modi (bei bestehender Konfiguration)

Beim erneuten Aufruf von `setup` mit vorhandener `/etc/paperless-backup.conf`:

- **Modus 1 – Ziele ändern:** Neue Cloud-Ziele einrichten, Borg und Passphrase bleiben unverändert
- **Modus 2 – Neu generieren:** Scripts und Timer neu erstellen ohne andere Änderungen

### Telegram-Token rotieren

```bash
# TELEGRAM_TOKEN in /etc/paperless-backup.conf manuell ersetzen, dann:
sudo pabo.sh  # → 1) setup → 2) Nur neu generieren
```

---

## Restore

```bash
sudo pabo.sh
# → Menüpunkt 2) restore
```

Der Assistent bietet folgende Optionen:

| Option | Beschreibung |
|---|---|
| 1) Voll-Restore | Media + Data + docker-compose.yml + Datenbank |
| 2) Nur Datenbank | Nur PostgreSQL-Dump einspielen |
| 3) Nur Media | Nur Dokumentendateien wiederherstellen |
| 4) Nur Data | Nur Paperless-Data-Verzeichnis |
| 5) Staging | Restore in alternatives Verzeichnis (ohne laufendes System zu beeinflussen) |

### Manueller Restore bei totalem Systemverlust

```bash
# 1. Abhängigkeiten installieren
apt-get install -y borgbackup rclone jq curl postgresql-client

# 2. Passphrase wiederherstellen
echo "DEINE_PASSPHRASE" > /root/.borg_passphrase
chmod 600 /root/.borg_passphrase

# 3. Borg-Repo von Cloud herunterladen
rclone sync gdrive:/Paperless-Borg-Encrypted /backup/paperless-borg

# 4. Archive anzeigen
export BORG_PASSCOMMAND="cat /root/.borg_passphrase"
borg list /backup/paperless-borg

# 5. Restore starten
sudo pabo.sh  # → 2) restore
```

> **Hinweis zu schwerer Datenbank-Korruption:** Falls `psql` beim Einspielen fehlschlägt, zuerst manuell `DROP DATABASE paperless; CREATE DATABASE paperless;` im PostgreSQL-Container ausführen, dann erneut restore.

---

## Konfigurationsreferenz

Die Konfiguration liegt in `/etc/paperless-backup.conf` (chmod 600, nur root lesbar).

```bash
# Paperless Backup Konfiguration

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
  gdrive:/Paperless-Borg-Encrypted          # Format: remote:/pfad
  dropbox:/Backups/Paperless
)

RCLONE_BWLIMIT="2M"                        # Leer = kein Limit, z.B. "2M", "500K"
RCLONE_TRANSFERS="4"
RCLONE_CHECKERS="8"

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

---

## Architektur

```
paperless-setup.sh
│
├── /etc/paperless-backup.conf          ← Zentrale Konfiguration (chmod 600)
├── /root/.borg_passphrase              ← Borg-Passphrase (chmod 600)
│
├── /usr/local/lib/
│   └── paperless-backup-common.sh     ← Shared Library (run_backup, send_telegram, …)
│
├── /usr/local/bin/
│   ├── paperless-backup-<remote>.sh   ← Pro Cloud-Ziel ein Script
│   ├── paperless-borg-check.sh        ← Wöchentlicher Integritätscheck
│   └── paperless-restore-test.sh      ← Wöchentlicher Restore Dry-Run
│
└── /etc/systemd/system/
    ├── paperless-backup-<remote>.{service,timer}
    ├── paperless-borg-check.{service,timer}
    └── paperless-restore-test.{service,timer}
```

### Backup-Ablauf pro Ziel

```
flock (Lock pro Remote)
  │
  ├── [optional] document_exporter
  ├── pg_dump → /backup/paperless-tmp/paperless-db.sql
  ├── borg create (Media + Data + DB-Dump + compose.yml)
  ├── borg prune (14d/8w/6m)
  ├── borg compact
  └── rclone sync → Cloud
```

---

## Sicherheitshinweise

| Aspekt | Maßnahme |
|---|---|
| Verschlüsselung | AES-256 `repokey` – Daten sind in der Cloud ohne Passphrase unlesbar |
| Config-Schutz | `/etc/paperless-backup.conf` chmod 600, nur root lesbar |
| Passphrase | Nur als Lesebefehl in der Umgebung (`BORG_PASSCOMMAND`), nie als Klartext |
| Telegram | Bot-Token in Config – bei Kompromittierung über @BotFather rotieren + Modus 2 |
| Locks | Pro Remote ein eigener flock-Lock – verhindert parallele Ausführung |
| Passphrase-Verlust | Backup ist **dauerhaft verloren** – extern sichern! |

---

## Fehlerbehandlung & Exit-Codes

| Code | Bedeutung |
|---|---|
| 0 | Erfolgreich |
| 10 | PostgreSQL-Dump fehlgeschlagen |
| 11 | Borg create/check fehlgeschlagen |
| 12 | rclone Upload fehlgeschlagen |
| 13 | Restore fehlgeschlagen |
| 14 | Restore-Test fehlgeschlagen |

Bei jedem Fehler wird eine Telegram-Nachricht mit Exit-Code und betroffener Komponente gesendet.

---

## Häufige Probleme

### `❌ /root/.borg_passphrase nicht gefunden`
Die Passphrase-Datei fehlt. Manuell erstellen:
```bash
echo "DEINE_PASSPHRASE" > /root/.borg_passphrase
chmod 600 /root/.borg_passphrase
```

### `⚠️ Backup läuft bereits (Lock aktiv)`
Ein anderer Backup-Prozess ist noch aktiv. Prüfen mit:
```bash
ps aux | grep paperless-backup
ls /var/lock/paperless-backup-*.lock
```

### Borg-Repository nicht erreichbar
```bash
export BORG_PASSCOMMAND="cat /root/.borg_passphrase"
borg info /backup/paperless-borg
```

### rclone-Remote fehlt
```bash
rclone listremotes
rclone config  # Remote neu einrichten
sudo pabo.sh  # → 1) setup → 1) Ziele ändern
```

### Telegram-Nachrichten kommen nicht an
```bash
# Token und Chat-ID testen:
curl -s "https://api.telegram.org/bot<TOKEN>/getMe"
curl -s "https://api.telegram.org/bot<TOKEN>/sendMessage"   -d "chat_id=<CHAT_ID>&text=Test"
```

### Borg Check schlägt fehl
```bash
export BORG_PASSCOMMAND="cat /root/.borg_passphrase"
borg check --repair /backup/paperless-borg
# Wenn nicht reparierbar: Restore vom letzten funktionierenden Cloud-Backup
```
