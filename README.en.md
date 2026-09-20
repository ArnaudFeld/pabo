[Deutsch](README.md) | English

# PABO – Paperless-Borg Backup Orchestrator

PABO (Paperless-Borg Backup Orchestrator) backs up a Paperless-ngx instance automatically. Data goes encrypted into a local Borg repository, then out to any number of cloud targets via rclone. A weekly integrity check, a weekly restore test and Telegram messages are part of it.

## Background

I have run my own Paperless-ngx instance for years. Once it had grown, plain `cp` was no longer enough: backups had to run on their own, store data encrypted, and restore for real when it counts. I first heard about BorgBackup in talks from the CCC community. Deduplication, encryption and efficiency convinced me. PABO is the script that came out of it.

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Initial setup](#initial-setup)
- [Daily operations](#daily-operations)
- [Manual actions](#manual-actions)
- [Restore](#restore)
- [Configuration reference](#configuration-reference)
- [Architecture](#architecture)
- [Security](#security)
- [Error handling & exit codes](#error-handling--exit-codes)
- [Troubleshooting](#troubleshooting)

## Features

| Area | Behavior |
|---|---|
| Encryption | AES-256 via BorgBackup `repokey` |
| Cloud targets | One archive per run, then one upload per rclone remote |
| Database | PostgreSQL dump with `pg_dump --clean --if-exists` |
| Deduplication | Native to Borg, LZ4 compression |
| Retention | 14 daily, 8 weekly, 6 monthly |
| Upload guard | Preflight plus `--max-delete` before every `rclone sync` |
| Space guard | Abort before `borg create` when less than `BACKUP_MIN_FREE_MB` is free (default 4096 MB) |
| Integrity check | `borg check --verify-data`, weekly |
| Restore test | Weekly dry-run |
| Notifications | Telegram on success and failure |
| Timers | systemd, no cron needed |

## Requirements

### System

- Debian- or Ubuntu-based Linux (apt is used)
- Docker and Docker Compose
- Root access

### Software

The setup installs these on its own:

- `borgbackup` 1.4 or newer
- `rclone`
- `jq`
- `curl`
- `postgresql-client`

### Cloud storage

At least one configured rclone remote is needed. If none exists, the setup starts `rclone config` on its own. All rclone remotes are supported, including Google Drive, Dropbox, S3, Backblaze B2, OneDrive, SFTP and WebDAV.

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

### Upgrading from 1.0.5 to 1.1.0

1. Fetch the new version:

```bash
cd /opt/pabo && git pull
```

2. Start setup and pick mode 2 (regenerate scripts and timers). It removes the old per-target scripts and timers and creates the new layout; configuration, Borg repository and passphrase stay untouched.
3. Run `config-check`. Two new keys get automatic defaults (`RCLONE_MAX_DELETE=500`, `BACKUP_MIN_FREE_MB=4096`); to change them, edit `/etc/paperless-backup.conf` or re-run target setup via mode 1.

Four behavior changes affect existing installations. Validation is stricter than before: paths with spaces, `..` or double slashes, and a bot token that does not look like `<id>:<token>`, abort the run now. Exit code 10 additionally reports aborts from missing containers or low disk space. There is only one backup timer for all targets instead of one timer per target. After a restore, the script asks whether to delete the downloaded repository in `/backup/restore-repo`.

## Initial setup

```bash
sudo pabo.sh
# → Select menu item 1) setup
```

The wizard asks for input in this order:

1. Install dependencies
2. Detect rclone remotes or create new ones
3. Pick cloud targets (remote plus destination path, several allowed)
4. Detect Docker containers (Paperless and PostgreSQL)
5. Confirm paths (media, data, export, compose file)
6. Warn if Borg repo and data sit on the same disk
7. Configure Telegram (bot token and chat ID)
8. rclone options (bandwidth limit, transfers, checkers, delete limit, minimum free space)
9. Borg excludes (logs, NLTK data, temp files)
10. Initialize Borg repository (AES-256)
11. Show the passphrase and store it externally
12. Set up systemd timers; from there everything runs on its own

Input is validated on the spot; the wizard rejects invalid values and asks again. If the Borg repository already exists, it and the passphrase stay untouched.

### Save the passphrase

Setup stores the passphrase in `/root/.borg_passphrase` (root only, mode 600) and shows it once in the terminal. Without it the repository stays unreadable for good. Keep it in a password manager (Bitwarden, 1Password, KeePass) or print it and store it away from the server.

## Daily operations

After setup, everything runs on systemd timers:

| Timer | Schedule | Action |
|---|---|---|
| `paperless-backup.timer` | Daily at 02:00 | Create one archive, upload to all targets |
| `paperless-borg-check.timer` | Sundays at 03:00 | Borg integrity check |
| `paperless-restore-test.timer` | Sundays at 04:00 | Automated restore test |

All timers carry `RandomizedDelaySec=900`, so they start up to 15 minutes after the scheduled time. The services run without a time limit (`TimeoutStartSec=infinity`) because a backup can take longer than the systemd default of 90 seconds.

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
journalctl -u paperless-backup.service -n 50
```

## Manual actions

```bash
sudo pabo.sh
```

The menu offers setup (first setup or change targets), restore (interactive wizard), test (start a backup, check or restore test by hand), status (overview of containers, timers, archives and logs) and config-check (validate the configuration and reachability).

The test submenu holds a real backup, a dry-run, a plain upload to a single target, the Borg check and the restore dry-run test.

With an existing `/etc/paperless-backup.conf`, setup has two modes: mode 1 changes only the cloud targets and leaves Borg repo and passphrase alone; mode 2 regenerates scripts and timers and does not touch the config.

A rotated Telegram token goes into the config by hand; then regenerate scripts and timers:

```bash
sudo pabo.sh  # → 1) setup → 2)
```

## Restore

```bash
sudo pabo.sh
# → Select menu item 2) restore
```

The wizard asks for cloud target and archive first, then for the restore type: full restore (media, data, docker-compose.yml and database), database only, media only, data only, or staging into an alternative directory that leaves the running system alone.

The procedure:

1. Free-space preflight: the remote is measured with `rclone size`; the download only starts once repo size times 1.1 is free.
2. Download of the repository from the cloud to `/backup/restore-repo`; the live repository at `BORG_REPO` stays untouched.
3. `borg check` against the downloaded repository.
4. Archive selection; the name has to appear in the archive list.
5. When restoring to `/`, the archive name has to be entered a second time for confirmation.
6. The Paperless container is stopped before extraction and started again afterwards.
7. A question whether the downloaded restore repo should stay; the default is to delete it.

### Manual restore after total system loss

```bash
# 1. Install dependencies
apt-get install -y borgbackup rclone jq curl postgresql-client

# 2. Restore passphrase
echo "YOUR_PASSPHRASE" > /root/.borg_passphrase
chmod 600 /root/.borg_passphrase

# 3. Download Borg repo from cloud
rclone copy gdrive:/Paperless-Borg-Encrypted /backup/restore-repo

# 4. List available archives
export BORG_PASSCOMMAND="cat /root/.borg_passphrase"
borg list /backup/restore-repo

# 5. Start restore
sudo pabo.sh  # → 2) restore
```

### Empty the database manually

The restore feeds the dump through `psql` with `ON_ERROR_STOP` and stops at the first SQL error; there is no silent partial restore. If applying the dump fails, empty the database by hand first. The `DROP` command has to run against the `postgres` database, not `paperless`:

```bash
docker exec db psql -U paperless -d postgres -c "DROP DATABASE paperless;"
docker exec db psql -U paperless -d postgres -c "CREATE DATABASE paperless OWNER paperless;"
```

The `collation version mismatch` warning on connect concerns internal sort metadata only and blocks neither backup nor restore.

## Configuration reference

The configuration lives in `/etc/paperless-backup.conf` and is readable only by root (mode 600).

The file is read line by line as text, never executed as shell code. Every key sits on a whitelist, every value is checked against a fixed pattern; anything unknown or invalid aborts the run. That sets the limits: no spaces, no `..` and no double slashes in paths; the bot token has to look like `<id>:<token>` and the chat ID has to be an integer.

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
RCLONE_MAX_DELETE="500"                    # Safety net for rclone sync
BACKUP_MIN_FREE_MB="4096"                  # Minimum free space in MB, otherwise abort

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

## Architecture

```
pabo.sh
│
├── /etc/paperless-backup.conf          ← Central configuration (chmod 600, read as data)
├── /root/.borg_passphrase              ← Borg passphrase (chmod 600)
├── /run/pabo/                          ← Locks (chmod 700, root only)
│
├── /usr/local/lib/
│   └── paperless-backup-common.sh     ← Shared library, extracted from pabo.sh
│
├── /usr/local/bin/
│   ├── paperless-backup.sh            ← Daily: archive + upload to all targets
│   ├── paperless-borg-check.sh        ← Weekly integrity check
│   └── paperless-restore-test.sh      ← Weekly restore dry-run
│
└── /etc/systemd/system/
    ├── paperless-backup.{service,timer}
    ├── paperless-borg-check.{service,timer}
    └── paperless-restore-test.{service,timer}
```

The three scripts in `/usr/local/bin` hold only the call and the log path; the logic lives once in the library, which the setup extracts from `pabo.sh`.

### Backup flow

```
flock (/run/pabo/backup.lock)
  │
  ├── Space check (BACKUP_MIN_FREE_MB, default 4096 MB)
  ├── Container check (Paperless and database running?)
  ├── [optional] document_exporter
  ├── pg_dump → $BACKUP_TMP/paperless-db.sql (chmod 600, removed afterwards)
  ├── borg create (media + data + DB dump + compose.yml)
  ├── borg prune (14d/8w/6m)
  ├── borg compact
  └── per target:
        ├── preflight: config + archives + segments present?
        └── rclone sync --max-delete → cloud
```

## Security

| Area | Behavior |
|---|---|
| Encryption | AES-256 via `repokey`; without the passphrase the cloud data is unreadable |
| Configuration | Root only, read as text and checked against patterns |
| Passphrase | Only a read command in the environment (`BORG_PASSCOMMAND`), never plaintext; the file is checked before every use (present, not a symlink, owned by root, mode 600) |
| Telegram | Token lives in a config with mode 600, not on the command line; an outage never aborts a backup, the failure is only logged; if compromised, rotate via @BotFather and regenerate the scripts |
| Locks | `/run/pabo` with mode 700, not the world-writable `/var/lock` |
| Upload guard | Preflight plus `--max-delete` before every `rclone sync`; an empty or unmounted repo deletes nothing in the cloud |
| Space guard | Abort before `borg create` below `BACKUP_MIN_FREE_MB` of free space (default 4096 MB); restore test needs archive size times 1.2, restore download needs repo size times 1.1 |
| Restore | Download into a separate directory, archive name checked against the list, container stopped, target `/` requires confirmation |
| Secrets | `umask 077` throughout the script, PostgreSQL dump with mode 600, removed afterwards |
| Passphrase loss | Without it the backup is lost for good, store it externally |

## Error handling & exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 10 | Backup aborted (DB dump, missing container or low disk space) |
| 11 | Borg create/check failed |
| 12 | rclone upload to at least one target failed |
| 13 | Restore failed |
| 14 | Restore test failed |

Every error triggers a Telegram message with exit code and affected component.

## Troubleshooting

### Passphrase file missing

The file `/root/.borg_passphrase` is missing. Create it manually:

```bash
echo "YOUR_PASSPHRASE" > /root/.borg_passphrase
chmod 600 /root/.borg_passphrase
```

### Backup already running

Another backup process is still active (`Backup already running (lock active)` in the log). Check with:

```bash
ps aux | grep paperless-backup
ls /run/pabo/
```

### Borg repository unreachable

```bash
export BORG_PASSCOMMAND="cat /root/.borg_passphrase"
borg info /backup/paperless-borg
```

### Upload aborted

The guard against data loss has kicked in: the local repository had no `config`, no archives or no data segments. Find the cause:

```bash
ls -la /backup/paperless-borg
export BORG_PASSCOMMAND="cat /root/.borg_passphrase"
borg list /backup/paperless-borg
```

While the preflight fails, nothing is synced to the cloud.

### rclone remote missing

```bash
rclone listremotes
rclone config  # Set up the remote again
sudo pabo.sh  # → 1) setup → 1) Change targets
```

### Telegram notifications not arriving

Test token and chat ID by hand:

```bash
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

The `DROP` command must not run against the database being dropped. Connect via `postgres` instead:

```bash
docker exec db psql -U paperless -d postgres -c "DROP DATABASE paperless;"
docker exec db psql -U paperless -d postgres -c "CREATE DATABASE paperless OWNER paperless;"
```

### `WARNING: collation version mismatch`

This warning appears when the PostgreSQL collation version of the container does not match the operating system version. It blocks neither backup nor restore. Optionally fix with:

```bash
docker exec db psql -U paperless -d postgres -c "ALTER DATABASE paperless REFRESH COLLATION VERSION;"
docker exec db psql -U paperless -d postgres -c "ALTER DATABASE template1 REFRESH COLLATION VERSION;"
```
