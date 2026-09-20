# Changelog

All notable changes to PABO will be documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.1.0] – 2026-09-11

### Security
- **Configuration is no longer executed.** `/etc/paperless-backup.conf` used to
  be loaded with `source`, i.e. as shell code running as root on every timer
  run. It is now read line by line as text: every key must be on a whitelist,
  every value is validated against a fixed pattern before it is assigned.
  Unknown keys and invalid values abort the run. The three generated scripts
  use the same parser.
- **No more injection when writing the configuration.** The setup wrote values
  into an unquoted heredoc. A value containing a quotation mark (possible for
  `TELEGRAM_TOKEN`, `TELEGRAM_CHAT_ID` and `EXPORTER_DEST`, which were not
  validated) produced a self-contained line that was executed as root on the
  next run. Configuration output now goes through `_conf_emit`, which refuses
  any value with quotes, backslashes, `$()`, `${}`, backticks or newlines.
- **Passphrase no longer at risk during setup.** `/root/.borg_passphrase` was
  overwritten before `borg init` ran. When `borg init` failed (repository
  already present), the previous passphrase was gone and the repository became
  unreadable. Setup now detects an existing repository, keeps the passphrase and
  backs the file up before writing a new one.
- **Uploads can no longer wipe the cloud.** `rclone sync` deleted everything in
  the remote that was missing locally. A preflight (repository `config`,
  archives and data segments present) plus `--max-delete`
  (`RCLONE_MAX_DELETE`, default 500) now run before every sync. A missing or
  unmounted repository aborts the upload instead of deleting remote data.
- **Locks moved out of `/var/lock`.** That directory is world-writable and the
  lock files were opened with a plain redirection, so a local user could
  pre-create them as symlinks or block backups. Locks now live in `/run/pabo`
  (chmod 700).
- **Telegram token removed from the command line.** It was part of the `curl`
  URL and visible in the process list. It is now passed via a 0600 curl config
  file.
- **Secrets are created with restrictive permissions.** `umask 077` is set for
  the whole script, and the PostgreSQL dump, the configuration and the
  passphrase file are created with mode 600 instead of being world-readable for
  a short window. The dump is also removed via an exit trap, so a failed backup
  no longer leaves the database in plaintext on disk.
- **Passphrase file is checked before use**: present, not a symlink, owned by
  root, mode 600 (corrected automatically).
- **Disk space guards.** `create_archive` aborts before `borg create` when free
  space on the repository filesystem falls below `BACKUP_MIN_FREE_MB`
  (new configuration key, default 4096 MB, asked during setup) – instead of
  running into a full disk mid-run. The restore measures the remote first with
  `rclone size` and only downloads when at least repo size × 1.1 is free.
  `config-check` and `status` report the free space on the repository
  filesystem.
- **Restore leaves no second copy on disk.** After the restore the user is
  asked whether the downloaded repository in `/backup/restore-repo` should be
  kept (default: delete, with ownership check).
- **Restore no longer overwrites a running installation silently.** The download
  goes to `/backup/restore-repo` instead of the live repository, the archive
  name is validated against the archive list, the Paperless container is stopped
  before extraction, and restoring to `/` requires entering the archive name
  again.
- **Restore test uses `mktemp -d`** under a 0700 directory instead of a
  predictable path, checks free space against the archive size and verifies
  ownership before cleanup.

### Fixed
- **Missing containers were only noticed mid-run.** With a wrong or stopped
  container name in the configuration, the backup failed at `document_exporter`
  and `pg_dump` with an opaque Docker error. `create_archive` now checks both
  containers up front and aborts with a clear message, `config-check` verifies
  that both containers are actually running, and the database restore refuses to
  start `psql` against a stopped container.
- **Setup failed with a confusing multi-line error.** `docker inspect` can
  return several matching mount lines, so `MEDIA_DIR` and friends arrived at the
  configuration writer with embedded newlines and were rejected with the value
  printed across lines. Detected values now take the first line only, values
  that cannot be stored trigger a re-prompt, and all collected values are
  validated with the same patterns as the parser before the configuration file
  is written. Invalid values in error messages are displayed escaped.
