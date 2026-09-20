#!/bin/bash
# pabo.sh – PABO: Paperless-Borg Backup Orchestrator v1.1.0
# Automated, encrypted, multi-cloud backups for Paperless-ngx
# powered by BorgBackup and rclone.
# https://github.com/ArnaudFeld/pabo
# Aufruf mit `sh` landet auf Debian in dash, das Arrays und [[ =~ ]] nicht
# kennt – hier umschalten, bevor irgendetwas bash-Spezifisches geparst wird.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi
set -euo pipefail
umask 077

# ═════════════════════════════════════════════
# GEMEINSAMER CODE-BLOCK
# Dieser Abschnitt wird unverändert nach
# /usr/local/lib/paperless-backup-common.sh extrahiert (generate_lib)
# und von den generierten Scripts gesourct.
# ═════════════════════════════════════════════
# >>> PABO COMMON BEGIN

PABO_VERSION="1.1.0"

CONF_FILE="/etc/paperless-backup.conf"
PASSPHRASE_FILE="/root/.borg_passphrase"
SCRIPT_DIR="/usr/local/bin"
LIB_FILE="/usr/local/lib/paperless-backup-common.sh"
LOCK_DIR="/run/pabo"
RESTORE_REPO="/backup/restore-repo"
RESTORE_TEST_DIR="/backup/restore-test"
MIN_BORG_VERSION="1.4.0"
# Die generierten Scripts überschreiben LOG_FILE nach dem Sourcen.
LOG_FILE="${LOG_FILE:-/var/log/paperless-backup.log}"

EXIT_OK=0; EXIT_DB=10; EXIT_BORG=11; EXIT_RCLONE=12; EXIT_RESTORE=13; EXIT_RESTORE_TEST=14

# ─────────────────────────────────────────────
# AUSGABE UND GRUNDLAGEN
# ─────────────────────────────────────────────

log() {
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  if [[ -n "${LOG_FILE:-}" ]]; then
    printf '%s\n' "$line" | tee -a "$LOG_FILE"
  else
    printf '%s\n' "$line"
  fi
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "❌ Bitte als root ausführen."
    exit 1
  fi
}

ensure_lock_dir() {
  if [[ ! -d "$LOCK_DIR" ]]; then
    install -d -m 700 "$LOCK_DIR"
  fi
}

# Passphrase-Datei: vorhanden, root gehörend, kein Symlink, Mode 600
check_passphrase() {
  if [[ ! -f "$PASSPHRASE_FILE" ]]; then
    echo "❌ ${PASSPHRASE_FILE} nicht gefunden!"
    echo "   Bitte Passphrase manuell nach ${PASSPHRASE_FILE} schreiben (chmod 600)"
    exit 1
  fi
  if [[ -L "$PASSPHRASE_FILE" ]]; then
    echo "❌ ${PASSPHRASE_FILE} ist ein Symlink – Abbruch."
    exit 1
  fi
  local mode owner
  mode=$(stat -c '%a' "$PASSPHRASE_FILE" 2>/dev/null || echo "")
  owner=$(stat -c '%u' "$PASSPHRASE_FILE" 2>/dev/null || echo "")
  if [[ -n "$owner" && "$owner" != "0" ]]; then
    echo "❌ ${PASSPHRASE_FILE} gehört nicht root – Abbruch."
    exit 1
  fi
  if [[ -n "$mode" && "$mode" != "600" ]]; then
    echo "⚠️  ${PASSPHRASE_FILE} hat Mode ${mode} – korrigiere auf 600"
    chmod 600 "$PASSPHRASE_FILE"
  fi
}

# ─────────────────────────────────────────────
# WERTE-PRÜFUNG
# Alle Werte werden geprüft, bevor sie in eine Variable geschrieben
# oder an borg/rclone/docker weitergereicht werden.
# ─────────────────────────────────────────────

valid_name()  { [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]]; }
valid_int()   { [[ "$1" =~ ^[0-9]+$ ]]; }
valid_bool()  { [[ "$1" == "true" || "$1" == "false" ]]; }
valid_token() { [[ "$1" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{20,}$ ]]; }
valid_chatid(){ [[ "$1" =~ ^-?[0-9]+$ ]]; }
valid_target() {
  local re='^[A-Za-z0-9_-]+:[A-Za-z0-9/_. -]+$'
  [[ "$1" =~ $re ]]
}
valid_bwlimit() {
  [[ -z "$1" ]] && return 0
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?[KMGkmg]?$ ]]
}

# Absolute Pfade ohne Leerzeichen, ohne .. und ohne doppelte Schrägstriche.
# Leerzeichen sind ausgeschlossen, weil die Pfade in generierten Snippets
# und Borg-Pfadmustern verwendet werden.
valid_path() {
  local v="$1"
  if [[ ! "$v" =~ ^/[A-Za-z0-9._/-]+$ ]]; then return 1; fi
  if [[ "$v" == *"//"* ]]; then return 1; fi
  if [[ "$v" == *"/.."* || "$v" == *"../"* ]]; then return 1; fi
  if [[ "$v" == */ ]]; then return 1; fi
  return 0
}

# Borg-Excludes sind --exclude Argumente (immer gequotet).
# Nur leere Werte und Shell-Substitutionen sind gefährlich.
# Zeichen, die in der Config-Datei nie auftauchen dürfen, weil die Datei
# zeilenweise als Text gelesen wird.
_conf_embeddable() {
  local v="$1"
  local subst1 subst2 backtick backslash
  # shellcheck disable=SC2016
  subst1='$('
  # shellcheck disable=SC2016
  subst2='${'
  # shellcheck disable=SC2016
  backtick='`'
  backslash="\\"
  if [[ "$v" == *'"'* || "$v" == *"'"* ]]; then return 1; fi
  if [[ "$v" == *"$subst1"* || "$v" == *"$subst2"* || "$v" == *"$backtick"* ]]; then
    return 1
  fi
  if [[ "$v" == *"$backslash"* ]]; then return 1; fi
  if [[ "$v" == *$'\n'* || "$v" == *$'\r'* ]]; then return 1; fi
  return 0
}

# Borg-Excludes sind --exclude Argumente (immer gequotet).
# Alles, was in der Config-Datei nicht sicher steht, wird abgelehnt.
valid_exclude() {
  local v="$1"
  if [[ -z "$v" ]]; then return 1; fi
  if ! _conf_embeddable "$v"; then return 1; fi
  if [[ "$v" == *';'* || "$v" == *'&'* || "$v" == *'|'* ]]; then return 1; fi
  return 0
}

# ─────────────────────────────────────────────
# KONFIGURATION
# Die Datei wird als Daten gelesen und nie ausgeführt:
# jeder Schlüssel muss auf der Whitelist stehen, jeder Wert wird
# vor der Zuweisung geprüft.
# ─────────────────────────────────────────────

CONF_ERRORS=0

conf_error() {
  printf '❌ Config: %s\n' "$1"
  CONF_ERRORS=$(( CONF_ERRORS + 1 ))
}

_conf_unquote() {
  local v="$1"
  if (( ${#v} >= 2 )); then
    if [[ "${v:0:1}" == '"' && "${v: -1}" == '"' ]] \
    || [[ "${v:0:1}" == "'" && "${v: -1}" == "'" ]]; then
      v="${v:1:${#v}-2}"
    fi
  fi
  printf '%s' "$v"
}

_conf_trim() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

_conf_scalar() {
  local key="$1" val="$2"
  case "$key" in
    PAPERLESS_CONTAINER|DB_CONTAINER|DB_NAME|DB_USER)
      if valid_name "$val"; then
        printf -v "$key" '%s' "$val"
      else
        conf_error "${key} enthält ungültige Zeichen: '${val}'"
      fi
      ;;
    COMPOSE_FILE|MEDIA_DIR|DATA_DIR|EXPORT_DIR|BORG_REPO|BACKUP_TMP|EXPORTER_DEST)
      if valid_path "$val"; then
        printf -v "$key" '%s' "$val"
      else
        conf_error "${key} ist kein gültiger absoluter Pfad: '${val}'"
      fi
      ;;
    TELEGRAM_TOKEN)
      if valid_token "$val"; then
        printf -v "$key" '%s' "$val"
      else
        conf_error "TELEGRAM_TOKEN hat nicht das erwartete Format '<id>:<token>'"
      fi
      ;;
    TELEGRAM_CHAT_ID)
      if valid_chatid "$val"; then
        printf -v "$key" '%s' "$val"
      else
        conf_error "TELEGRAM_CHAT_ID ist keine Ganzzahl: '${val}'"
      fi
      ;;
    RCLONE_TRANSFERS|RCLONE_CHECKERS|RCLONE_MAX_DELETE|BACKUP_MIN_FREE_MB)
      if valid_int "$val"; then
        printf -v "$key" '%s' "$val"
      else
        conf_error "${key} ist keine Ganzzahl: '${val}'"
      fi
      ;;
    RCLONE_BWLIMIT)
      if valid_bwlimit "$val"; then
        printf -v "$key" '%s' "$val"
      else
        conf_error "RCLONE_BWLIMIT ungültiges Format: '${val}' (erwartet z.B. 2M, 500K, leer)"
      fi
      ;;
    ENABLE_DOCUMENT_EXPORTER)
      if valid_bool "$val"; then
        printf -v "$key" '%s' "$val"
      else
        conf_error "ENABLE_DOCUMENT_EXPORTER muss true oder false sein: '${val}'"
      fi
      ;;
    *)
      conf_error "unbekannter Schlüssel: '${key}'"
      ;;
  esac
}

_conf_array_elem() {
  local key="$1" val="$2"
  case "$key" in
    BACKUP_TARGETS)
      if valid_target "$val"; then
        BACKUP_TARGETS+=("$val")
      else
        conf_error "BACKUP_TARGETS enthält ungültigen Eintrag: '${val}'"
      fi
      ;;
    BORG_EXCLUDES)
      if valid_exclude "$val"; then
        BORG_EXCLUDES+=("$val")
      else
        conf_error "BORG_EXCLUDES enthält ungültigen Eintrag: '${val}'"
      fi
      ;;
  esac
}

