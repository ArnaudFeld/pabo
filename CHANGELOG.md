# Changelog

All notable changes to PABO will be documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.0.1] – 2026-03-27

### Fixed
- **`cid: unbound variable` crash during setup** (line 823): In the `BORGCHECK` and
  `RESTORETEST` heredocs (both unquoted `<<BORGCHECK` / `<<RESTORETEST`), single quotes
  do not suppress shell expansion. The jq argument `$cid` and `$text` were being
  expanded by the shell at heredoc-write time instead of being written literally into
  the generated scripts. Fixed by escaping both variables as `\$cid` and `\$text`
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