- **Silent partial database restore.** `psql` was invoked without
  `-v ON_ERROR_STOP=1`, which returns exit code 0 even when SQL statements fail
  in the middle of the dump. A restore that had only partially completed was
  reported as successful. The restore now stops at the first SQL error and
  reports the failure (exit 13, Telegram notification).
- **Systemd killed long-running backups.** The units had no `TimeoutStartSec`,
  so the systemd default of 90 seconds applied and terminated `borg create` or
  `rclone` mid-run, leaving stale Borg locks. Units now set
  `TimeoutStartSec=infinity` and `TimeoutStopSec=300`.
- **Retention was wrong with more than one cloud target.** Every target created
  its own archive, so `borg prune --keep-daily=14` counted archives instead of
  days and 14 daily archives covered only 14/N days. One archive is now created
  per run and uploaded to all targets afterwards.
- **A Telegram outage could abort a backup.** `send_telegram` was called
  stand-alone under `set -e`, so a failed `curl` ended the run after
  `borg create` but before prune, upload and cleanup. Telegram errors are now
  logged only.
- **Hard-coded dump path during restore.** The SQL dump was expected at
  `backup/paperless-tmp/paperless-db.sql`; with any other `BACKUP_TMP` the
  database restore and the restore test failed. The path is now derived from
  `BACKUP_TMP`.
- **Fragile in-place config edit** when changing targets (`sed` on the
  `BACKUP_TARGETS` block); the file is now rewritten as a whole.
- **`cd` handling during restore**, which previously left the shell in a deleted
  temporary directory, is now done in subshells.

### Changed
- `pabo.sh` re-execs itself with `/bin/bash` when started via `sh`, which points
  to dash on Debian and cannot parse the script (arrays, `[[ =~ ]]`).
- One backup script and one timer (`paperless-backup`) instead of one script and
  timer per cloud target; the old per-target units are removed on setup.
- Borg check runs Sundays at 03:00, restore test at 04:00 (previously derived
  from the number of targets).
- The generated scripts are thin wrappers; all logic lives in
  `/usr/local/lib/paperless-backup-common.sh`, which is extracted from the
  common code block of `pabo.sh` so there is no second copy.
- Systemd units hardened with `UMask=0077`, `PrivateTmp=true`,
  `ProtectSystem=full`, `NoNewPrivileges=true` and `RandomizedDelaySec=900`.
- Setup validates Telegram token, chat ID, bandwidth limit, exporter path and
  custom excludes on input instead of accepting anything.
- `config-check` additionally verifies the Borg version, the passphrase file
  mode, the repository directory and the reachability of every rclone remote.
- Timer schedule: backup daily 02:00, check Sunday 03:00, test Sunday 04:00.

## [1.0.5] – 2026-04-19

### Fixed
- **BrokenPipeError during DB restore** (`run_restore`, types 1 and 2):
  `borg extract --stdout … | docker exec -i … psql` caused a `BrokenPipeError`
  with Borg 1.4+ because Borg writes the archive index to stdout alongside the
  file content, which confuses the psql pipe. Fixed by extracting the SQL dump
  into a `mktemp -d` directory first, then feeding it to psql via
  `psql < file` redirect.
- **`getwd: no such file or directory` after DB restore**:
  After the DB tmpdir was cleaned up via `trap … RETURN`, the shell's current
  working directory pointed into the now-deleted tmpdir, causing Docker Compose
  to fail with `getwd: no such file or directory` when trying to start Paperless.
  Fixed by saving `$PWD` into `PREV_DIR` before `cd "$DB_TMP"` and restoring it
  with `cd "$PREV_DIR"` after cleanup.

---

## [1.0.4] – 2026-04-19

### Changed
- **Simplified heredoc structure in `generate_scripts()`**: Removed legacy
  comment blocks and redundant inline annotations that were carried over from
  earlier versions, improving readability of the generated scripts.