parse_conf() {
  local file="$1"
  local raw line key val current_array=""

  CONF_ERRORS=0

  # Vorbesetzen, damit set -u bei fehlenden Schlüsseln nicht zuschlägt
  PAPERLESS_CONTAINER=""; DB_CONTAINER=""; COMPOSE_FILE=""
  DB_NAME=""; DB_USER=""
  MEDIA_DIR=""; DATA_DIR=""; EXPORT_DIR=""; BORG_REPO=""; BACKUP_TMP=""
  TELEGRAM_TOKEN=""; TELEGRAM_CHAT_ID=""
  RCLONE_BWLIMIT=""; RCLONE_TRANSFERS=""; RCLONE_CHECKERS=""; RCLONE_MAX_DELETE=""; BACKUP_MIN_FREE_MB=""
  ENABLE_DOCUMENT_EXPORTER="false"; EXPORTER_DEST=""
  BACKUP_TARGETS=(); BORG_EXCLUDES=()

  if [[ ! -r "$file" ]]; then
    echo "❌ Konfiguration nicht lesbar: ${file}"
    echo "   Bitte zuerst 'setup' ausführen."
    return 1
  fi

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="$(_conf_trim "${raw//$'\r'/}")"

    if [[ -z "$line" || "$line" == "#"* ]]; then
      continue
    fi

    if [[ -n "$current_array" ]]; then
      if [[ "$line" == ")" ]]; then
        current_array=""
        continue
      fi
      _conf_array_elem "$current_array" "$(_conf_unquote "$line")"
      continue
    fi

    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="$(_conf_trim "${BASH_REMATCH[2]}")"
      if [[ "$val" == "(" ]]; then
        case "$key" in
          BACKUP_TARGETS|BORG_EXCLUDES) current_array="$key" ;;
          *)
            conf_error "unerlaubter Array-Schlüssel: '${key}'"
            current_array="__skip__"
            ;;
        esac
        continue
      fi
      _conf_scalar "$key" "$(_conf_unquote "$val")"
    else
      conf_error "nicht verwertbare Zeile: '${raw}'"
    fi
  done < "$file"

  if [[ "$current_array" == "__skip__" ]]; then
    :
  elif [[ -n "$current_array" ]]; then
    conf_error "Array '${current_array}' wird nicht geschlossen"
  fi

  local required
  for required in \
      PAPERLESS_CONTAINER DB_CONTAINER COMPOSE_FILE \
      DB_NAME DB_USER \
      MEDIA_DIR DATA_DIR EXPORT_DIR BORG_REPO BACKUP_TMP \
      TELEGRAM_TOKEN TELEGRAM_CHAT_ID \
      RCLONE_TRANSFERS RCLONE_CHECKERS; do
    if [[ -z "${!required:-}" ]]; then
      conf_error "${required} fehlt oder ist leer"
    fi
  done

  RCLONE_MAX_DELETE="${RCLONE_MAX_DELETE:-500}"
  if ! valid_int "$RCLONE_MAX_DELETE"; then
    conf_error "RCLONE_MAX_DELETE ist keine Ganzzahl: '${RCLONE_MAX_DELETE}'"
  fi

  BACKUP_MIN_FREE_MB="${BACKUP_MIN_FREE_MB:-4096}"
  if ! valid_int "$BACKUP_MIN_FREE_MB"; then
    conf_error "BACKUP_MIN_FREE_MB ist keine Ganzzahl: '${BACKUP_MIN_FREE_MB}'"
  fi

  if (( ${#BACKUP_TARGETS[@]} == 0 )); then
    conf_error "BACKUP_TARGETS ist leer"
  fi

  if (( CONF_ERRORS > 0 )); then
    echo ""
    echo "❌ ${CONF_ERRORS} Config-Fehler – Script abgebrochen."
    echo "   Bitte ${file} prüfen oder Setup erneut ausführen."
    return 1
  fi
  return 0
}

load_conf() {
  if [[ ! -f "$CONF_FILE" ]]; then
    echo "❌ Keine Konfiguration gefunden unter ${CONF_FILE}"
    echo "   Bitte zuerst 'setup' ausführen."
    exit 1
  fi
  parse_conf "$CONF_FILE" || exit 1
}

# Prüft alle gesammelten Werte mit denselben Mustern wie der Parser,
# bevor die Config geschrieben wird. Andernfalls könnte eine Config
# entstehen, die beim nächsten Lauf abgelehnt wird.
_check_collected_values() {
  local key
  CONF_ERRORS=0
  for key in PAPERLESS_CONTAINER DB_CONTAINER COMPOSE_FILE DB_NAME DB_USER \
             MEDIA_DIR DATA_DIR EXPORT_DIR BORG_REPO BACKUP_TMP \
             TELEGRAM_TOKEN TELEGRAM_CHAT_ID \
             RCLONE_BWLIMIT RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_MAX_DELETE \
             BACKUP_MIN_FREE_MB \
             ENABLE_DOCUMENT_EXPORTER EXPORTER_DEST; do
    _conf_scalar "$key" "${!key}"
  done
  if (( CONF_ERRORS > 0 )); then
    echo ""
    echo "❌ Eingaben können nicht gespeichert werden – Setup bitte erneut ausführen."
    exit 1
  fi
}

# Schreibt einen Schlüssel/Wert-Paar. Werte mit Zeichen, die in der
# Config-Datei etwas bedeuten könnten, werden nie geschrieben.
# Werte nur zeilenweise ausgeben, damit eine Meldung nie über
# mehrere Zeilen läuft.
_conf_show() {
  local v="$1"
  v="${v//$'\n'/\\n}"
  if (( ${#v} > 80 )); then
    v="${v:0:80}…"
  fi
  printf '%s' "$v"
}

_conf_emit() {
  local key="$1" val="$2"
  if ! _conf_embeddable "$val"; then
    printf '❌ Wert für %s enthält unzulässige Zeichen: %s\n' "$key" "$(_conf_show "$val")" >&2
    exit 1
  fi
  printf '%s="%s"\n' "$key" "$val"
}

_conf_emit_item() {
  local val="$1"
  if ! _conf_embeddable "$val"; then
    printf '❌ Listenwert enthält unzulässige Zeichen: %s\n' "$(_conf_show "$val")" >&2
    exit 1
  fi
  printf '  "%s"\n' "$val"
}

write_conf() {
  # Global statt local, damit der Trap auch auf dem Abbruchpfad
  # (ungültiger Wert in _conf_emit) noch etwas Gültiges sieht.
  PABO_CONF_TMP=$(mktemp) || { echo "❌ Konnte Tempfile nicht anlegen"; exit 1; }
  trap 'rm -f "${PABO_CONF_TMP:-}"' EXIT

  {
    printf '# PABO – Paperless-Borg Backup Orchestrator v%s\n' "$PABO_VERSION"
    printf '# Konfiguration erstellt: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '# Diese Datei wird als Daten gelesen, nicht ausgeführt.\n\n'

    _conf_emit PAPERLESS_CONTAINER "${PAPERLESS_CONTAINER}"
    _conf_emit DB_CONTAINER        "${DB_CONTAINER}"
    _conf_emit COMPOSE_FILE        "${COMPOSE_FILE}"
    printf '\n'
    _conf_emit DB_NAME "${DB_NAME}"
    _conf_emit DB_USER "${DB_USER}"
    printf '\n'
    _conf_emit MEDIA_DIR   "${MEDIA_DIR}"
    _conf_emit DATA_DIR    "${DATA_DIR}"
    _conf_emit EXPORT_DIR  "${EXPORT_DIR}"
    _conf_emit BORG_REPO   "${BORG_REPO}"
    _conf_emit BACKUP_TMP  "${BACKUP_TMP}"
    printf '\n'
    _conf_emit TELEGRAM_TOKEN   "${TELEGRAM_TOKEN}"
    _conf_emit TELEGRAM_CHAT_ID "${TELEGRAM_CHAT_ID}"
    printf '\n'

    printf 'BACKUP_TARGETS=(\n'
    local t
    for t in "${BACKUP_TARGETS[@]}"; do
      _conf_emit_item "$t"
    done
    printf ')\n\n'

    _conf_emit RCLONE_BWLIMIT     "${RCLONE_BWLIMIT}"
    _conf_emit RCLONE_TRANSFERS   "${RCLONE_TRANSFERS}"
    _conf_emit RCLONE_CHECKERS    "${RCLONE_CHECKERS}"
    _conf_emit RCLONE_MAX_DELETE  "${RCLONE_MAX_DELETE:-500}"
    _conf_emit BACKUP_MIN_FREE_MB "${BACKUP_MIN_FREE_MB:-4096}"
    printf '\n'

    printf 'BORG_EXCLUDES=(\n'
    local e
    for e in "${BORG_EXCLUDES[@]:-}"; do
      if [[ -n "$e" ]]; then
        _conf_emit_item "$e"
      fi
    done
    printf ')\n\n'

    _conf_emit ENABLE_DOCUMENT_EXPORTER "${ENABLE_DOCUMENT_EXPORTER}"
    _conf_emit EXPORTER_DEST            "${EXPORTER_DEST}"
  } > "$PABO_CONF_TMP"

  install -m 600 "$PABO_CONF_TMP" "$CONF_FILE"
  rm -f "$PABO_CONF_TMP"
  unset PABO_CONF_TMP
  trap - EXIT
}

# Platzprüfung vor dem Restore-Download: das Repo belegt das
# Dateisystem ein zweites Mal.
check_restore_space() {
  local remote="$1" dest="$2"
  local remote_bytes need_kb free_kb
  remote_bytes=$(rclone size --json "$remote" 2>/dev/null | jq -r '.bytes // 0') || remote_bytes=0
  if [[ ! "$remote_bytes" =~ ^[0-9]+$ ]] || (( remote_bytes == 0 )); then
    echo "❌ Remote-Größe nicht ermittelbar – Download abgebrochen, ohne blind zu schreiben."
    exit "$EXIT_RESTORE"
  fi
  need_kb=$(( remote_bytes * 11 / 10 / 1024 ))
  if ! free_kb=$(fs_free_kb "$dest"); then
    echo "❌ Freier Platz nicht ermittelbar – Download abgebrochen, ohne blind zu schreiben."
    exit "$EXIT_RESTORE"
  fi
  if (( free_kb < need_kb )); then
    echo "❌ Nicht genug Platz: $(( free_kb / 1024 )) MB frei unter ${dest}, benötigt werden $(( need_kb / 1024 )) MB."
    send_telegram "❌ Restore abgebrochen
⚠️ Nicht genug Platz für den Download aus ${remote}
🔢 Exit-Code: ${EXIT_RESTORE}"
    exit "$EXIT_RESTORE"
  fi
  return 0
}

# ─────────────────────────────────────────────
# TELEGRAM
# Token liegt in einer 0600-curl-Config, nicht in der Kommandozeile.
# Fehler beim Senden beenden nie ein laufendes Backup.
# ─────────────────────────────────────────────

send_telegram() {
  local message="$1"
  local payload http_code cfg

  payload=$(jq -n \
    --arg cid  "${TELEGRAM_CHAT_ID}" \
    --arg text "$message" \
    '{"chat_id":$cid,"text":$text,"parse_mode":"HTML"}') || {
      log "⚠️  Telegram: Nachricht konnte nicht kodiert werden"
      return 0
    }

  cfg=$(mktemp) || {
    log "⚠️  Telegram: kein Tempfile verfügbar"
    return 0
  }
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "${TELEGRAM_TOKEN}" > "$cfg"

  http_code=$(printf '%s' "$payload" | \
    curl -sS --max-time 10 --connect-timeout 5 \
      --proto '=https' \
      --config "$cfg" \
      -H 'Content-Type: application/json' \
      --data-binary @- -o /dev/null -w '%{http_code}' 2>/dev/null) || http_code="000"
  rm -f "$cfg"

  if [[ "$http_code" != "200" ]]; then
    log "⚠️  Telegram: Meldung nicht gesendet (HTTP ${http_code})"
  fi
  return 0
}

# ─────────────────────────────────────────────
# HILFSFUNKTIONEN
# ─────────────────────────────────────────────

borg_repo_size() {
  local repo="$1"
  borg info --json "$repo" 2>/dev/null | jq -r '
    (.cache.stats.unique_csize // .stats.unique_csize // 0)
    | if   . > 1073741824 then "\(. / 1073741824 * 10 | floor / 10) GB"
      elif . > 1048576    then "\(. / 1048576 | floor) MB"
      else                     "\(. / 1024 | floor) KB"
      end
  ' 2>/dev/null || echo "unbekannt"
}

check_borg_version() {
  local installed
  installed=$(borg --version 2>/dev/null | awk '{print $2}') || installed=""
  if [[ -z "$installed" ]]; then
    log "⚠️  Borg-Version nicht ermittelbar"
    return 0
  fi
  log "ℹ️  Borg ${installed}"
  if [[ "$(printf '%s\n%s\n' "$MIN_BORG_VERSION" "$installed" | sort -V | head -1)" \
        != "$MIN_BORG_VERSION" ]]; then
    log "⚠️  Borg ist älter als ${MIN_BORG_VERSION} – Update empfohlen"
  fi
  return 0
}

# Schutz vor dem Löschen von Cloud-Daten: nur synchronisieren, wenn das
# lokale Repository intakt und gefüllt ist.
repo_sane() {
  if [[ ! -f "${BORG_REPO}/config" ]]; then
    log "❌ Preflight: ${BORG_REPO}/config fehlt – kein gültiges Repository"
    return 1
  fi
  local archives
  archives=$(borg list --short "${BORG_REPO}" 2>/dev/null | wc -l) || archives=0
  if (( archives < 1 )); then
    log "❌ Preflight: Repository enthält keine Archive"
    return 1
  fi
  if [[ -z "$(find "${BORG_REPO}/data" -type f -print -quit 2>/dev/null)" ]]; then
    log "❌ Preflight: Repository enthält keine Datensegmente"
    return 1
  fi
  return 0
}

# Freier Platz im Dateisystem eines Pfades, in KiB.
fs_free_kb() {
  local path="$1" free
  free=$(df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4}') || free=""
  if [[ ! "$free" =~ ^[0-9]+$ ]]; then
    echo ""
    return 1
  fi
  printf '%s' "$free"
  return 0
}

# Bricht mit Warnung ab, wenn der Mindestfreiraum (BACKUP_MIN_FREE_MB)
# unterschritten ist. Der exit_code hängt vom Aufrufer ab: Backup oder Restore.
require_free_space() {
  local path="$1" exit_code="$2" context="$3"
  local free need_mb
  need_mb="${BACKUP_MIN_FREE_MB:-4096}"
  if ! free=$(fs_free_kb "$path"); then
    log "⚠️  Platzprüfung: freier Platz für ${path} nicht ermittelbar – fahre ohne Prüfung fort"
    return 0
  fi
  if (( free < need_mb * 1024 )); then
    log "❌ Platzprüfung: nur $(( free / 1024 )) MB frei unter ${path} (Mindestwert BACKUP_MIN_FREE_MB: ${need_mb} MB) – ${context} abgebrochen"
    send_telegram "❌ ${context} abgebrochen
⚠️ Nur $(( free / 1024 )) MB frei unter ${path} (benötigt: ${need_mb} MB)
ℹ️ Platte aufräumen oder BACKUP_MIN_FREE_MB in /etc/paperless-backup.conf anpassen"
    exit "$exit_code"
  fi
  return 0
}

# ─────────────────────────────────────────────
# BACKUP
# Ein Archiv pro Lauf, danach ein Upload pro Cloud-Ziel.
# ─────────────────────────────────────────────

container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

create_archive() {
  local dry_run="${1:-false}"
  local archive db_dump db_size start
  archive="paperless-$(date +%Y-%m-%d-%H%M%S)"
  db_dump="${BACKUP_TMP}/paperless-db.sql"
  db_size="0"
  start=$(date +%s)

  check_borg_version

  # Dry-Run schreibt nichts – keine Prüfung nötig.
  if [[ "$dry_run" == "false" ]]; then
    require_free_space "${BORG_REPO}" "$EXIT_DB" "Backup"
  fi

  if [[ "${ENABLE_DOCUMENT_EXPORTER}" == "true" && "$dry_run" == "false" ]] \
     && ! container_running "${PAPERLESS_CONTAINER}"; then
    log "❌ Paperless-Container '${PAPERLESS_CONTAINER}' läuft nicht – Backup abgebrochen"
    log "   Namen prüfen mit: docker ps -a --format '{{.Names}}\t{{.Status}}'"
    send_telegram "❌ Backup abgebrochen
🔴 Paperless-Container '${PAPERLESS_CONTAINER}' läuft nicht
ℹ️ PAPERLESS_CONTAINER in /etc/paperless-backup.conf prüfen"
    exit "$EXIT_DB"
  fi

  if [[ "$dry_run" == "false" ]] && ! container_running "${DB_CONTAINER}"; then
    log "❌ Datenbank-Container '${DB_CONTAINER}' läuft nicht – Backup abgebrochen"
    log "   Namen prüfen mit: docker ps -a --format '{{.Names}}\t{{.Status}}'"
    send_telegram "❌ Backup abgebrochen
🔴 Datenbank-Container '${DB_CONTAINER}' läuft nicht
ℹ️ DB_CONTAINER in /etc/paperless-backup.conf prüfen"
    exit "$EXIT_DB"
  fi

  if [[ "${ENABLE_DOCUMENT_EXPORTER}" == "true" && "$dry_run" == "false" ]]; then
    log "[EXPORTER] Starte document_exporter..."
    if docker exec "${PAPERLESS_CONTAINER}" document_exporter "${EXPORTER_DEST}" \
         2>&1 | tee -a "$LOG_FILE"; then
      log "[EXPORTER] ✅ document_exporter erfolgreich"
    else
      log "[EXPORTER] ⚠️  document_exporter fehlgeschlagen – Backup läuft weiter"
      send_telegram "⚠️ document_exporter Warnung
❌ Export fehlgeschlagen – Backup läuft ohne aktuellen Export weiter."
    fi
  fi

  if [[ "$dry_run" == "true" ]]; then
    log "[DB] DRY-RUN: überspringe DB-Dump"
  else
    if [[ ! -d "${BACKUP_TMP}" ]]; then
      mkdir -p "${BACKUP_TMP}"
    fi
    chmod 700 "${BACKUP_TMP}"
    log "[DB] Erstelle PostgreSQL-Dump..."
    if docker exec "${DB_CONTAINER}" pg_dump \
         --clean --if-exists -U "${DB_USER}" "${DB_NAME}" > "${db_dump}" 2>>"${LOG_FILE}"; then
      chmod 600 "${db_dump}"
      db_size=$(du -h "${db_dump}" | cut -f1)
      log "[DB] ✅ Dump OK (${db_size})"
      # Global, damit der Trap auch nach dem Ende von create_archive
      # noch auf einen gültigen Pfad zeigt.
      PABO_DB_DUMP="$db_dump"
      trap 'rm -f "${PABO_DB_DUMP:-}"' EXIT
    else
      log "[DB] ❌ DB-Dump fehlgeschlagen (Exit: ${EXIT_DB})"
      rm -f "${db_dump}"
      send_telegram "❌ Backup fehlgeschlagen
🔴 Fehler: [DB] PostgreSQL-Dump
🔢 Exit-Code: ${EXIT_DB}"
      exit "$EXIT_DB"
    fi
  fi

  local borg_args=(create --stats --compression lz4)
  if [[ "$dry_run" == "true" ]]; then
    borg_args+=(--dry-run)
  fi

  local pattern
  for pattern in "${BORG_EXCLUDES[@]:-}"; do
    if [[ -n "$pattern" ]]; then
      borg_args+=(--exclude "$pattern")
    fi
  done

  borg_args+=("${BORG_REPO}::${archive}")
  borg_args+=("${MEDIA_DIR}" "${DATA_DIR}")
  if [[ "$dry_run" == "false" ]]; then
    borg_args+=("${db_dump}")
  fi
  if [[ -f "${COMPOSE_FILE}" ]]; then
    borg_args+=("${COMPOSE_FILE}")
  else
    log "⚠️  ${COMPOSE_FILE} nicht gefunden – wird nicht mitgesichert"
  fi
  if [[ "${ENABLE_DOCUMENT_EXPORTER}" == "true" && "$dry_run" == "false" ]]; then
    if [[ -d "${EXPORT_DIR}" ]]; then
      borg_args+=("${EXPORT_DIR}")
    else
      log "⚠️  ${EXPORT_DIR} fehlt – Export wird nicht mitgesichert"
    fi
  fi

  log "[BORG] Starte borg create (${archive})..."
  if ! borg "${borg_args[@]}" 2>&1 | tee -a "$LOG_FILE"; then
    log "[BORG] ❌ borg create fehlgeschlagen (Exit: ${EXIT_BORG})"
    send_telegram "❌ Backup fehlgeschlagen
🔴 Fehler: [BORG] borg create
🗄 Archiv: ${archive}
🔢 Exit-Code: ${EXIT_BORG}"
    exit "$EXIT_BORG"
  fi
  log "[BORG] ✅ Archiv ${archive} erstellt"

  if [[ "$dry_run" == "false" ]]; then
    rm -f "${db_dump}"

    log "[BORG] Prune alte Archive..."
    if ! borg prune \
           --glob-archives 'paperless-*' \
           --keep-daily=14 \
           --keep-weekly=8 \
           --keep-monthly=6 \
           "${BORG_REPO}" 2>&1 | tee -a "$LOG_FILE"; then
      log "[BORG] ⚠️  Prune fehlgeschlagen – nicht kritisch"
    fi

    log "[BORG] Compact Repository..."
    if ! borg compact "${BORG_REPO}" 2>&1 | tee -a "$LOG_FILE"; then
      log "[BORG] ⚠️  Compact fehlgeschlagen – nicht kritisch"
      send_telegram "⚠️ Borg Compact Warnung
Compact nach Prune fehlgeschlagen. Backup war erfolgreich."
    fi
  fi

  ARCHIVE_NAME_CREATED="$archive"
  DB_DUMP_SIZE="$db_size"
  BACKUP_START="$start"
  return 0
}

upload_to_target() {
  local target="$1"
  local remote="${target%%:*}"
  local remote_path="${target#*:}"

  log "[RCLONE] Upload → ${target}..."

  if ! repo_sane; then
    log "[RCLONE] ❌ Upload abgebrochen – lokales Repository nicht intakt"
    send_telegram "❌ Upload abgebrochen
☁️ Ziel: ${target}
🔴 Grund: lokales Borg-Repository ist leer oder ungültig
🛡 Schutz: es wurde nichts in der Cloud gelöscht"
    return 1
  fi

  local opts=(--transfers "${RCLONE_TRANSFERS}" --checkers "${RCLONE_CHECKERS}")
  if [[ -n "${RCLONE_BWLIMIT}" ]]; then
    opts+=(--bwlimit "${RCLONE_BWLIMIT}")
  fi
  if (( RCLONE_MAX_DELETE > 0 )); then
    opts+=(--max-delete "${RCLONE_MAX_DELETE}")
  fi

  if rclone sync "${BORG_REPO}" "${remote}:${remote_path}" "${opts[@]}" 2>&1 \
       | tee -a "$LOG_FILE"; then
    log "[RCLONE] ✅ Upload → ${target} abgeschlossen"
    return 0
  fi

  log "[RCLONE] ❌ Upload → ${target} fehlgeschlagen (Exit: ${EXIT_RCLONE})"
  send_telegram "❌ Backup-Upload fehlgeschlagen
🔴 Fehler: [RCLONE] Upload
☁️ Ziel: ${target}
🔢 Exit-Code: ${EXIT_RCLONE}"
  return 1
}

run_backup() {
  local dry_run="${1:-false}"
  ensure_lock_dir

  (
    flock -n 9 || {
      log "⚠️  Backup läuft bereits (Lock aktiv). Abbruch."
      send_telegram "⚠️ Backup übersprungen
🔒 Ein anderer Backup-Prozess läuft bereits."
      exit 0
    }

    check_passphrase
    export BORG_PASSCOMMAND="cat ${PASSPHRASE_FILE}"

    local failed=()
    create_archive "$dry_run"

    if [[ "$dry_run" == "false" ]]; then
      local target
      for target in "${BACKUP_TARGETS[@]}"; do
        if ! upload_to_target "$target"; then
          failed+=("$target")
        fi
      done
    fi

    local end duration count size
    end=$(date +%s)
    duration=$(( end - BACKUP_START ))
    count=$(borg list "${BORG_REPO}" 2>/dev/null | wc -l || echo "?")
    size=$(borg_repo_size "${BORG_REPO}")

    if (( ${#failed[@]} > 0 )); then
      log "=== Backup mit Upload-Fehlern beendet (${duration}s) ==="
      send_telegram "❌ Backup teilweise fehlgeschlagen
🗄 Archiv: ${ARCHIVE_NAME_CREATED}
⚠️ Upload fehlgeschlagen für: ${failed[*]}
💾 Repo-Größe: ${size}
⏱ Dauer: ${duration}s"
      exit "$EXIT_RCLONE"
    fi

    if [[ "$dry_run" == "true" ]]; then
      log "=== DRY-RUN abgeschlossen – keine Änderungen vorgenommen ==="
      exit "$EXIT_OK"
    fi

    send_telegram "✅ Paperless Backup erfolgreich
🗄 Archiv: ${ARCHIVE_NAME_CREATED}
☁️ Ziele: ${#BACKUP_TARGETS[@]}
🗃 DB-Dump: ${DB_DUMP_SIZE}
📦 Archive gesamt: ${count}
💾 Repo-Größe: ${size}
⏱ Dauer: ${duration}s"
    log "=== Backup erfolgreich (${duration}s) ==="

  ) 9>"${LOCK_DIR}/backup.lock"
}

run_upload_only() {
  local target="$1"
  ensure_lock_dir
  check_passphrase
  export BORG_PASSCOMMAND="cat ${PASSPHRASE_FILE}"
  (
    flock -n 9 || {
      log "⚠️  Upload läuft bereits (Lock aktiv). Abbruch."
      exit 0
    }
    upload_to_target "$target" || exit "$EXIT_RCLONE"
  ) 9>"${LOCK_DIR}/upload.lock"
}

# ─────────────────────────────────────────────
# BORG CHECK
# ─────────────────────────────────────────────

run_borg_check() {
  ensure_lock_dir
  (
    flock -n 9 || {
      log "⚠️  Borg Check läuft bereits. Abbruch."
      exit 0
    }

    check_passphrase
    export BORG_PASSCOMMAND="cat ${PASSPHRASE_FILE}"

    log "=== Starte Borg Repository Check ==="
    local start end duration count size
    start=$(date +%s)

    if borg check --verify-data "${BORG_REPO}" 2>&1 | tee -a "$LOG_FILE"; then
      end=$(date +%s)
      duration=$(( end - start ))
      count=$(borg list "${BORG_REPO}" 2>/dev/null | wc -l || echo "?")
      size=$(borg_repo_size "${BORG_REPO}")
      log "✅ Borg Check OK (${duration}s)"
      send_telegram "✅ Borg Repository Check
🔍 Status: OK – keine Fehler
📦 Archive: ${count}
💾 Repo-Größe: ${size}
⏱ Dauer: ${duration}s"
    else
      log "❌ Borg Check fehlgeschlagen!"
      send_telegram "❌ Borg Check FEHLGESCHLAGEN
⚠️ Repository könnte beschädigt sein!
🔢 Exit-Code: ${EXIT_BORG}
📋 Log: cat ${LOG_FILE}"
      exit "$EXIT_BORG"
    fi
  ) 9>"${LOCK_DIR}/borgcheck.lock"
}

# ─────────────────────────────────────────────
# RESTORE DRY-RUN TEST
# ─────────────────────────────────────────────

run_restore_test() {
  ensure_lock_dir
  (
    flock -n 9 || {
      log "⚠️  Restore-Test läuft bereits. Abbruch."
      exit 0
    }

    check_passphrase
    export BORG_PASSCOMMAND="cat ${PASSPHRASE_FILE}"

    install -d -m 700 "${RESTORE_TEST_DIR}"
    local test_dir
    test_dir=$(mktemp -d "${RESTORE_TEST_DIR}/test-XXXXXXXX") || {
      log "❌ Konnte Testverzeichnis nicht anlegen"
      exit 1
    }
    trap 'if [[ -n "${test_dir:-}" && -O "${test_dir}" ]]; then
            log "Räume ${test_dir} auf..."; rm -rf "${test_dir}"; fi' EXIT

    log "=== Starte Restore Dry-Run Test ==="
    local start errors=()
    start=$(date +%s)

    local archive
    archive=$(borg list --short "${BORG_REPO}" 2>/dev/null | tail -1)
    if [[ -z "$archive" ]]; then
      log "❌ Kein Archiv gefunden!"
      send_telegram "❌ Restore-Test FEHLGESCHLAGEN
❌ Kein Borg-Archiv gefunden!
🔢 Exit-Code: ${EXIT_RESTORE_TEST}"
      exit "$EXIT_RESTORE_TEST"
    fi
    log "Teste Archiv: ${archive}"

    local avail need
    avail=$(df -Pk "${RESTORE_TEST_DIR}" 2>/dev/null | awk 'NR==2 {print $4}') || avail=""
    need=$(borg info --json "${BORG_REPO}::${archive}" 2>/dev/null \
             | jq -r '.archives[0].stats.unique_csize // 0') || need=0
    if [[ -n "$avail" && "$need" =~ ^[0-9]+$ ]] && (( need > 0 )) \
       && (( avail * 1024 < need * 12 / 10 )); then
      log "❌ Nicht genug Platz für den Restore-Test (${avail} KiB frei)"
      send_telegram "❌ Restore-Test abgebrochen
⚠️ Nicht genug freier Speicher für den Dry-Run
🔢 Exit-Code: ${EXIT_RESTORE_TEST}"
      exit "$EXIT_RESTORE_TEST"
    fi

    (
      cd "$test_dir" || exit 1
      borg extract "${BORG_REPO}::${archive}" 2>&1 | tee -a "$LOG_FILE"
    ) || errors+=("Borg-Extraktion fehlgeschlagen")

    local extracted_media="${test_dir}/${MEDIA_DIR#/}"
    local extracted_data="${test_dir}/${DATA_DIR#/}"
    local extracted_compose="${test_dir}/${COMPOSE_FILE#/}"
    local extracted_db="${test_dir}/${BACKUP_TMP#/}/paperless-db.sql"
    local media_count=0

    if [[ -d "$extracted_media" ]]; then
      media_count=$(find "$extracted_media" -type f | wc -l)
      log "✅ Media OK (${media_count} Dateien)"
    else
      errors+=("Media-Verzeichnis fehlt"); log "❌ Media fehlt!"
    fi

    if [[ -d "$extracted_data" ]]; then
      log "✅ Data-Verzeichnis OK"
    else
      errors+=("Data-Verzeichnis fehlt"); log "❌ Data fehlt!"
    fi

    if [[ -f "$extracted_compose" ]]; then
      log "✅ docker-compose.yml vorhanden"
    else
      errors+=("docker-compose.yml fehlt"); log "❌ docker-compose.yml fehlt!"
    fi

    if [[ -f "$extracted_db" ]]; then
      if head -5 "$extracted_db" | grep -q "PostgreSQL\|pg_dump"; then
        log "✅ PostgreSQL-Dump OK ($(du -sh "$extracted_db" | cut -f1))"
      else
        errors+=("PostgreSQL-Dump Header ungültig"); log "❌ DB-Dump Header ungültig!"
      fi
    else
      errors+=("PostgreSQL-Dump fehlt (${extracted_db})"); log "❌ DB-Dump fehlt!"
    fi

    local end duration
    end=$(date +%s)
    duration=$(( end - start ))

    if (( ${#errors[@]} == 0 )); then
      log "✅ Restore-Test erfolgreich (${duration}s)"
      send_telegram "✅ Restore Dry-Run Test erfolgreich
🗄 Archiv: ${archive}
📂 Media: ${media_count} Dateien ✅
📁 Data-Verzeichnis: ✅
📄 docker-compose.yml: ✅
🗃 PostgreSQL-Dump: ✅
⏱ Dauer: ${duration}s
💡 Ein echter Restore wäre möglich."
    else
      local error_list
      error_list=$(printf '❌ %s\n' "${errors[@]}")
      log "❌ ${#errors[@]} Fehler gefunden!"
      send_telegram "❌ Restore-Test FEHLGESCHLAGEN
🗄 Archiv: ${archive}
⚠️ ${#errors[@]} Fehler:
${error_list}
🔢 Exit-Code: ${EXIT_RESTORE_TEST}
📋 Log: cat ${LOG_FILE}"
      exit "$EXIT_RESTORE_TEST"
    fi
  ) 9>"${LOCK_DIR}/restore-test.lock"
}

# <<< PABO COMMON END

# ═════════════════════════════════════════════
# INTERAKTIVE TEILE (nur in pabo.sh)
# ═════════════════════════════════════════════

detect_value() {
  local label="$1" detected="$2" varname="$3"
  local input value
  # Docker-Ausgaben können mehrere Trefferzeilen enthalten (z.B. doppelte
  # Mounts) – nur die erste Zeile übernehmen, sonst landet ein Umbruch im Wert.
  detected="${detected%%$'\n'*}"
  detected="$(_conf_trim "$detected")"
  echo ""
  echo "🔍 Erkannt: ${label} = ${detected}"
  while true; do
    read -rp "   Korrekt? (Enter = ja, sonst neuen Wert eingeben): " input || exit 1
    value="${input:-$detected}"
    if [[ -z "$value" ]]; then
      echo "   ⚠️  Der erkannte Wert ist leer – bitte hier einen Wert eingeben."
      continue
    fi
    if _conf_embeddable "$value"; then
      printf -v "$varname" '%s' "$value"
      return
    fi
    echo "   ❌ Der Wert enthält Zeichen, die nicht gespeichert werden können (Zeilenumbruch, Anführungszeichen oder \\$)"
  done
}

prompt_int() {
  local prompt="$1" min="$2" max="$3" varname="$4"
  local val
  while true; do
    read -rp "$prompt" val || { echo "❌ EOF – Abbruch"; exit 1; }
    if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= min )) && (( val <= max )); then
      printf -v "$varname" '%s' "$val"
      return
    fi
    echo "   ❌ Ungültig – bitte Zahl zwischen ${min} und ${max} eingeben"
  done
}

# ─────────────────────────────────────────────
# H1-Fix: Alte Scripts und Timer sauber entfernen
# ─────────────────────────────────────────────

cleanup_old_scripts() {
  echo ""
  echo "🧹 Räume alte Scripts und Timer auf..."

  local timer tname
  for timer in \
      /etc/systemd/system/paperless-backup.timer \
      /etc/systemd/system/paperless-backup-*.timer \
      /etc/systemd/system/paperless-borg-check.timer \
      /etc/systemd/system/paperless-restore-test.timer; do
    [[ -f "$timer" ]] || continue
    tname=$(basename "$timer")
    systemctl stop    "$tname" 2>/dev/null || true
    systemctl disable "$tname" 2>/dev/null || true
    echo "   🛑 Timer gestoppt: ${tname}"
  done

  local script
  for script in "${SCRIPT_DIR}"/paperless-backup.sh \
                "${SCRIPT_DIR}"/paperless-backup-*.sh \
                "${SCRIPT_DIR}"/paperless-borg-check.sh \
                "${SCRIPT_DIR}"/paperless-restore-test.sh; do
    [[ -f "$script" ]] || continue
    rm -f "$script"
    echo "   🗑 Script gelöscht: ${script}"
  done

  local unit
  for unit in \
      /etc/systemd/system/paperless-backup.service \
      /etc/systemd/system/paperless-backup.timer \
      /etc/systemd/system/paperless-backup-*.service \
      /etc/systemd/system/paperless-backup-*.timer \
      /etc/systemd/system/paperless-borg-check.service \
      /etc/systemd/system/paperless-borg-check.timer \
      /etc/systemd/system/paperless-restore-test.service \
      /etc/systemd/system/paperless-restore-test.timer; do
    [[ -f "$unit" ]] || continue
    rm -f "$unit"
    echo "   🗑 Unit gelöscht: ${unit}"
  done

  systemctl daemon-reload
  echo "   ✅ Aufräumen abgeschlossen"
}

# ─────────────────────────────────────────────
# SETUP
# ─────────────────────────────────────────────

run_setup() {
  require_root

  local SETUP_MODE=0
  _SETUP_VARS_LOADED=1

  if [[ -f "$CONF_FILE" ]]; then
    echo ""
    echo "⚠️  Bestehende Konfiguration gefunden: ${CONF_FILE}"
    echo ""
    echo "Was möchtest du tun?"
    echo "  1) Ziele ändern (Config teilweise neu einrichten)"
    echo "  2) Scripts und Timer neu generieren (Config unverändert)"
    echo "  3) Abbrechen"
    local mode_choice
    prompt_int "Auswahl (1-3): " 1 3 mode_choice
    case "$mode_choice" in
      1) SETUP_MODE=1 ;;
      2) SETUP_MODE=2 ;;
      3) echo "Abgebrochen."; exit 0 ;;
    esac
    load_conf
    echo ""
    echo "   Aktuell konfigurierte Ziele:"
    local t
    for t in "${BACKUP_TARGETS[@]}"; do
      echo "   • ${t}"
    done
    echo ""
    echo "🔒 Borg-Repository und Passphrase werden nicht verändert."
  fi

  echo "╔══════════════════════════════════════╗"
  echo "║     Paperless Backup Setup           ║"
  echo "╚══════════════════════════════════════╝"

  if [[ $SETUP_MODE -eq 2 ]]; then
    cleanup_old_scripts
    generate_scripts
    setup_systemd
    echo ""
    echo "✅ Scripts und Timer erfolgreich neu generiert."
    return
  fi

  echo ""
  echo "📦 Installiere Abhängigkeiten..."
  apt-get update -qq
  apt-get install -y -qq borgbackup curl rclone postgresql-client jq

  echo ""
  echo "☁️  Prüfe rclone Remotes..."
  AVAILABLE_REMOTES=$(rclone listremotes 2>/dev/null || true)

  if [[ -z "$AVAILABLE_REMOTES" ]]; then
    echo ""
    echo "⚠️  Keine rclone Remotes gefunden!"
    read -rp "   Jetzt 'rclone config' starten? (j/n): " do_rclone
    if [[ "$do_rclone" == "j" ]]; then
      rclone config
      AVAILABLE_REMOTES=$(rclone listremotes 2>/dev/null || true)
      if [[ -z "$AVAILABLE_REMOTES" ]]; then
        echo "❌ Weiterhin keine Remotes gefunden. Setup abgebrochen."
        exit 1
      fi
    else
      echo "❌ Kein Remote konfiguriert. Setup abgebrochen."
      exit 1
    fi
  fi

  echo ""
  echo "Gefundene Remotes:"
  mapfile -t REMOTE_LIST <<< "$AVAILABLE_REMOTES"
  local i
  for i in "${!REMOTE_LIST[@]}"; do
    echo "  $((i+1))) ${REMOTE_LIST[$i]}"
  done

  local TARGET_COUNT
  prompt_int "Wie viele Cloud-Ziele möchtest du nutzen? (1-${#REMOTE_LIST[@]}): " \
    1 "${#REMOTE_LIST[@]}" TARGET_COUNT

  BACKUP_TARGETS=()
  local remote_idx SELECTED_REMOTE REMOTE_CLEAN remote_path
  for ((t=1; t<=TARGET_COUNT; t++)); do
    echo ""
    echo "── Ziel ${t} ──────────────────────────────"
    for i in "${!REMOTE_LIST[@]}"; do
      echo "  $((i+1))) ${REMOTE_LIST[$i]}"
    done
    prompt_int "Remote auswählen (1-${#REMOTE_LIST[@]}): " \
      1 "${#REMOTE_LIST[@]}" remote_idx
    SELECTED_REMOTE="${REMOTE_LIST[$((remote_idx-1))]}"
    REMOTE_CLEAN="${SELECTED_REMOTE%:}"
    local remote_path
    while true; do
      read -rp "Ziel-Pfad auf ${SELECTED_REMOTE} (z.B. /Paperless-Borg-Encrypted): " remote_path
      if [[ -n "$remote_path" ]] && _conf_embeddable "$remote_path" \
         && valid_target "${REMOTE_CLEAN}:${remote_path}"; then
        break
      fi
      echo "   ❌ Bitte einen Pfad ohne Sonderzeichen angeben (z.B. /Paperless-Borg-Encrypted)"
    done
    BACKUP_TARGETS+=("${REMOTE_CLEAN}:${remote_path}")
    echo "   ✅ Ziel ${t}: ${REMOTE_CLEAN}:${remote_path}"
  done

  if [[ $SETUP_MODE -eq 1 ]]; then
    echo ""
    echo "💾 Aktualisiere ${CONF_FILE}..."
    _check_collected_values
    write_conf
    echo "   ✅ Konfiguration gespeichert (chmod 600)"
    cleanup_old_scripts
    generate_scripts
    setup_systemd
    echo ""
    echo "✅ Ziele erfolgreich geändert."
    send_telegram "✅ Paperless Backup – Ziele geändert
📦 Neue Ziele: $(IFS=', '; echo "${BACKUP_TARGETS[*]}")
🖥 Host: $(hostname)
📅 $(date '+%Y-%m-%d %H:%M')"
    return
  fi

  echo ""
  echo "🐳 Erkenne Docker-Container..."
  DETECTED_PAPERLESS=$(docker ps --format '{{.Names}}' | grep -i paperless | grep -v db | grep -v redis | head -1 || true)
  DETECTED_DB=$(docker ps --format '{{.Names}}' | grep -iE "paperless.*(db|postgres)|postgres" | head -1 || true)

  detect_value "Paperless Container" "${DETECTED_PAPERLESS:-paperless-webserver}" PAPERLESS_CONTAINER
  detect_value "PostgreSQL Container" "${DETECTED_DB:-paperless-db}" DB_CONTAINER

  DETECTED_COMPOSE=$(docker inspect "$PAPERLESS_CONTAINER" \
    --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' 2>/dev/null || true)
  [[ -z "$DETECTED_COMPOSE" ]] && DETECTED_COMPOSE="/home/paperless/docker-compose.yml"
  detect_value "docker-compose.yml Pfad" "$DETECTED_COMPOSE" COMPOSE_FILE

  DETECTED_DB_NAME=$(grep -E 'POSTGRES_DB|DB_NAME' "$COMPOSE_FILE" 2>/dev/null \
    | grep -oP '(?<==)[^\s"]+' | head -1) || DETECTED_DB_NAME=""
  DETECTED_DB_USER=$(grep -E 'POSTGRES_USER|DB_USER' "$COMPOSE_FILE" 2>/dev/null \
    | grep -oP '(?<==)[^\s"]+' | head -1) || DETECTED_DB_USER=""
  if [[ -z "$DETECTED_DB_NAME" ]]; then
    echo "   ℹ️  Kein POSTGRES_DB gefunden – Standard wird vorgeschlagen"
    DETECTED_DB_NAME="paperless"
  fi
  if [[ -z "$DETECTED_DB_USER" ]]; then
    echo "   ℹ️  Kein POSTGRES_USER gefunden – Standard wird vorgeschlagen"
    DETECTED_DB_USER="paperless"
  fi
  detect_value "Datenbank Name" "$DETECTED_DB_NAME" DB_NAME
  detect_value "Datenbank User" "$DETECTED_DB_USER" DB_USER

  echo ""
  echo "📂 Erkenne gemountete Pfade..."
  # docker inspect meldet Exit 0 mit leerer Ausgabe, wenn der Mount fehlt –
  # deshalb hier auf Leer prüfen statt auf Exit-Code.
  DETECTED_MEDIA=$(docker inspect "$PAPERLESS_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/usr/src/paperless/media"}}{{.Source}}{{end}}{{end}}' \
    2>/dev/null) || DETECTED_MEDIA=""
  DETECTED_DATA=$(docker inspect "$PAPERLESS_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/usr/src/paperless/data"}}{{.Source}}{{end}}{{end}}' \
    2>/dev/null) || DETECTED_DATA=""
  DETECTED_EXPORT=$(docker inspect "$PAPERLESS_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/usr/src/paperless/export"}}{{.Source}}{{end}}{{end}}' \
    2>/dev/null) || DETECTED_EXPORT=""

  if [[ -z "$DETECTED_MEDIA" ]]; then
    echo "   ⚠️  Kein Mount für /usr/src/paperless/media gefunden – Standard wird vorgeschlagen"
    DETECTED_MEDIA="/data/paperless/media"
  fi
  if [[ -z "$DETECTED_DATA" ]]; then
    echo "   ⚠️  Kein Mount für /usr/src/paperless/data gefunden – Standard wird vorgeschlagen"
    DETECTED_DATA="/data/paperless/data"
  fi
  if [[ -z "$DETECTED_EXPORT" ]]; then
    echo "   ℹ️  Kein Mount für /usr/src/paperless/export gefunden – Standard wird vorgeschlagen"
    DETECTED_EXPORT="/data/paperless/export"
  fi

  detect_value "Media-Pfad"   "$DETECTED_MEDIA"  MEDIA_DIR
  detect_value "Data-Pfad"    "$DETECTED_DATA"   DATA_DIR
  detect_value "Export-Pfad"  "$DETECTED_EXPORT" EXPORT_DIR
  detect_value "Borg Repository Pfad" "/backup/paperless-borg" BORG_REPO
  detect_value "Temporäres Backup-Verzeichnis" "/backup/paperless-tmp" BACKUP_TMP

  MEDIA_FS=$(df --output=source "$MEDIA_DIR" 2>/dev/null | tail -1 || echo "")
  BORG_PARENT=$(dirname "$BORG_REPO")
  mkdir -p "$BORG_PARENT"
  BORG_FS=$(df --output=source "$BORG_PARENT" 2>/dev/null | tail -1 || echo "")
  if [[ -n "$MEDIA_FS" && -n "$BORG_FS" && "$MEDIA_FS" == "$BORG_FS" ]]; then
    echo ""
    echo "┌──────────────────────────────────────────────────┐"
    echo "│  ⚠️  WARNUNG: BORG_REPO liegt auf demselben       │"
    echo "│  Filesystem wie deine Paperless-Daten!           │"
    echo "│  • Kein Schutz bei Disk-Full                     │"
    echo "│  • Kein Schutz bei Disk-Failure                  │"
    echo "│  Empfehlung: BORG_REPO auf separates Laufwerk    │"
    echo "└──────────────────────────────────────────────────┘"
    read -rp "   Trotzdem fortfahren? (j/n): " fs_warn_ok
    [[ "$fs_warn_ok" != "j" ]] && { echo "Setup abgebrochen."; exit 0; }
  fi

  echo ""
  echo "📱 Telegram-Konfiguration"
  while true; do
    read -rsp "   Bot Token: " TELEGRAM_TOKEN
    echo ""
    if valid_token "$TELEGRAM_TOKEN"; then
      break
    fi
    echo "   ❌ Format ungültig – erwartet wird '<id>:<token>' (z.B. 123456789:AA...)"
  done
  while true; do
    read -rp "   Chat ID:   " TELEGRAM_CHAT_ID
    if valid_chatid "$TELEGRAM_CHAT_ID"; then
      break
    fi
    echo "   ❌ Ungültig – bitte eine Ganzzahl eingeben"
  done

  echo ""
  echo "☁️  rclone Upload-Optionen"
  while true; do
    read -rp "   Bandbreitenlimit (leer = kein Limit, z.B. 2M): " RCLONE_BWLIMIT
    if valid_bwlimit "$RCLONE_BWLIMIT"; then
      break
    fi
    echo "   ❌ Ungültiges Format (z.B. 2M, 500K oder leer)"
  done
  while true; do
    read -rp "   Parallele Transfers [4]: " RCLONE_TRANSFERS
    RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-4}"
    if valid_int "$RCLONE_TRANSFERS"; then
      break
    fi
    echo "   ❌ Bitte eine Ganzzahl eingeben"
  done
  while true; do
    read -rp "   Checker [8]: " RCLONE_CHECKERS
    RCLONE_CHECKERS="${RCLONE_CHECKERS:-8}"
    if valid_int "$RCLONE_CHECKERS"; then
      break
    fi
    echo "   ❌ Bitte eine Ganzzahl eingeben"
  done
  while true; do
    read -rp "   Max. Löschungen pro Sync [500]: " RCLONE_MAX_DELETE
    RCLONE_MAX_DELETE="${RCLONE_MAX_DELETE:-500}"
    if valid_int "$RCLONE_MAX_DELETE"; then
      break
    fi
    echo "   ❌ Bitte eine Ganzzahl eingeben (0 = unbegrenzt)"
  done
  while true; do
    read -rp "   Mindestfreiraum vor Backup in MB [4096]: " BACKUP_MIN_FREE_MB
    BACKUP_MIN_FREE_MB="${BACKUP_MIN_FREE_MB:-4096}"
    if valid_int "$BACKUP_MIN_FREE_MB"; then
      break
    fi
    echo "   ❌ Bitte eine Ganzzahl eingeben"
  done

  echo ""
  echo "📂 Borg Exclude-Liste konfigurieren"
  BORG_EXCLUDES=()

  read -rp "   Log-Verzeichnis (${DATA_DIR}/log) ausschließen? (j/n) [j]: " excl_log
  [[ "${excl_log:-j}" == "j" ]] && BORG_EXCLUDES+=("${DATA_DIR}/log")
  BORG_EXCLUDES+=("${DATA_DIR}/celerybeat-schedule.db")

  if [[ -d "${DATA_DIR}/nltk" ]]; then
    read -rp "   NLTK-Daten (${DATA_DIR}/nltk) ausschließen? (j/n) [j]: " excl_nltk
    [[ "${excl_nltk:-j}" == "j" ]] && BORG_EXCLUDES+=("${DATA_DIR}/nltk")
  fi

  read -rp "   Export-Verzeichnis (${EXPORT_DIR}) ausschließen? (j/n) [n]: " excl_export
  [[ "${excl_export:-n}" == "j" ]] && BORG_EXCLUDES+=("${EXPORT_DIR}")

  BORG_EXCLUDES+=("*.tmp" "*.swp" "*.lock")

  read -rp "   Weitere Pfade/Muster hinzufügen? (j/n): " add_more
  while [[ "$add_more" == "j" ]]; do
    read -rp "   Pfad oder Muster: " custom_excl
    if valid_exclude "$custom_excl"; then
      BORG_EXCLUDES+=("$custom_excl")
    else
      echo "   ❌ Ungültiges Muster – wird übersprungen"
    fi
    read -rp "   Noch einen? (j/n): " add_more
  done

  echo ""
  echo "📄 Document-Exporter"
  read -rp "   Aktivieren? (j/n) [n]: " enable_exporter
  ENABLE_DOCUMENT_EXPORTER="false"
  EXPORTER_DEST="/usr/src/paperless/export"
  if [[ "${enable_exporter:-n}" == "j" ]]; then
    ENABLE_DOCUMENT_EXPORTER="true"
    while true; do
      detect_value "Export-Zielverzeichnis im Container" "/usr/src/paperless/export" EXPORTER_DEST
      if valid_path "$EXPORTER_DEST"; then
        break
      fi
      echo "   ❌ Bitte einen absoluten Pfad ohne Leerzeichen angeben"
    done
  fi

  echo ""
  echo "💾 Speichere Konfiguration nach ${CONF_FILE}..."
  _check_collected_values
  write_conf
  echo "   ✅ Konfiguration gespeichert (chmod 600)"

  install -d -m 700 "$BORG_REPO"
  install -d -m 700 "$BACKUP_TMP"
  install -d -m 700 "$RESTORE_TEST_DIR"

  echo ""
  echo "🔐 Borg Repository..."
  if [[ -f "${BORG_REPO}/config" ]]; then
    echo "   ℹ️  Bestehendes Repository erkannt – Passphrase wird beibehalten."
    check_passphrase
  else
    local passphrase
    passphrase=$(openssl rand -base64 32)
    if [[ -f "$PASSPHRASE_FILE" ]]; then
      local pass_backup
      pass_backup="${PASSPHRASE_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
      cp -a "$PASSPHRASE_FILE" "$pass_backup"
      echo "   ℹ️  Vorhandene Passphrase gesichert nach ${pass_backup}"
    fi
    install -m 600 /dev/null "$PASSPHRASE_FILE"
    printf '%s\n' "$passphrase" > "$PASSPHRASE_FILE"
    export BORG_PASSCOMMAND="cat ${PASSPHRASE_FILE}"
    borg init --encryption=repokey "$BORG_REPO"
    echo "   ✅ Repository initialisiert"

    echo ""
    echo "┌─────────────────────────────────────────┐"
    echo "│  ⚠️  BORG PASSPHRASE – SICHER AUFBEWAHREN │"
    echo "├─────────────────────────────────────────┤"
    echo "│  ${passphrase}"
    echo "│  Gespeichert: ${PASSPHRASE_FILE}"
    echo "│  → extern sichern! (Single Point of     │"
    echo "│    Failure bei Verlust)                 │"
    echo "└─────────────────────────────────────────┘"
    read -rp "Passphrase notiert und extern gesichert? (Enter)"
    unset passphrase
  fi

  send_telegram "✅ Paperless Backup Setup abgeschlossen
📦 Ziele: $(IFS=', '; echo "${BACKUP_TARGETS[*]}")
🖥 Host: $(hostname)
📅 $(date '+%Y-%m-%d %H:%M')"

  generate_scripts
  setup_systemd

  echo ""
  echo "✅ Setup erfolgreich abgeschlossen!"
  read -rp "Jetzt einen Test-Backup starten? (j/n): " do_test
  [[ "$do_test" == "j" ]] && run_test
}

# ─────────────────────────────────────────────
# SCRIPTS GENERIEREN
# ─────────────────────────────────────────────

generate_lib() {
  local self="${BASH_SOURCE[0]}"
  if command -v readlink >/dev/null 2>&1; then
    self="$(readlink -f "$self" 2>/dev/null || printf '%s' "$self")"
  fi

  if ! grep -q '^# >>> PABO COMMON BEGIN' "$self" 2>/dev/null; then
    echo "❌ Gemeinsamer Code-Block in ${self} nicht gefunden – Script beschädigt?"
    exit 1
  fi

  local tmp
  tmp=$(mktemp) || { echo "❌ Konnte Tempfile nicht anlegen"; exit 1; }

  {
    printf '#!/bin/bash\n'
    printf '# Automatisch generiert von pabo.sh v%s – nicht manuell bearbeiten.\n' "$PABO_VERSION"
    printf 'set -euo pipefail\numask 077\n\n'
    sed -n '/^# >>> PABO COMMON BEGIN/,/^# <<< PABO COMMON END/p' "$self" \
      | grep -vE '^# (>>>|<<<) PABO COMMON (BEGIN|END)$'
  } > "$tmp"

  install -m 644 "$tmp" "$LIB_FILE"
  rm -f "$tmp"
  echo "   ✅ ${LIB_FILE}"
}

write_script() {
  local name="$1" log_line="$2" entry="$3"
  local path="${SCRIPT_DIR}/${name}"
  cat > "$path" <<EOF
#!/bin/bash
set -euo pipefail
source ${LIB_FILE}
${log_line}
load_conf
require_root
${entry}
EOF
  chmod 755 "$path"
  echo "   ✅ ${path}"
}

generate_scripts() {
  if [[ "${_SETUP_VARS_LOADED:-0}" -ne 1 ]]; then
    load_conf
  fi

  echo ""
  echo "📝 Generiere Backup-Scripts..."
  install -d -m 755 /usr/local/lib

  generate_lib

  write_script "paperless-backup.sh" \
    "LOG_FILE=\"/var/log/paperless-backup.log\"" \
    "run_backup false"

  write_script "paperless-borg-check.sh" \
    "LOG_FILE=\"/var/log/paperless-borg-check.log\"" \
    "run_borg_check"

  write_script "paperless-restore-test.sh" \
    "LOG_FILE=\"/var/log/paperless-restore-test.log\"" \
    "run_restore_test"
}

# ─────────────────────────────────────────────
# SYSTEMD EINRICHTEN
# ─────────────────────────────────────────────

setup_systemd() {
  if [[ "${_SETUP_VARS_LOADED:-0}" -ne 1 ]]; then
    load_conf
  fi
  echo ""
  echo "⚙️  Richte Systemd Services und Timer ein..."

  create_service_timer() {
    local NAME="$1" SCRIPT="$2" DESCRIPTION="$3" SCHEDULE="$4"

    cat > "/etc/systemd/system/${NAME}.service" <<EOF
[Unit]
Description=${DESCRIPTION}
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${SCRIPT}
TimeoutStartSec=infinity
TimeoutStopSec=300
UMask=0077
PrivateTmp=true
ProtectSystem=full
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal
EOF
    chmod 644 "/etc/systemd/system/${NAME}.service"

    cat > "/etc/systemd/system/${NAME}.timer" <<EOF
[Unit]
Description=Timer für ${DESCRIPTION}

[Timer]
OnCalendar=${SCHEDULE}
Persistent=true
RandomizedDelaySec=900
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
    chmod 644 "/etc/systemd/system/${NAME}.timer"
  }

  create_service_timer "paperless-backup" \
    "${SCRIPT_DIR}/paperless-backup.sh" \
    "Tägliches Paperless Backup" \
    "*-*-* 02:00:00"
  echo "   ✅ paperless-backup.timer (täglich 02:00)"

  create_service_timer "paperless-borg-check" \
    "${SCRIPT_DIR}/paperless-borg-check.sh" \
    "Wöchentlicher Borg Repository Check" \
    "Sun *-*-* 03:00:00"
  echo "   ✅ paperless-borg-check.timer (Sonntag 03:00)"

  create_service_timer "paperless-restore-test" \
    "${SCRIPT_DIR}/paperless-restore-test.sh" \
    "Wöchentlicher Restore Dry-Run Test" \
    "Sun *-*-* 04:00:00"
  echo "   ✅ paperless-restore-test.timer (Sonntag 04:00)"

  systemctl daemon-reload
  local unit
  for unit in paperless-backup.timer paperless-borg-check.timer paperless-restore-test.timer; do
    systemctl enable --now "$unit"
  done
  echo "   ✅ Alle Timer aktiviert"
}

# ─────────────────────────────────────────────
# RESTORE
# ─────────────────────────────────────────────

run_restore() {
  require_root
  load_conf
  check_passphrase
  export BORG_PASSCOMMAND="cat ${PASSPHRASE_FILE}"

  echo "╔══════════════════════════════════════╗"
  echo "║     Paperless Restore                ║"
  echo "╚══════════════════════════════════════╝"
  echo ""
  echo "☁️  Von welchem Cloud-Ziel wiederherstellen?"
  local i
  for i in "${!BACKUP_TARGETS[@]}"; do
    echo "  $((i+1))) ${BACKUP_TARGETS[$i]}"
  done
  local target_idx
  prompt_int "Auswahl: " 1 "${#BACKUP_TARGETS[@]}" target_idx
  local SELECTED_TARGET="${BACKUP_TARGETS[$((target_idx-1))]}"
  local REMOTE_NAME="${SELECTED_TARGET%%:*}"
  local REMOTE_PATH="${SELECTED_TARGET#*:}"

  echo ""
  echo "📥 Lade Borg-Repository von ${SELECTED_TARGET} nach ${RESTORE_REPO}..."
  install -d -m 700 "$RESTORE_REPO"

  # Platzprüfung: das Repo belegt das Dateisystem ein zweites Mal.
  local remote_bytes need_kb free_kb
  remote_bytes=$(rclone size --json "${REMOTE_NAME}:${REMOTE_PATH}" 2>/dev/null \
                   | jq -r '.bytes // 0') || remote_bytes=0
  if [[ ! "$remote_bytes" =~ ^[0-9]+$ ]] || (( remote_bytes == 0 )); then
    echo "❌ Remote-Größe nicht ermittelbar – Download abgebrochen, ohne blind zu schreiben."
    exit "$EXIT_RESTORE"
  fi
  need_kb=$(( remote_bytes * 11 / 10 / 1024 ))
  if ! free_kb=$(fs_free_kb "$RESTORE_REPO"); then
    echo "❌ Freier Platz nicht ermittelbar – Download abgebrochen, ohne blind zu schreiben."
    exit "$EXIT_RESTORE"
  fi
  if (( free_kb < need_kb )); then
    echo "❌ Nicht genug Platz: $(( free_kb / 1024 )) MB frei unter ${RESTORE_REPO}, benötigt werden $(( need_kb / 1024 )) MB."
    send_telegram "❌ Restore abgebrochen
⚠️ Nicht genug Platz für den Download aus ${SELECTED_TARGET}
🔢 Exit-Code: ${EXIT_RESTORE}"
    exit "$EXIT_RESTORE"
  fi
  local rclone_opts=(
    --transfers "${RCLONE_TRANSFERS}"
    --checkers  "${RCLONE_CHECKERS}"
  )
  if [[ -n "${RCLONE_BWLIMIT}" ]]; then
    rclone_opts+=(--bwlimit "${RCLONE_BWLIMIT}")
  fi
  if ! rclone copy "${REMOTE_NAME}:${REMOTE_PATH}" "${RESTORE_REPO}" "${rclone_opts[@]}"; then
    echo "❌ Download von ${SELECTED_TARGET} fehlgeschlagen."
    exit "$EXIT_RESTORE"
  fi

  echo ""
  echo "🔍 Prüfe heruntergeladenes Repository..."
  if ! borg check "${RESTORE_REPO}" 2>&1 | tail -20; then
    echo "⚠️  Das heruntergeladene Repository meldet Auffälligkeiten."
    read -rp "   Trotzdem fortfahren? (ja/nein): " check_ok
    [[ "$check_ok" != "ja" ]] && { echo "Abgebrochen."; exit 0; }
  fi

  echo ""
  echo "📋 Verfügbare Archive:"
  local archives=()
  mapfile -t archives < <(borg list --short "${RESTORE_REPO}" 2>/dev/null || true)
  if (( ${#archives[@]} == 0 )); then
    echo "❌ Keine Archive in ${RESTORE_REPO} gefunden."
    exit "$EXIT_RESTORE"
  fi
  for i in "${!archives[@]}"; do
    echo "  $((i+1))) ${archives[$i]}"
  done
  echo ""
  read -rp "Archiv-Name eingeben: " ARCHIVE_NAME
  local known=0 a
  for a in "${archives[@]}"; do
    [[ "$a" == "$ARCHIVE_NAME" ]] && known=1
  done
  if (( known == 0 )); then
    echo "❌ Archiv '${ARCHIVE_NAME}' existiert nicht."
    exit "$EXIT_RESTORE"
  fi

  echo ""
  echo "🔧 Restore-Typ wählen:"
  echo "  1) Voll-Restore (Media + Data + compose + DB)"
  echo "  2) Nur Datenbank"
  echo "  3) Nur Media-Verzeichnis"
  echo "  4) Nur Data-Verzeichnis"
  echo "  5) Restore in alternatives Zielverzeichnis (z.B. Staging)"
  local restore_type
  prompt_int "Auswahl (1-5): " 1 5 restore_type

  local TARGET_PREFIX="/"
  if [[ "$restore_type" == "5" ]]; then
    while true; do
      read -rp "Ziel-Basisverzeichnis (z.B. /tmp/paperless-staging): " TARGET_PREFIX
      if valid_path "$TARGET_PREFIX"; then
        break
      fi
      echo "   ❌ Bitte absoluten Pfad ohne Leerzeichen angeben"
    done
    install -d -m 700 "$TARGET_PREFIX" || {
      echo "❌ Konnte Zielverzeichnis nicht erstellen: ${TARGET_PREFIX}"
      exit 1
    }
    restore_type="1"
    echo "   Restore nach: ${TARGET_PREFIX}"
  fi

  echo ""
  echo "⚠️  ACHTUNG: Daten werden nach ${TARGET_PREFIX} wiederhergestellt!"
  if [[ "$TARGET_PREFIX" == "/" ]]; then
    echo "   Das überschreibt die laufende Installation."
    local confirm_name
    read -rp "Archivnamen zur Bestätigung erneut eingeben: " confirm_name
    if [[ "$confirm_name" != "$ARCHIVE_NAME" ]]; then
      echo "Abgebrochen."
      exit 0
    fi
  fi
  read -rp "Fortfahren? (ja/nein): " confirm
  [[ "$confirm" != "ja" ]] && { echo "Abgebrochen."; exit 0; }

  local stopped=0
  if [[ "$TARGET_PREFIX" == "/" ]] \
     && docker ps --format '{{.Names}}' | grep -qx "${PAPERLESS_CONTAINER}"; then
    echo "🐳 Stoppe ${PAPERLESS_CONTAINER}..."
    docker stop "${PAPERLESS_CONTAINER}" >/dev/null
    stopped=1
  fi

  local db_rel="${BACKUP_TMP#/}/paperless-db.sql"

  if [[ "$restore_type" == "1" || "$restore_type" == "3" ]]; then
    echo "📂 Stelle Media wieder her..."
    if ! ( cd "$TARGET_PREFIX" && borg extract "${RESTORE_REPO}::${ARCHIVE_NAME}" "${MEDIA_DIR#/}" ); then
      send_telegram "❌ Restore fehlgeschlagen
🔴 Fehler: [MEDIA] borg extract
🔢 Exit-Code: ${EXIT_RESTORE}"
      exit "$EXIT_RESTORE"
    fi
    echo "   ✅ Media wiederhergestellt"
  fi

  if [[ "$restore_type" == "1" || "$restore_type" == "4" ]]; then
    echo "📁 Stelle Data wieder her..."
    if ! ( cd "$TARGET_PREFIX" && borg extract "${RESTORE_REPO}::${ARCHIVE_NAME}" "${DATA_DIR#/}" ); then
      send_telegram "❌ Restore fehlgeschlagen
🔴 Fehler: [DATA] borg extract
🔢 Exit-Code: ${EXIT_RESTORE}"
      exit "$EXIT_RESTORE"
    fi
    echo "   ✅ Data wiederhergestellt"
  fi

  if [[ "$restore_type" == "1" ]]; then
    echo "📄 Stelle docker-compose.yml wieder her..."
    if ! ( cd "$TARGET_PREFIX" && borg extract "${RESTORE_REPO}::${ARCHIVE_NAME}" "${COMPOSE_FILE#/}" ); then
      echo "   ⚠️  docker-compose.yml konnte nicht wiederhergestellt werden"
    else
      echo "   ✅ docker-compose.yml wiederhergestellt"
    fi
  fi

  if [[ "$restore_type" == "1" || "$restore_type" == "2" ]]; then
    if ! container_running "${DB_CONTAINER}"; then
      echo "❌ Datenbank-Container '${DB_CONTAINER}' läuft nicht – DB-Restore nicht möglich."
      echo "   Erst den Container starten (docker compose up -d), dann erneut."
      send_telegram "❌ Restore fehlgeschlagen
🔴 Datenbank-Container '${DB_CONTAINER}' läuft nicht
🔢 Exit-Code: ${EXIT_RESTORE}"
      exit "$EXIT_RESTORE"
    fi
    echo "🗃 Stelle Datenbank wieder her..."
    local db_tmp
    db_tmp=$(mktemp -d)
    if ( cd "$db_tmp" && borg extract "${RESTORE_REPO}::${ARCHIVE_NAME}" "${db_rel}" ); then
      if docker exec -i "${DB_CONTAINER}" psql -U "${DB_USER}" "${DB_NAME}" \
           -v ON_ERROR_STOP=1 \
           < "${db_tmp}/${db_rel}"; then
        echo "   ✅ Datenbank wiederhergestellt"
      else
        rm -rf "$db_tmp"
        send_telegram "❌ Restore fehlgeschlagen
🔴 Fehler: [DB] psql restore
🔢 Exit-Code: ${EXIT_RESTORE}"
        exit "$EXIT_RESTORE"
      fi
    else
      rm -rf "$db_tmp"
      send_telegram "❌ Restore fehlgeschlagen
🔴 Fehler: [DB] borg extract (${db_rel})
🔢 Exit-Code: ${EXIT_RESTORE}"
      exit "$EXIT_RESTORE"
    fi
    rm -rf "$db_tmp"
  fi

  if (( stopped == 1 )); then
    echo ""
    echo "🐳 Starte Paperless..."
    docker compose -f "${COMPOSE_FILE}" up -d \
      || docker start "${PAPERLESS_CONTAINER}" >/dev/null
  fi

  echo ""
  echo "✅ Restore abgeschlossen!"
  send_telegram "✅ Paperless Restore abgeschlossen
🗄 Archiv: ${ARCHIVE_NAME}
☁️ Quelle: ${SELECTED_TARGET}
📁 Ziel: ${TARGET_PREFIX}"

  # Das heruntergeladene Repo bleibt sonst als Doppelter der
  # Datenmenge dauerhaft auf der Platte liegen.
  if [[ -d "${RESTORE_REPO}" && -O "${RESTORE_REPO}" ]]; then
    local restore_size
    restore_size=$(du -sh "${RESTORE_REPO}" 2>/dev/null | cut -f1 || echo "?")
    read -rp "   Heruntergeladenes Restore-Repo (${restore_size}) löschen? (j/n) [j]: " del_restore
    if [[ "${del_restore:-j}" == "j" ]]; then
      rm -rf "${RESTORE_REPO}"
      echo "   ✅ Restore-Repo gelöscht"
    fi
  fi
}

# ─────────────────────────────────────────────
# TEST / STATUS / CONFIG-CHECK
# ─────────────────────────────────────────────

run_test() {
  require_root
  load_conf

  echo ""
  echo "🧪 Test auswählen:"
  echo "  1) Backup (Archiv + Upload in alle Ziele)"
  echo "  2) Backup Dry-Run (kein Archiv, kein Upload)"
  echo "  3) Upload → Ziel auswählen"
  echo "  4) Borg Check"
  echo "  5) Restore Dry-Run Test"
  local choice
  prompt_int "Auswahl (1-5): " 1 5 choice

  case "$choice" in
    1) run_backup false ;;
    2) run_backup true ;;
    3)
      echo ""
      echo "Upload zu welchem Ziel?"
      local i
      for i in "${!BACKUP_TARGETS[@]}"; do
        echo "  $((i+1))) ${BACKUP_TARGETS[$i]}"
      done
      local upload_idx
      prompt_int "Auswahl: " 1 "${#BACKUP_TARGETS[@]}" upload_idx
      run_upload_only "${BACKUP_TARGETS[$((upload_idx-1))]}"
      ;;
    4) run_borg_check ;;
    5) run_restore_test ;;
  esac
}

run_status() {
  require_root
  load_conf
  check_passphrase
  export BORG_PASSCOMMAND="cat ${PASSPHRASE_FILE}"

  echo ""
  echo "╔══════════════════════════════════════╗"
  echo "║     Paperless Backup Status          ║"
  echo "╚══════════════════════════════════════╝"

  echo ""
  echo "🐳 Docker Container:"
  docker ps --format "table {{.Names}}\t{{.Status}}" \
    | grep -iE "paperless|redis|tika|gotenberg" || echo "   keine gefunden"

  echo ""
  echo "⏰ Systemd Timer:"
  systemctl list-timers --no-pager | grep paperless || echo "   keine aktiven Timer"

  echo ""
  echo "📦 Borg Archive (letzte 5):"
  borg list "${BORG_REPO}" 2>/dev/null | tail -5 || echo "   nicht verfügbar"

  echo ""
  echo "💾 Repository-Größe:"
  borg_repo_size "${BORG_REPO}"
  local repo_free
  if repo_free=$(fs_free_kb "${BORG_REPO}"); then
    echo "   Frei auf dem Repository-Dateisystem: $(( repo_free / 1024 / 1024 )) GB"
  fi

  echo ""
  echo "☁️  Cloud-Ziele:"
  local t
  for t in "${BACKUP_TARGETS[@]}"; do
    echo "   • ${t}"
  done

  echo ""
  echo "📋 Letzte Backup-Logs:"
  tail -5 "/var/log/paperless-backup.log" 2>/dev/null || echo "   keine Logs"

  echo ""
  echo "🔍 Letzter Borg Check:"
  tail -3 "/var/log/paperless-borg-check.log" 2>/dev/null || echo "   noch kein Check gelaufen"

  echo ""
  echo "🧪 Letzter Restore-Test:"
  tail -3 "/var/log/paperless-restore-test.log" 2>/dev/null || echo "   noch kein Test gelaufen"
}

run_config_check() {
  require_root
  load_conf
  check_passphrase
  export BORG_PASSCOMMAND="cat ${PASSPHRASE_FILE}"

  local ERRORS=0
  check_ok()   { echo "   ✅ $*"; }
  check_fail() { echo "   ❌ $*"; ERRORS=$(( ERRORS + 1 )); }
  check_info() { echo "   ℹ️  $*"; }

  echo ""
  echo "╔══════════════════════════════════════╗"
  echo "║     Paperless Config-Check           ║"
  echo "╚══════════════════════════════════════╝"

  echo ""
  echo "📂 Pfade:"
  if [[ -d "$MEDIA_DIR" ]]; then check_ok "Media-Verzeichnis: ${MEDIA_DIR}"; else check_fail "Media-Verzeichnis fehlt: ${MEDIA_DIR}"; fi
  if [[ -d "$DATA_DIR" ]]; then check_ok "Data-Verzeichnis: ${DATA_DIR}"; else check_fail "Data-Verzeichnis fehlt: ${DATA_DIR}"; fi
  if [[ -f "$COMPOSE_FILE" ]]; then check_ok "docker-compose.yml: ${COMPOSE_FILE}"; else check_fail "docker-compose.yml fehlt: ${COMPOSE_FILE}"; fi
  if [[ -w "$BACKUP_TMP" ]]; then check_ok "Schreibrechte auf ${BACKUP_TMP}"; else check_fail "Keine Schreibrechte auf ${BACKUP_TMP}"; fi
  if [[ -d "$BORG_REPO" ]]; then check_ok "Borg-Repository: ${BORG_REPO}"; else check_fail "Borg-Repository fehlt: ${BORG_REPO}"; fi

  echo ""
  echo "💾 Freier Platz:"
  local repo_free_min avail_mb
  repo_free_min="${BACKUP_MIN_FREE_MB:-4096}"
  if repo_free=$(fs_free_kb "${BORG_REPO}"); then
    avail_mb=$(( repo_free / 1024 ))
    if (( repo_free >= repo_free_min * 1024 )); then
      check_ok "${avail_mb} MB frei (benötigt: ${repo_free_min} MB)"
    else
      check_fail "${avail_mb} MB frei (benötigt: ${repo_free_min} MB)"
    fi
  else
    check_fail "Freier Platz nicht ermittelbar: ${BORG_REPO}"
  fi

  echo ""
  echo "🐳 Container:"
  if container_running "${PAPERLESS_CONTAINER}"; then
    check_ok "Paperless-Container: ${PAPERLESS_CONTAINER}"
  else
    check_fail "Paperless-Container läuft nicht: ${PAPERLESS_CONTAINER}"
  fi
  if container_running "${DB_CONTAINER}"; then
    check_ok "Datenbank-Container: ${DB_CONTAINER}"
  else
    check_fail "Datenbank-Container läuft nicht: ${DB_CONTAINER}"
  fi

  echo ""
  echo "🔐 Passphrase:"
  check_ok "${PASSPHRASE_FILE} vorhanden (Mode $(stat -c '%a' "$PASSPHRASE_FILE"))"

  echo ""
  echo "🔧 Versionen:"
  local borg_version
  borg_version=$(borg --version 2>/dev/null | awk '{print $2}') || borg_version="unbekannt"
  if [[ "$borg_version" == "unbekannt" ]]; then
    check_fail "borg nicht ausführbar"
  elif [[ "$(printf '%s\n%s\n' "$MIN_BORG_VERSION" "$borg_version" | sort -V | head -1)" \
          != "$MIN_BORG_VERSION" ]]; then
    check_fail "borg ${borg_version} ist älter als ${MIN_BORG_VERSION}"
  else
    check_ok "$(borg --version)"
  fi
  check_info "$(rclone --version | head -1)"
  check_info "$(docker --version)"
  check_info "jq $(jq --version)"

  echo ""
  echo "☁️  Cloud-Ziele:"
  local t remote
  for t in "${BACKUP_TARGETS[@]}"; do
    remote="${t%%:*}"
    if rclone lsd "${remote}:" >/dev/null 2>&1; then
      check_ok "${t}"
    else
      check_fail "${t} – Remote nicht erreichbar"
    fi
  done

  echo ""
  if (( ERRORS == 0 )); then
    echo "✅ Alle Checks bestanden – System bereit."
  else
    echo "❌ ${ERRORS} Checks fehlgeschlagen – bitte beheben!"
    exit 1
  fi
}

# ─────────────────────────────────────────────
# MAIN MENU
# ─────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  ██████╗  █████╗██████╗  ██████╗            ║"
echo "║  ██╔══██╗██╔══██╗██╔══██╗██╔═══██╗          ║"
echo "║  ██████╔╝███████║██████╔╝██║   ██║          ║"
echo "║  ██╔═══╝ ██╔══██║██╔══██╗██║   ██║          ║"
echo "║  ██║     ██║  ██║██████╔╝╚██████╔╝          ║"
echo "║  ╚═╝     ╚═╝  ╚═╝╚═════╝  ╚═════╝  v${PABO_VERSION}     ║"
echo "║  Paperless-Borg Backup Orchestrator          ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "Was möchtest du tun?"
echo "  1) setup        – Einrichtung / Ziele ändern"
echo "  2) restore      – Daten wiederherstellen"
echo "  3) test         – Backup / Check / Restore-Test manuell starten"
echo "  4) status       – Systemübersicht"
echo "  5) config-check – Konfiguration prüfen"
echo "  6) exit"
echo ""

prompt_int "Auswahl (1-6): " 1 6 MAIN_CHOICE

case "$MAIN_CHOICE" in
  1) run_setup ;;
  2) run_restore ;;
  3) run_test ;;
  4) run_status ;;
  5) run_config_check ;;
  6) exit 0 ;;
esac
