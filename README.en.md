[🇩🇪 Deutsch](README.md) | 🇬🇧 English

***

# PABO – Paperless-Borg Backup Orchestrator

**PABO** (*Paperless-Borg Backup Orchestrator*) is a fully automated backup solution for [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) – powered by [BorgBackup](https://borgbackup.readthedocs.io/) and [rclone](https://rclone.org/). Supports multiple simultaneous cloud targets, encrypted local backups, automatic integrity checks, and weekly restore dry-runs.

## Background

I've been running my own [Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) instance for years, and over time it grew into something I really depend on. At some point a simple `cp` wasn't good enough anymore – I wanted something that runs automatically, stores backups encrypted, and can actually be restored when things go wrong.

I came across BorgBackup through talks from the CCC community. The combination of deduplication, encryption, and efficiency convinced me. PABO is the result: a script that does exactly what I need for my instance – nothing more, nothing less.

***

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Initial Setup](#initial-setup)
- [Daily Operations](#daily-operations)
- [Manual Actions](#manual-actions)
- [Restore](#restore)
- [Configuration Reference](#configuration-reference)
- [Architecture](#architecture)
- [Security](#security)
- [Error Handling & Exit Codes](#error-handling--exit-codes)
- [Troubleshooting](#troubleshooting)

***

## Features

| Feature | Details |
|---|---|
| 🔐 Encryption | AES-256 via BorgBackup `repokey` |
| ☁️ Multi-Cloud | Any number of rclone remotes simultaneously |
| 🗄️ Database | PostgreSQL dump via `pg_dump --clean --if-exists` |
| 📦 Deduplication | Borg-native deduplication + LZ4 compression |
| 🔁 Retention | 14 daily / 8 weekly / 6 monthly |
| ✅ Integrity check | Weekly `borg check --verify-data` |
| 🧪 Restore test | Weekly automated dry-run |
| 📱 Notifications | Telegram on success and failure |
| ⏰ Automation | Systemd timers (no cron required) |

***

## Requirements

### System
- Debian/Ubuntu-based Linux (apt is used)
- Docker + Docker Compose
- Root access

### Software (installed automatically)
- `borgbackup` ≥ 1.4
- `rclone`
- `jq`
- `curl`
- `postgresql-client`

### Cloud Storage
At least one configured rclone remote. If none exists, the setup wizard will launch `rclone config` automatically.

Supported providers (selection): Google Drive, Dropbox, S3, Backblaze B2, OneDrive, SFTP, WebDAV – [all rclone remotes](https://rclone.org/overview/).

***

## Installation

```bash
# Clone the repository
git clone https://github.com/ArnaudFeld/pabo.git /opt/pabo

# Create symlink
ln -s /opt/pabo/pabo.sh /usr/local/sbin/pabo.sh
chmod 755 /opt/pabo/pabo.sh
```

### Updates

```bash
cd /opt/pabo && git pull
```

***

## Initial Setup

```bash
sudo pabo.sh
# → Select menu item 1) setup
```

The setup wizard walks through the following steps:

1. **Install dependencies** – borgbackup, rclone, jq, curl, postgresql-client
2. **Detect rclone remotes** – or launch `rclone config` if none found
3. **Select cloud targets** – one or more remotes + destination path
4. **Detect Docker containers** – Paperless + PostgreSQL auto-detected
5. **Confirm paths** – media, data, export, compose file
6. **Filesystem warning** – if Borg repo is on the same disk as your data
7. **Configure Telegram** – bot token + chat ID
8. **rclone options** – bandwidth limit, parallel transfers
9. **Borg excludes** – logs, NLTK data, temp files
10. **Initialize Borg repository** – AES-256 encrypted
11. **Display passphrase** – **must be stored externally!**
12. **Set up systemd timers** – automated operation starts immediately

### ⚠️ Save your passphrase

After setup, a random passphrase is generated and stored in `/root/.borg_passphrase`. This file is the only key to the Borg repository.

```
┌─────────────────────────────────────────┐
│  ⚠️  BORG PASSPHRASE – KEEP IT SAFE      │
│  xK9mP2...                              │
│  Stored at: /root/.borg_passphrase      │
│  → back up externally!                  │
└─────────────────────────────────────────┘
```

**Recommendation:** Store the passphrase in a password manager (Bitwarden, 1Password, KeePass) or in print at a secure location.

***

## Daily Operations

After setup, everything runs automatically via systemd timers:

| Timer | Schedule | Action |
|---|---|---|
| `paperless-backup-<remote>.timer` | Daily at 02:00 | Backup + upload |
| `paperless-borg-check.timer` | Sundays | Borg integrity check |
| `paperless-restore-test.timer` | Sundays | Automated restore test |

With multiple cloud targets, backup timers are automatically staggered (02:00, 02:30, 03:00, …).

### Check timer status

```bash
systemctl list-timers | grep paperless
```

### View logs

```bash
# Backup log
tail -50 /var/log/paperless-backup.log

# Borg check log
tail -50 /var/log/paperless-borg-check.log

# Restore test log
tail -50 /var/log/paperless-restore-test.log

# Systemd journal
journalctl -u paperless-backup-<remote>.service -n 50
```

***

## Manual Actions

```bash
sudo pabo.sh
```

| Menu item | Action |
|---|---|
| `1) setup` | Initial setup or change targets |
| `2) restore` | Interactive restore wizard |
| `3) test` | Manually trigger backup/check/restore test |
| `4) status` | System overview (containers, timers, archives, logs) |
| `5) config-check` | Validate configuration and reachability |

### Setup modes (with existing configuration)

When running `setup` with an existing `/etc/paperless-backup.conf`:

- **Mode 1 – Change targets:** Configure new cloud targets, Borg and passphrase remain untouched
- **Mode 2 – Regenerate:** Recreate scripts and timers without any other changes

### Rotating the Telegram token

```bash
# Manually replace TELEGRAM_TOKEN in /etc/paperless-backup.conf, then:
sudo pabo.sh  # → 1) setup → 2) Regenerate only
```

***

## Restore

```bash
sudo pabo.sh
# → Select menu item 2) restore
```

The wizard offers the following restore options:

| Option | Description |
|---|---|
| 1) Full restore | Media + Data + docker-compose.yml + database |
| 2) Database only | Restore PostgreSQL dump only |
| 3) Media only | Restore document files only |
| 4) Data only | Restore Paperless data directory only |
| 5) Staging | Restore to an alternative directory (non-destructive) |

### Manual restore after total system loss

```bash
# 1. Install dependencies
apt-get install -y borgbackup rclone jq curl postgresql-client

# 2. Restore passphrase
echo "YOUR_PASSPHRASE" > /root/.borg_passphrase
chmod 600 /root/.borg_passphrase

# 3. Download Borg repo from cloud
rclone sync gdrive:/Paperless-Borg-Encrypted /backup/paperless-borg

# 4. List available archives
export BORG_PASSCOMMAND="cat /root/.borg_passphrase"
borg list /backup/paperless-borg

# 5. Start restore
sudo pabo.sh  # → 2) restore
```

> **Note on severe database corruption:** If `psql` fails during restore, the database
> must first be dropped and recreated manually. Important: the `DROP` command must be
> run against the `postgres` database, not `paperless` (otherwise:
> `cannot drop the currently open database`):
>
> ```bash
> docker exec db psql -U paperless -d postgres -c "DROP DATABASE paperless;"
> docker exec db psql -U paperless -d postgres -c "CREATE DATABASE paperless OWNER paperless;"
> ```
>
> A `collation version mismatch` warning during the connection is harmless and can be
> ignored – it only affects internal sort metadata and does not block the restore.

***

## Configuration Reference

The configuration is stored in `/etc/paperless-backup.conf` (chmod 600, root-only).

```bash
# PABO – Paperless Backup Configuration

PAPERLESS_CONTAINER="paperless-webserver"   # Docker container name
DB_CONTAINER="paperless-db"                 # PostgreSQL container name
COMPOSE_FILE="/home/paperless/docker-compose.yml"

DB_NAME="paperless"
DB_USER="paperless"

MEDIA_DIR="/data/paperless/media"
DATA_DIR="/data/paperless/data"
EXPORT_DIR="/data/paperless/export"
BORG_REPO="/backup/paperless-borg"          # Local Borg repository
BACKUP_TMP="/backup/paperless-tmp"          # Temporary storage for DB dump

# For token rotation: run setup → Mode 2 (regenerate)
TELEGRAM_TOKEN="123456:ABC..."
TELEGRAM_CHAT_ID="987654321"

BACKUP_TARGETS=(
  gdrive:/Paperless-Borg-Encrypted          # Format: remote:/path
  dropbox:/Backups/Paperless
)

RCLONE_BWLIMIT="2M"                        # Empty = no limit, e.g. "2M", "500K"
RCLONE_TRANSFERS="4"
RCLONE_CHECKERS="8"

BORG_EXCLUDES=(
  "/data/paperless/data/log"
  "/data/paperless/data/nltk"
  "*.tmp"
  "*.swp"
  "*.lock"
)

ENABLE_DOCUMENT_EXPORTER="false"           # true = run document_exporter before backup
EXPORTER_DEST="/usr/src/paperless/export"
```

***

## Architecture

```
pabo.sh
│
├── /etc/paperless-backup.conf          ← Central configuration (chmod 600)
├── /root/.borg_passphrase              ← Borg passphrase (chmod 600)
│
├── /usr/local/lib/
│   └── paperless-backup-common.sh     ← Shared library (run_backup, send_telegram, …)
│
├── /usr/local/bin/
│   ├── paperless-backup-<remote>.sh   ← One script per cloud target
│   ├── paperless-borg-check.sh        ← Weekly integrity check
│   └── paperless-restore-test.sh      ← Weekly restore dry-run
│
└── /etc/systemd/system/
    ├── paperless-backup-<remote>.{service,timer}
    ├── paperless-borg-check.{service,timer}
    └── paperless-restore-test.{service,timer}
```

### Backup flow per target

```
flock (lock per remote)
  │
  ├── [optional] document_exporter
  ├── pg_dump → /backup/paperless-tmp/paperless-db.sql
  ├── borg create (media + data + DB dump + compose.yml)
  ├── borg prune (14d/8w/6m)
  ├── borg compact
  └── rclone sync → cloud
```

***

## Security

| Aspect | Measure |
|---|---|
| Encryption | AES-256 `repokey` – data in the cloud is unreadable without the passphrase |
| Config protection | `/etc/paperless-backup.conf` chmod 600, root-only |
| Passphrase | Only a read command in the environment (`BORG_PASSCOMMAND`), never plaintext |
| Telegram | Bot token in config – if compromised, rotate via @BotFather + run Mode 2 |
| Locks | One flock lock per remote – prevents parallel execution |
| Passphrase loss | Backup is **permanently lost** – store it externally! |

***

## Error Handling & Exit Codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 10 | PostgreSQL dump failed |
| 11 | Borg create/check failed |
| 12 | rclone upload failed |
| 13 | Restore failed |
| 14 | Restore test failed |

On every error, a Telegram message is sent with the exit code and the affected component.

***

## Troubleshooting

### `❌ /root/.borg_passphrase not found`
The passphrase file is missing. Create it manually:
```bash
echo "YOUR_PASSPHRASE" > /root/.borg_passphrase
chmod 600 /root/.borg_passphrase
```

### `⚠️ Backup already running (lock active)`
Another backup process is still active. Check with:
```bash
ps aux | grep paperless-backup
ls /var/lock/paperless-backup-*.lock
```

### Borg repository unreachable
```bash
export BORG_PASSCOMMAND="cat /root/.borg_passphrase"
borg info /backup/paperless-borg
```

### rclone remote missing
```bash
rclone listremotes
rclone config  # Reconfigure remote
sudo pabo.sh  # → 1) setup → 1) Change targets
```

### Telegram notifications not arriving
```bash
# Test token and chat ID:
curl -s "https://api.telegram.org/bot<TOKEN>/getMe"
curl -s "https://api.telegram.org/bot<TOKEN>/sendMessage" \
  -d "chat_id=<CHAT_ID>&text=Test"
```

### Borg check fails
```bash
export BORG_PASSCOMMAND="cat /root/.borg_passphrase"
borg check --repair /backup/paperless-borg
# If unrepairable: restore from last working cloud backup
```

### `ERROR: cannot drop the currently open database`
The `DROP DATABASE` command must not be run against the database being dropped.
Connect via `postgres` instead:
```bash
docker exec db psql -U paperless -d postgres -c "DROP DATABASE paperless;"
docker exec db psql -U paperless -d postgres -c "CREATE DATABASE paperless OWNER paperless;"
```

### `WARNING: collation version mismatch`
This warning appears when the PostgreSQL collation version of the container does not
match the operating system. It is **harmless** and does not block backup or restore.
Optionally fix with:
```bash
docker exec db psql -U paperless -d postgres -c "ALTER DATABASE paperless REFRESH COLLATION VERSION;"
docker exec db psql -U paperless -d postgres -c "ALTER DATABASE template1 REFRESH COLLATION VERSION;"
```