- **Config header updated to v1.0.4**: The comment written to
  `/etc/paperless-backup.conf` during setup now reflects the correct version.

### Fixed
- **Minor quoting inconsistencies in `validate_conf()`**: Regex patterns for
  `_check_path` and `_check_name` aligned across all call sites to prevent
  false-positive validation errors on valid paths containing dots or hyphens.

---

## [1.0.3] – 2026-03-29

### Fixed
- **Missing `/` separator in restore-test path construction** (lines 949, 958, 965):
  In the `RESTORETEST` heredoc, `EXTRACTED_MEDIA`, `EXTRACTED_DATA`, and
  `EXTRACTED_COMPOSE` were built by concatenating `${TEST_DIR}` directly with the
  result of `$(echo ${…} | sed 's|^/||')`, without a `/` between them. This caused
  paths like `/backup/restore-test/20260329-040028data/paperless/media` instead of
  `/backup/restore-test/20260329-040028/data/paperless/media`, making all three
  directory/file existence checks fail and the restore-test always report failure via
  Telegram even when the archive was intact. Fixed by inserting `/` between `${TEST_DIR}`
  and the `$(echo …)` subshell in all three assignments.

---

## [1.0.2] – 2026-03-27

### Fixed
- **Unescaped jq variables in remaining heredocs**: Extended the heredoc escape fix
  from 1.0.1 to all remaining affected heredocs where `$cid` / `$text` were still
  being expanded at write-time by the outer shell.

### Changed
- **`celerybeat-schedule.db` excluded from Borg backup by default**: Added
  `${DATA_DIR}/celerybeat-schedule.db` to the default `BORG_EXCLUDES` during setup,
  as this file is a runtime lock/state file that should not be backed up and can cause
  unnecessary archive churn.

---

## [1.0.1] – 2026-03-27

### Fixed
- **`cid: unbound variable` crash during setup** (line 823): In the `BORGCHECK` and
  `RESTORETEST` heredocs (both unquoted `<<BORGCHECK` / `<<RESTORETEST`), single quotes
  do not suppress shell expansion. The jq argument `$cid` and `$text` were being
  expanded by the shell at heredoc-write time instead of being written literally into
  the generated scripts. Fixed by escaping both variables as `\\\\$cid` and `\\\\$text`
  inside the affected heredocs, so the generated scripts receive the correct literal
  `$cid` / `$text` jq variable references.

---

## [1.0.0] – 2026-03-09

### Added
- Initial release of PABO – Paperless-Borg Backup Orchestrator
- Multi-cloud support via rclone (unlimited targets)
- AES-256 encrypted local Borg repository
- PostgreSQL dump via `pg_dump --clean --if-exists`
- Automatic systemd timer setup (per-target, staggered)
- Weekly `borg check --verify-data` integrity check
- Weekly automated restore dry-run test
- Telegram notifications (success + failure, with jq JSON-safe escaping)
- Interactive setup wizard with auto-detection of Docker containers and paths
- Three setup modes: initial / change targets / regenerate scripts
- Interactive restore wizard (full / DB-only / media-only / staging)
- `config-check` command for validating configuration and reachability
- `status` command with live overview (timers, archives, logs)
- Config validation (`validate_conf`) after every `source /etc/paperless-backup.conf`
- Filesystem warning when Borg repo is on the same disk as Paperless data
- Per-remote flock locks (prevents archive name collision)
- `prompt_int()` with retry loop and EOF protection
- `borg_repo_size()` compatible with Borg 1.x and 2.x (no numfmt dependency)
- `cleanup_old_scripts()` before regenerating (stops timers, removes old units)
- `printf %q` safe quoting for BACKUP_TARGETS and BORG_EXCLUDES in config
- `trap` for tmp_conf cleanup on error (prevents token leak in /tmp)
- curl `--max-time 10 --connect-timeout 5` on all Telegram calls
- PABO ASCII-art branding in main menu