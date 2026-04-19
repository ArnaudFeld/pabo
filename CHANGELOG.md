# Changelog

All notable changes to PABO will be documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

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