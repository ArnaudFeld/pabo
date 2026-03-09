#!/bin/bash
# pabo.sh – PABO: Paperless-Borg Backup Orchestrator v1.0
# Automated, encrypted, multi-cloud backups for Paperless-ngx
# powered by BorgBackup and rclone.
# https://github.com/ArnaudFeld/pabo
set -euo pipefail

CONF_FILE="/etc/paperless-backup.conf"
LOG_FILE="/var/log/paperless-backup.log"
BORG_CHECK_LOG="/var/log/paperless-borg-check.log"
RESTORE_TEST_LOG="/var/log/paperless-restore-test.log"
SCRIPT_DIR="/usr/local/bin"
LIB_FILE="/usr/local/lib/paperless-backup-common.sh"

export EXIT_OK=0 EXIT_DB=10 EXIT_BORG=11 EXIT_RCLONE=12 EXIT_RESTORE=13 EXIT_RESTORE_TEST=14

# ─────────────────────────────────────────────
# HILFSFUNKTIONEN
# ─────────────────────────────────────────────

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

load_conf() {
  if [[ ! -f "$CONF_FILE" ]]; then
    echo "❌ Keine Konfiguration gefunden unter ${CONF_FILE}"
    echo "   Bitte zuerst 'setup' ausführen."
    exit 1
  fi
  # shellcheck source=/etc/paperless-backup.conf disable=SC1091
  source "$CONF_FILE"
}


# ─────────────────────────────────────────────
# CONFIG-VALIDIERUNG nach load_conf / source
# Prüft Variableninhalte auf erlaubte Zeichensätze bevor sie in
# Shell-Kommandos verwendet werden. Verhindert Code-Injection durch
# eine manipulierte CONF_FILE.
# ─────────────────────────────────────────────

validate_conf() {
  local errors=0

  _check_path() {
    local val="$1" label="$2"
    if [[ -z "$val" ]]; then
      echo "❌ Config: ${label} ist leer"; errors=$(( errors + 1 )); return
    fi
    # Erlaubt: alphanumerisch, / - _ . Leerzeichen verboten, keine Shell-Metazeichen
    if [[ "$val" =~ [^a-zA-Z0-9/_.\-] ]]; then
      echo "❌ Config: ${label} enthält ungültige Zeichen: '${val}'"
      errors=$(( errors + 1 ))
    fi
  }

  _check_name() {
    local val="$1" label="$2"
    if [[ -z "$val" ]]; then
      echo "❌ Config: ${label} ist leer"; errors=$(( errors + 1 )); return
    fi
    # Container/DB-Namen: alphanumerisch + - _ .
    if [[ "$val" =~ [^a-zA-Z0-9_.\-] ]]; then
      echo "❌ Config: ${label} enthält ungültige Zeichen: '${val}'"
      errors=$(( errors + 1 ))
    fi
  }

  _check_int() {
    local val="$1" label="$2"
    if [[ ! "$val" =~ ^[0-9]+$ ]]; then
      echo "❌ Config: ${label} ist keine Ganzzahl: '${val}'"
      errors=$(( errors + 1 ))
    fi
  }

  _check_nonempty() {
    local val="$1" label="$2"
    if [[ -z "$val" ]]; then
      echo "❌ Config: ${label} ist leer"; errors=$(( errors + 1 ))
    fi
  }

  # Pfade
  _check_path "${MEDIA_DIR:-}"    "MEDIA_DIR"
  _check_path "${DATA_DIR:-}"     "DATA_DIR"
  _check_path "${EXPORT_DIR:-}"   "EXPORT_DIR"
  _check_path "${BORG_REPO:-}"    "BORG_REPO"
  _check_path "${BACKUP_TMP:-}"   "BACKUP_TMP"
  _check_path "${COMPOSE_FILE:-}" "COMPOSE_FILE"

  # Container- und DB-Namen
  _check_name "${PAPERLESS_CONTAINER:-}" "PAPERLESS_CONTAINER"
  _check_name "${DB_CONTAINER:-}"        "DB_CONTAINER"
  _check_name "${DB_NAME:-}"             "DB_NAME"
  _check_name "${DB_USER:-}"             "DB_USER"

  # Numerische Werte
  _check_int "${RCLONE_TRANSFERS:-}" "RCLONE_TRANSFERS"
  _check_int "${RCLONE_CHECKERS:-}"  "RCLONE_CHECKERS"

  # RCLONE_BWLIMIT: optional – leer = kein Limit, sonst z.B. "2M", "1.5M", "500K"
  if [[ -n "${RCLONE_BWLIMIT:-}" ]] &&      [[ ! "${RCLONE_BWLIMIT}" =~ ^[0-9]+(\.[0-9]+)?[KMGkmg]?$ ]]; then
    echo "❌ Config: RCLONE_BWLIMIT ungültiges Format: '${RCLONE_BWLIMIT}' (erwartet z.B. 2M, 500K, leer)"
    errors=$(( errors + 1 ))
  fi

  # Pflichtfelder ohne Formatprüfung (Tokens können beliebige druckbare Zeichen enthalten)
  _check_nonempty "${TELEGRAM_TOKEN:-}"   "TELEGRAM_TOKEN"
  _check_nonempty "${TELEGRAM_CHAT_ID:-}" "TELEGRAM_CHAT_ID"

  # BACKUP_TARGETS: jedes Element muss "name:/pfad" Form haben
  if [[ ${#BACKUP_TARGETS[@]} -eq 0 ]]; then
    echo "❌ Config: BACKUP_TARGETS ist leer"
    errors=$(( errors + 1 ))
  else
    local t
    for t in "${BACKUP_TARGETS[@]}"; do
      # Remote-Name: alphanumerisch + - / Pfad: alphanumerisch + / - _ .
      if [[ ! "$t" =~ ^[a-zA-Z0-9_-]+:[a-zA-Z0-9/_.\-]+$ ]]; then
        echo "❌ Config: BACKUP_TARGETS enthält ungültigen Eintrag: '${t}'"
        errors=$(( errors + 1 ))
      fi
    done
  fi

  if (( errors > 0 )); then
    echo ""
    echo "❌ ${errors} Config-Validierungsfehler – Script abgebrochen."
    echo "   Bitte ${CONF_FILE} prüfen oder Setup erneut ausführen."
    exit 1
  fi
}

# N5-Fix: Passphrase-Datei prüfen bevor BORG_PASSCOMMAND gesetzt wird
check_passphrase() {
  if [[ ! -f /root/.borg_passphrase ]]; then
    echo "❌ /root/.borg_passphrase nicht gefunden!"
    echo "   Bitte Passphrase manuell nach /root/.borg_passphrase schreiben (chmod 600)"
    exit 1
  fi
}

# K1-Fix: jq für sicheres JSON-Escaping / M4-Fix: curl Timeouts
send_telegram() {
  local message="$1"
  jq -n \
    --arg cid  "${TELEGRAM_CHAT_ID}" \
    --arg text "$message" \
    '{"chat_id":$cid,"text":$text,"parse_mode":"HTML"}' | \
  curl -s --max-time 10 --connect-timeout 5 \
    -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    --data-binary @- > /dev/null
}

detect_value() {
  local label="$1" detected="$2" varname="$3"
  echo ""
  echo "🔍 Erkannt: ${label} = ${detected}"
  read -rp "   Korrekt? (Enter = ja, sonst neuen Wert eingeben): " input
  printf -v "$varname" '%s' "${input:-$detected}"
}

sanitize_remote_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g'
}

# H7-Info: validate_int wird aktuell nicht direkt aufgerufen (alle interaktiven
# Eingaben nutzen prompt_int). Bleibt für nicht-interaktive Config-Validierung
# erhalten, z.B. für künftige Prüfung von RCLONE_TRANSFERS beim Config-Laden.
# M1-Fix: Regex ^[0-9]+$ – akzeptiert auch 0 als validen Wert
validate_int() {
  local val="$1" min="$2" max="$3" label="$4"
  if [[ ! "$val" =~ ^[0-9]+$ ]] || (( val < min )) || (( val > max )); then
    echo "❌ Ungültige Eingabe für ${label}: '${val}' (erwartet: ${min}-${max})"
    exit 1
  fi
}

# N3-Fix: Retry-Schleife / N2(neu)-Fix: EOF-Schutz
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

# M1(neu)-HINWEIS: Identische Funktion existiert in LIB_FILE (für run_backup).
# Bei Änderungen BEIDE Stellen aktualisieren (hier + COMMON-Heredoc in generate_scripts).
# Borg 1.x: .cache.stats.unique_csize / Borg 2.x: .stats.unique_csize
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

# ─────────────────────────────────────────────
# H1-Fix: Alte Scripts und Timer sauber entfernen
# Prüft auf laufende Prozesse, stoppt Timer, löscht Units + Scripts
# ─────────────────────────────────────────────

cleanup_old_scripts() {
  echo ""
  echo "🧹 Räume alte Scripts und Timer auf..."

  # Laufende Backup-Prozesse prüfen – bei Fund Abbruch mit Meldung
  if pgrep -f "paperless-backup-" > /dev/null 2>&1; then
    echo "❌ Laufende Backup-Prozesse gefunden – bitte warten:"
    pgrep -a -f "paperless-backup-" || true
    exit 1
  fi

  # Timer stoppen und deaktivieren
  local timer tname
  for timer in \
      /etc/systemd/system/paperless-backup-*.timer \
      /etc/systemd/system/paperless-borg-check.timer \
      /etc/systemd/system/paperless-restore-test.timer; do
    [[ -f "$timer" ]] || continue
    tname=$(basename "$timer")
    systemctl stop    "$tname" 2>/dev/null || true
    systemctl disable "$tname" 2>/dev/null || true
    echo "   🛑 Timer gestoppt: ${tname}"
  done

  # Alte pro-Ziel Backup-Scripts löschen
  local script
  for script in "${SCRIPT_DIR}"/paperless-backup-*.sh; do
    [[ -f "$script" ]] || continue
    rm -f "$script"
    echo "   🗑 Script gelöscht: ${script}"
  done

  # Alte Systemd-Units löschen (service + timer)
  # H5-Info: Check- und Restore-Scripts werden ebenfalls entfernt und sofort
  # neu generiert. Das kurze Fehl-Fenster dazwischen ist akzeptabel.
  # Bei Bedarf: Phase 1 = nur zielabhängige Scripts, Phase 2 nach generate_scripts.
  local unit
  for unit in \
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
  if [[ $EUID -ne 0 ]]; then echo "❌ Bitte als root ausführen."; exit 1; fi

  # H1-Fix: Setup-Modus erkennen
  # Modus 0 = Ersteinrichtung (kein CONF_FILE)
  # Modus 1 = Ziele ändern     (CONF_FILE vorhanden)
  # Modus 2 = Nur neu generieren (CONF_FILE vorhanden, unverändert)
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
    validate_conf
    echo ""
    echo "   Aktuell konfigurierte Ziele:"
    for t in "${BACKUP_TARGETS[@]}"; do
      echo "   • ${t}"
    done
    echo ""
    echo "🔒 Borg-Repository und Passphrase werden nicht verändert."
  fi

  echo "╔══════════════════════════════════════╗"
  echo "║     Paperless Backup Setup           ║"
  echo "╚══════════════════════════════════════╝"

  # Modus 2: Nur neu generieren – direkt zu cleanup + generate
  if [[ $SETUP_MODE -eq 2 ]]; then
    cleanup_old_scripts
    generate_scripts
    setup_systemd
    echo ""
    echo "✅ Scripts und Timer erfolgreich neu generiert."
    return
  fi

  # Modus 0+1: Abhängigkeiten installieren
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
    read -rp "Ziel-Pfad auf ${SELECTED_REMOTE} (z.B. /Paperless-Borg-Encrypted): " remote_path
    BACKUP_TARGETS+=("${REMOTE_CLEAN}:${remote_path}")
    echo "   ✅ Ziel ${t}: ${REMOTE_CLEAN}:${remote_path}"
  done

  # Modus 1: Nur Ziele neu – restliche Config aus geladenem CONF_FILE behalten
  if [[ $SETUP_MODE -eq 1 ]]; then
    # BACKUP_TARGETS in Config aktualisieren
    local tmp_conf
    tmp_conf=$(mktemp)
    # B4-Fix: tmp_conf enthält Klartext-Token – bei Fehler sofort löschen
    trap 'rm -f "$tmp_conf"' EXIT
    # Alles außer BACKUP_TARGETS-Block übernehmen, dann neues Array anhängen
    sed '/^BACKUP_TARGETS=($/,/^)$/d' "$CONF_FILE" > "$tmp_conf"
    {
      echo "BACKUP_TARGETS=("
      for t in "${BACKUP_TARGETS[@]}"; do
        printf "  %q\n" "$t"
      done
      echo ")"
    } >> "$tmp_conf"
    mv "$tmp_conf" "$CONF_FILE"
    trap - EXIT  # tmp_conf erfolgreich ersetzt – trap nicht mehr nötig
    chmod 600 "$CONF_FILE"
    echo ""
    echo "✅ Ziele in ${CONF_FILE} aktualisiert."
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

  # ── Ab hier nur Modus 0 (Ersteinrichtung) ──

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
    | grep -oP '(?<==)[^\s"]+' | head -1 || echo "paperless")
  DETECTED_DB_USER=$(grep -E 'POSTGRES_USER|DB_USER' "$COMPOSE_FILE" 2>/dev/null \
    | grep -oP '(?<==)[^\s"]+' | head -1 || echo "paperless")
  detect_value "Datenbank Name" "$DETECTED_DB_NAME" DB_NAME
  detect_value "Datenbank User" "$DETECTED_DB_USER" DB_USER

  echo ""
  echo "📂 Erkenne gemountete Pfade..."
  DETECTED_MEDIA=$(docker inspect "$PAPERLESS_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/usr/src/paperless/media"}}{{.Source}}{{end}}{{end}}' \
    2>/dev/null || echo "/data/paperless/media")
  DETECTED_DATA=$(docker inspect "$PAPERLESS_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/usr/src/paperless/data"}}{{.Source}}{{end}}{{end}}' \
    2>/dev/null || echo "/data/paperless/data")
  DETECTED_EXPORT=$(docker inspect "$PAPERLESS_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/usr/src/paperless/export"}}{{.Source}}{{end}}{{end}}' \
    2>/dev/null || echo "/data/paperless/export")

  detect_value "Media-Pfad"   "$DETECTED_MEDIA"  MEDIA_DIR
  detect_value "Data-Pfad"    "$DETECTED_DATA"   DATA_DIR
  detect_value "Export-Pfad"  "$DETECTED_EXPORT" EXPORT_DIR
  detect_value "Borg Repository Pfad" "/backup/paperless-borg" BORG_REPO
  detect_value "Temporäres Backup-Verzeichnis" "/backup/paperless-tmp" BACKUP_TMP

  # Warnung bei gleichem Filesystem
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
  read -rp "   Bot Token: " TELEGRAM_TOKEN
  read -rp "   Chat ID:   " TELEGRAM_CHAT_ID

  echo ""
  echo "☁️  rclone Upload-Optionen"
  read -rp "   Bandbreitenlimit (leer = kein Limit, z.B. 2M): " RCLONE_BWLIMIT
  read -rp "   Parallele Transfers [4]: " RCLONE_TRANSFERS
  RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-4}"
  read -rp "   Checker [8]: " RCLONE_CHECKERS
  RCLONE_CHECKERS="${RCLONE_CHECKERS:-8}"

  echo ""
  echo "📂 Borg Exclude-Liste konfigurieren"
  BORG_EXCLUDES=()

  read -rp "   Log-Verzeichnis (${DATA_DIR}/log) ausschließen? (j/n) [j]: " excl_log
  [[ "${excl_log:-j}" == "j" ]] && BORG_EXCLUDES+=("${DATA_DIR}/log")

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
    BORG_EXCLUDES+=("$custom_excl")
    read -rp "   Noch einen? (j/n): " add_more
  done

  echo ""
  echo "📄 Document-Exporter"
  read -rp "   Aktivieren? (j/n) [n]: " enable_exporter
  ENABLE_DOCUMENT_EXPORTER="false"
  EXPORTER_DEST="/usr/src/paperless/export"
  if [[ "${enable_exporter:-n}" == "j" ]]; then
    ENABLE_DOCUMENT_EXPORTER="true"
    detect_value "Export-Zielverzeichnis im Container" "/usr/src/paperless/export" EXPORTER_DEST
  fi

  echo ""
  echo "💾 Speichere Konfiguration nach ${CONF_FILE}..."
  cat > "$CONF_FILE" <<EOF
# PABO – Paperless-Borg Backup Orchestrator v1.0
# Konfiguration erstellt: $(date '+%Y-%m-%d %H:%M:%S')

PAPERLESS_CONTAINER="${PAPERLESS_CONTAINER}"
DB_CONTAINER="${DB_CONTAINER}"
COMPOSE_FILE="${COMPOSE_FILE}"

DB_NAME="${DB_NAME}"
DB_USER="${DB_USER}"

MEDIA_DIR="${MEDIA_DIR}"
DATA_DIR="${DATA_DIR}"
EXPORT_DIR="${EXPORT_DIR}"
BORG_REPO="${BORG_REPO}"
BACKUP_TMP="${BACKUP_TMP}"

# H3-Fix: Bei Token-Rotation: paperless-setup.sh → Setup → Modus 2 (neu generieren)
# oder diesen Wert manuell ersetzen und danach Modus 2 ausführen.
TELEGRAM_TOKEN="${TELEGRAM_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"

BACKUP_TARGETS=(
$(
  # N1(neu)-Fix: printf %q – Bash-sicheres Quoting für Sonderzeichen in Pfaden
  for t in "${BACKUP_TARGETS[@]}"; do
    printf "  %q\n" "$t"
  done
)
)

RCLONE_BWLIMIT="${RCLONE_BWLIMIT}"
RCLONE_TRANSFERS="${RCLONE_TRANSFERS}"
RCLONE_CHECKERS="${RCLONE_CHECKERS}"

BORG_EXCLUDES=(
$(
  for e in "${BORG_EXCLUDES[@]}"; do
    printf "  %q\n" "$e"
  done
)
)

ENABLE_DOCUMENT_EXPORTER="${ENABLE_DOCUMENT_EXPORTER}"
EXPORTER_DEST="${EXPORTER_DEST}"
EOF
  chmod 600 "$CONF_FILE"
  echo "   ✅ Konfiguration gespeichert (chmod 600)"

  mkdir -p "$BORG_REPO" "$BACKUP_TMP" /backup/restore-test
  chmod 700 "$BORG_REPO"

  echo ""
  echo "🔐 Initialisiere Borg Repository..."
  BORG_PASSPHRASE=$(openssl rand -base64 32)
  echo "$BORG_PASSPHRASE" > /root/.borg_passphrase
  chmod 600 /root/.borg_passphrase

  # REST-K3-Fix: Nur der Lesebefehl steht in /proc/<pid>/environ
  export BORG_PASSCOMMAND="cat /root/.borg_passphrase"
  borg init --encryption=repokey "$BORG_REPO"

  echo ""
  echo "┌─────────────────────────────────────────┐"
  echo "│  ⚠️  BORG PASSPHRASE – SICHER AUFBEWAHREN │"
  echo "├─────────────────────────────────────────┤"
  echo "│  ${BORG_PASSPHRASE}"
  echo "│  Gespeichert: /root/.borg_passphrase    │"
  echo "│  → extern sichern! (Single Point of     │"
  echo "│    Failure bei Verlust)                 │"
  echo "└─────────────────────────────────────────┘"
  read -rp "Passphrase notiert und extern gesichert? (Enter)"

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

generate_scripts() {
  [[ "${_SETUP_VARS_LOADED:-0}" -eq 1 ]] || load_conf
  validate_conf

  echo ""
  echo "📝 Generiere Backup-Scripts..."
  mkdir -p /usr/local/lib

  cat > "$LIB_FILE" <<'COMMON'
#!/bin/bash
set -euo pipefail
source /etc/paperless-backup.conf

EXIT_OK=0; EXIT_DB=10; EXIT_BORG=11; EXIT_RCLONE=12; EXIT_RESTORE=13; EXIT_RESTORE_TEST=14

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# K1-Fix: jq für JSON-Escaping / M4-Fix: curl Timeouts
send_telegram() {
  local message="$1"
  jq -n \
    --arg cid  "${TELEGRAM_CHAT_ID}" \
    --arg text "$message" \
    '{"chat_id":$cid,"text":$text,"parse_mode":"HTML"}' | \
  curl -s --max-time 10 --connect-timeout 5 \
    -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    --data-binary @- > /dev/null
}

# M1(neu)-HINWEIS: Identische Funktion im Haupt-Script (für run_status).
# Bei Änderungen BEIDE Stellen aktualisieren.
# Borg 1.x: .cache.stats.unique_csize / Borg 2.x: .stats.unique_csize
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

run_backup() {
  local TARGET="$1"
  local DRY_RUN="${2:-false}"
  local REMOTE="${TARGET%%:*}"
  local REMOTE_PATH="${TARGET#*:}"
  local START_TIME
  START_TIME=$(date +%s)
  local ARCHIVE_NAME="paperless-$(date +%Y-%m-%d-%H%M%S)"

  # H2-Fix: Target-spezifischer Lock-Pfad – verhindert Archivname-Kollision
  # bei gleichzeitigen Starts und macht Locks unabhängig voneinander
  local LOCK_SAFE
  LOCK_SAFE=$(echo "${REMOTE}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')

  [[ "$DRY_RUN" == "true" ]] \
    && log "=== DRY-RUN: Backup → ${TARGET} ===" \
    || log "=== Starte Backup → ${TARGET} ==="

  (
    flock -n 9 || {
      log "⚠️  Backup für ${REMOTE} läuft bereits (Lock aktiv). Abbruch."
      send_telegram "⚠️ Backup übersprungen
🔒 Ein anderer Backup-Prozess für ${REMOTE} läuft bereits.
☁️ Ziel: ${TARGET}"
      exit 0
    }

    # REST-K3-Fix: Nur der Lesebefehl in Env, nicht die Passphrase
    export BORG_PASSCOMMAND="cat /root/.borg_passphrase"

    if [[ "${ENABLE_DOCUMENT_EXPORTER:-false}" == "true" && "$DRY_RUN" == "false" ]]; then
      log "[EXPORTER] Starte document_exporter..."
      if docker exec "${PAPERLESS_CONTAINER}" document_exporter "${EXPORTER_DEST}" \
          2>&1 | tee -a "$LOG_FILE"; then
        log "[EXPORTER] ✅ document_exporter erfolgreich"
      else
        log "[EXPORTER] ⚠️  document_exporter fehlgeschlagen – Backup läuft weiter"
        send_telegram "⚠️ document_exporter Warnung
❌ Export fehlgeschlagen – Backup läuft ohne aktuellen Export weiter.
☁️ Ziel: ${TARGET}"
      fi
    fi

    log "[DB] Erstelle PostgreSQL-Dump..."
    mkdir -p "${BACKUP_TMP}"
    local DB_DUMP_SIZE="0"
    if [[ "$DRY_RUN" == "true" ]]; then
      log "[DB] DRY-RUN: Überspringe DB-Dump"
    else
      # --clean --if-exists: DROPs Tabellen vor dem Einspielen
      # REST-M4-Hinweis: Bei schwerer Korruption manuell DROP/CREATE DATABASE
      docker exec "${DB_CONTAINER}" pg_dump \
        --clean --if-exists \
        -U "${DB_USER}" "${DB_NAME}" \
        > "${BACKUP_TMP}/paperless-db.sql" || {
          log "[DB] ❌ DB-Dump fehlgeschlagen (Exit: ${EXIT_DB})"
          send_telegram "❌ Backup fehlgeschlagen
🔴 Fehler: [DB] PostgreSQL-Dump
☁️ Ziel: ${TARGET}
🔢 Exit-Code: ${EXIT_DB}"
          exit $EXIT_DB
        }
      DB_DUMP_SIZE=$(du -h "${BACKUP_TMP}/paperless-db.sql" | cut -f1)
      log "[DB] ✅ Dump OK (${DB_DUMP_SIZE})"
    fi

    local borg_args=()
    borg_args=(create --stats --compression lz4)
    [[ "$DRY_RUN" == "true" ]] && borg_args+=(--dry-run)

    local pattern
    for pattern in "${BORG_EXCLUDES[@]:-}"; do
      [[ -n "$pattern" ]] && borg_args+=(--exclude "$pattern")
    done

    borg_args+=("${BORG_REPO}::${ARCHIVE_NAME}")
    borg_args+=("${MEDIA_DIR}" "${DATA_DIR}")
    [[ "$DRY_RUN" == "false" ]] && borg_args+=("${BACKUP_TMP}/paperless-db.sql")
    borg_args+=("${COMPOSE_FILE}")
    [[ "${ENABLE_DOCUMENT_EXPORTER:-false}" == "true" && "$DRY_RUN" == "false" ]] \
      && borg_args+=("${EXPORT_DIR}")

    log "[BORG] Starte borg create..."
    borg "${borg_args[@]}" 2>&1 | tee -a "$LOG_FILE" || {
      log "[BORG] ❌ borg create fehlgeschlagen (Exit: ${EXIT_BORG})"
      send_telegram "❌ Backup fehlgeschlagen
🔴 Fehler: [BORG] borg create
☁️ Ziel: ${TARGET}
🔢 Exit-Code: ${EXIT_BORG}"
      exit $EXIT_BORG
    }

    if [[ "$DRY_RUN" == "false" ]]; then
      log "[BORG] Prune alte Archive..."
      borg prune \
        --glob-archives 'paperless-*' \
        --keep-daily=14 \
        --keep-weekly=8 \
        --keep-monthly=6 \
        "${BORG_REPO}" 2>&1 | tee -a "$LOG_FILE" || {
          log "[BORG] ⚠️  Prune teilweise fehlgeschlagen – nicht kritisch"
        }

      log "[BORG] Compact Repository..."
      borg compact "${BORG_REPO}" 2>&1 | tee -a "$LOG_FILE" || {
        log "[BORG] ⚠️  Compact fehlgeschlagen – nicht kritisch"
        send_telegram "⚠️ Borg Compact Warnung
Compact nach Prune fehlgeschlagen. Backup war erfolgreich.
☁️ Ziel: ${TARGET}"
      }

      local rclone_opts=(
        --progress
        --transfers "${RCLONE_TRANSFERS:-4}"
        --checkers  "${RCLONE_CHECKERS:-8}"
      )
      [[ -n "${RCLONE_BWLIMIT:-}" ]] && rclone_opts+=(--bwlimit "${RCLONE_BWLIMIT}")

      log "[RCLONE] Upload → ${TARGET}..."
      rclone sync "${BORG_REPO}" "${REMOTE}:${REMOTE_PATH}" \
        "${rclone_opts[@]}" 2>&1 | tee -a "$LOG_FILE" || {
          log "[RCLONE] ❌ Upload fehlgeschlagen (Exit: ${EXIT_RCLONE})"
          send_telegram "❌ Backup fehlgeschlagen
🔴 Fehler: [RCLONE] Upload
☁️ Ziel: ${TARGET}
🔢 Exit-Code: ${EXIT_RCLONE}"
          exit $EXIT_RCLONE
        }

      rm -f "${BACKUP_TMP}/paperless-db.sql"

      local END_TIME DURATION ARCHIVE_COUNT MEDIA_FILE_COUNT REPO_SIZE
      END_TIME=$(date +%s)
      DURATION=$(( END_TIME - START_TIME ))
      ARCHIVE_COUNT=$(borg list "${BORG_REPO}" 2>/dev/null | wc -l || echo "?")
      MEDIA_FILE_COUNT=$(find "${MEDIA_DIR}" -type f 2>/dev/null | wc -l || echo "?")
      REPO_SIZE=$(borg_repo_size "${BORG_REPO}")

      send_telegram "✅ Paperless Backup erfolgreich
🗄 Archiv: ${ARCHIVE_NAME}
☁️ Ziel: ${TARGET}
📂 Media: ${MEDIA_FILE_COUNT} Dateien
🗃 DB-Dump: ${DB_DUMP_SIZE}
📦 Archive gesamt: ${ARCHIVE_COUNT}
💾 Repo-Größe: ${REPO_SIZE}
⏱ Dauer: ${DURATION}s"
      log "=== Backup → ${TARGET} erfolgreich (${DURATION}s) ==="
    else
      log "=== DRY-RUN abgeschlossen – keine Änderungen vorgenommen ==="
    fi

  ) 9>"/var/lock/paperless-backup-${LOCK_SAFE}.lock"
}
COMMON
  chmod 644 "$LIB_FILE"

  local REMOTE_NAME SAFE_NAME SCRIPT_PATH
  for target in "${BACKUP_TARGETS[@]}"; do
    REMOTE_NAME="${target%%:*}"
    SAFE_NAME=$(sanitize_remote_name "$REMOTE_NAME")
    SCRIPT_PATH="${SCRIPT_DIR}/paperless-backup-${SAFE_NAME}.sh"
    # B1-Fix: printf %q verhindert Syntaxfehler bei Sonderzeichen im Pfad
    cat > "$SCRIPT_PATH" <<EOF
#!/bin/bash
LOG_FILE="${LOG_FILE}"
source ${LIB_FILE}
run_backup $(printf '%q' "${target}") "false"
EOF
    chmod 755 "$SCRIPT_PATH"
    echo "   ✅ ${SCRIPT_PATH}"
  done

  # ── Borg Check Script ───────────────────────
  cat > "${SCRIPT_DIR}/paperless-borg-check.sh" <<BORGCHECK
#!/bin/bash
set -euo pipefail
source /etc/paperless-backup.conf
LOG_FILE="${BORG_CHECK_LOG}"

log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*" | tee -a "\$LOG_FILE"; }

send_telegram() {
  local message="\$1"
  jq -n \
    --arg cid  "\${TELEGRAM_CHAT_ID}" \
    --arg text "\$message" \
    '{"chat_id":$cid,"text":$text,"parse_mode":"HTML"}' | \
  curl -s --max-time 10 --connect-timeout 5 \
    -X POST "https://api.telegram.org/bot\${TELEGRAM_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    --data-binary @- > /dev/null
}

borg_repo_size() {
  local repo="\$1"
  borg info --json "\$repo" 2>/dev/null | jq -r '
    (.cache.stats.unique_csize // .stats.unique_csize // 0)
    | if   . > 1073741824 then "\(. / 1073741824 * 10 | floor / 10) GB"
      elif . > 1048576    then "\(. / 1048576 | floor) MB"
      else                     "\(. / 1024 | floor) KB"
      end
  ' 2>/dev/null || echo "unbekannt"
}

if [[ ! -f /root/.borg_passphrase ]]; then
  echo "❌ /root/.borg_passphrase nicht gefunden!"; exit 1
fi

(
  flock -n 9 || { log "⚠️  Borg Check läuft bereits. Abbruch."; exit 0; }
  export BORG_PASSCOMMAND="cat /root/.borg_passphrase"

  log "=== Starte Borg Repository Check ==="
  START_TIME=\$(date +%s)

  if borg check --verify-data "\${BORG_REPO}" 2>&1 | tee -a "\$LOG_FILE"; then
    END_TIME=\$(date +%s)
    DURATION=\$(( END_TIME - START_TIME ))
    ARCHIVE_COUNT=\$(borg list "\${BORG_REPO}" 2>/dev/null | wc -l || echo "?")
    REPO_SIZE=\$(borg_repo_size "\${BORG_REPO}")
    log "✅ Borg Check OK (\${DURATION}s)"
    send_telegram "✅ Borg Repository Check
🔍 Status: OK – keine Fehler
📦 Archive: \${ARCHIVE_COUNT}
💾 Repo-Größe: \${REPO_SIZE}
⏱ Dauer: \${DURATION}s"
  else
    log "❌ Borg Check fehlgeschlagen!"
    send_telegram "❌ Borg Check FEHLGESCHLAGEN
⚠️ Repository könnte beschädigt sein!
🔢 Exit-Code: 11
📋 Log: cat ${BORG_CHECK_LOG}"
    exit 11
  fi
) 9>/var/lock/paperless-borgcheck.lock
BORGCHECK
  chmod 755 "${SCRIPT_DIR}/paperless-borg-check.sh"
  echo "   ✅ ${SCRIPT_DIR}/paperless-borg-check.sh"

  # ── Restore Test Script ─────────────────────
  cat > "${SCRIPT_DIR}/paperless-restore-test.sh" <<RESTORETEST
#!/bin/bash
set -euo pipefail
source /etc/paperless-backup.conf
LOG_FILE="${RESTORE_TEST_LOG}"
TEST_DIR="/backup/restore-test/\$(date +%Y%m%d-%H%M%S)"

log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*" | tee -a "\$LOG_FILE"; }

send_telegram() {
  local message="\$1"
  jq -n \
    --arg cid  "\${TELEGRAM_CHAT_ID}" \
    --arg text "\$message" \
    '{"chat_id":$cid,"text":$text,"parse_mode":"HTML"}' | \
  curl -s --max-time 10 --connect-timeout 5 \
    -X POST "https://api.telegram.org/bot\${TELEGRAM_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    --data-binary @- > /dev/null
}

if [[ ! -f /root/.borg_passphrase ]]; then
  echo "❌ /root/.borg_passphrase nicht gefunden!"
  echo "   Bitte Passphrase nach /root/.borg_passphrase schreiben (chmod 600)"
  exit 1
fi

(
  flock -n 9 || { log "⚠️  Restore-Test läuft bereits. Abbruch."; exit 0; }
  export BORG_PASSCOMMAND="cat /root/.borg_passphrase"

  mkdir -p "\${TEST_DIR}"
  # K1(alt)-Fix: trap innerhalb der Subshell, nach mkdir
  # Guard [[ -n TEST_DIR ]] verhindert rm -rf ""
  trap '[[ -n "\${TEST_DIR:-}" ]] && { log "Räume \${TEST_DIR} auf..."; rm -rf "\${TEST_DIR}"; }' EXIT

  log "=== Starte Restore Dry-Run Test ==="
  START_TIME=\$(date +%s)
  ERRORS=()

  LATEST_ARCHIVE=\$(borg list --short "\${BORG_REPO}" 2>/dev/null | tail -1)
  if [[ -z "\$LATEST_ARCHIVE" ]]; then
    log "❌ Kein Archiv gefunden!"
    send_telegram "❌ Restore-Test FEHLGESCHLAGEN
❌ Kein Borg-Archiv gefunden!
🔢 Exit-Code: 14"
    exit 14
  fi
  log "Teste Archiv: \${LATEST_ARCHIVE}"

  # cd nach trap – bei Fehler wird trap sauber ausgelöst und TEST_DIR bereinigt
  cd "\$TEST_DIR" || { log "❌ cd \${TEST_DIR} fehlgeschlagen – Abbruch"; exit 1; }
  log "Extrahiere nach \${TEST_DIR}..."
  # M3-Fix: if/else statt || – zuverlässig unter set -euo pipefail
  if ! borg extract "\${BORG_REPO}::\${LATEST_ARCHIVE}" 2>&1 | tee -a "\$LOG_FILE"; then
    ERRORS+=("Borg-Extraktion fehlgeschlagen")
  fi

  EXTRACTED_MEDIA="\${TEST_DIR}\$(echo \${MEDIA_DIR} | sed 's|^/||')"
  MEDIA_COUNT=0
  if [[ -d "\$EXTRACTED_MEDIA" ]]; then
    MEDIA_COUNT=\$(find "\$EXTRACTED_MEDIA" -type f | wc -l)
    log "✅ Media OK (\${MEDIA_COUNT} Dateien)"
  else
    ERRORS+=("Media-Verzeichnis fehlt"); log "❌ Media fehlt!"
  fi

  EXTRACTED_DATA="\${TEST_DIR}\$(echo \${DATA_DIR} | sed 's|^/||')"
  if [[ -d "\$EXTRACTED_DATA" ]]; then
    log "✅ Data-Verzeichnis OK"
  else
    ERRORS+=("Data-Verzeichnis fehlt"); log "❌ Data fehlt!"
  fi

  EXTRACTED_COMPOSE="\${TEST_DIR}\$(echo \${COMPOSE_FILE} | sed 's|^/||')"
  if [[ -f "\$EXTRACTED_COMPOSE" ]]; then
    log "✅ docker-compose.yml vorhanden"
  else
    ERRORS+=("docker-compose.yml fehlt"); log "❌ docker-compose.yml fehlt!"
  fi

  EXTRACTED_DB="\${TEST_DIR}/backup/paperless-tmp/paperless-db.sql"
  if [[ -f "\$EXTRACTED_DB" ]]; then
    DB_SIZE=\$(du -sh "\$EXTRACTED_DB" | cut -f1)
    if head -5 "\$EXTRACTED_DB" | grep -q "PostgreSQL\|pg_dump"; then
      log "✅ PostgreSQL-Dump OK (\${DB_SIZE})"
    else
      ERRORS+=("PostgreSQL-Dump Header ungültig"); log "❌ DB-Dump Header ungültig!"
    fi
  else
    ERRORS+=("PostgreSQL-Dump fehlt"); log "❌ DB-Dump fehlt!"
  fi

  END_TIME=\$(date +%s)
  DURATION=\$(( END_TIME - START_TIME ))

  if [[ \${#ERRORS[@]} -eq 0 ]]; then
    log "✅ Restore-Test erfolgreich (\${DURATION}s)"
    send_telegram "✅ Restore Dry-Run Test erfolgreich
🗄 Archiv: \${LATEST_ARCHIVE}
📂 Media: \${MEDIA_COUNT} Dateien ✅
📁 Data-Verzeichnis: ✅
📄 docker-compose.yml: ✅
🗃 PostgreSQL-Dump: ✅
⏱ Dauer: \${DURATION}s
💡 Ein echter Restore wäre möglich."
  else
    ERROR_LIST=\$(printf '❌ %s\n' "\${ERRORS[@]}")
    log "❌ \${#ERRORS[@]} Fehler gefunden!"
    send_telegram "❌ Restore-Test FEHLGESCHLAGEN
🗄 Archiv: \${LATEST_ARCHIVE}
⚠️ \${#ERRORS[@]} Fehler:
\${ERROR_LIST}
🔢 Exit-Code: 14
📋 Log: cat ${RESTORE_TEST_LOG}"
    exit 14
  fi
) 9>/var/lock/paperless-restore-test.lock
RESTORETEST
  chmod 755 "${SCRIPT_DIR}/paperless-restore-test.sh"
  echo "   ✅ ${SCRIPT_DIR}/paperless-restore-test.sh"
}

# ─────────────────────────────────────────────
# SYSTEMD EINRICHTEN
# ─────────────────────────────────────────────

setup_systemd() {
  [[ "${_SETUP_VARS_LOADED:-0}" -eq 1 ]] || load_conf
  validate_conf
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
StandardOutput=journal
StandardError=journal
EOF
    cat > "/etc/systemd/system/${NAME}.timer" <<EOF
[Unit]
Description=Timer für ${DESCRIPTION}

[Timer]
OnCalendar=${SCHEDULE}
Persistent=true

[Install]
WantedBy=timers.target
EOF
  }

  local HOUR=2 MINUTE=0
  local REMOTE_NAME SAFE_NAME SCHEDULE
  for target in "${BACKUP_TARGETS[@]}"; do
    REMOTE_NAME="${target%%:*}"
    SAFE_NAME=$(sanitize_remote_name "$REMOTE_NAME")
    SCHEDULE=$(printf "*-*-* %02d:%02d:00" $HOUR $MINUTE)
    create_service_timer \
      "paperless-backup-${SAFE_NAME}" \
      "${SCRIPT_DIR}/paperless-backup-${SAFE_NAME}.sh" \
      "Paperless Backup → ${target}" \
      "$SCHEDULE"
    echo "   ✅ paperless-backup-${SAFE_NAME}.timer (${SCHEDULE})"
    MINUTE=$(( MINUTE + 30 ))
    if [[ $MINUTE -ge 60 ]]; then MINUTE=0; HOUR=$(( HOUR + 1 )); fi
  done

  local CHECK_HOUR=$(( (HOUR + 1) % 24 ))
  create_service_timer \
    "paperless-borg-check" \
    "${SCRIPT_DIR}/paperless-borg-check.sh" \
    "Wöchentlicher Borg Repository Check" \
    "Sun *-*-* $(printf '%02d' $CHECK_HOUR):00:00"
  echo "   ✅ paperless-borg-check.timer (Sonntag $(printf '%02d' $CHECK_HOUR):00)"

  local TEST_HOUR=$(( (CHECK_HOUR + 1) % 24 ))
  create_service_timer \
    "paperless-restore-test" \
    "${SCRIPT_DIR}/paperless-restore-test.sh" \
    "Wöchentlicher Restore Dry-Run Test" \
    "Sun *-*-* $(printf '%02d' $TEST_HOUR):00:00"
  echo "   ✅ paperless-restore-test.timer (Sonntag $(printf '%02d' $TEST_HOUR):00)"

  systemctl daemon-reload
  for service_file in /etc/systemd/system/paperless-backup-*.timer \
                      /etc/systemd/system/paperless-borg-check.timer \
                      /etc/systemd/system/paperless-restore-test.timer; do
    [[ -f "$service_file" ]] || continue
    systemctl enable --now "$(basename "$service_file")"
  done
  echo "   ✅ Alle Timer aktiviert"
}

# ─────────────────────────────────────────────
# RESTORE
# ─────────────────────────────────────────────

run_restore() {
  load_conf
  validate_conf
  check_passphrase
  # N1-Info: BORG_PASSCOMMAND im äußeren Prozess – interaktiv, kein flock nötig
  export BORG_PASSCOMMAND="cat /root/.borg_passphrase"

  echo "╔══════════════════════════════════════╗"
  echo "║     Paperless Restore                ║"
  echo "╚══════════════════════════════════════╝"
  echo ""
  echo "☁️  Von welchem Cloud-Ziel wiederherstellen?"
  for i in "${!BACKUP_TARGETS[@]}"; do
    echo "  $((i+1))) ${BACKUP_TARGETS[$i]}"
  done
  local target_idx
  prompt_int "Auswahl: " 1 "${#BACKUP_TARGETS[@]}" target_idx
  local SELECTED_TARGET="${BACKUP_TARGETS[$((target_idx-1))]}"
  local REMOTE_NAME="${SELECTED_TARGET%%:*}"
  local REMOTE_PATH="${SELECTED_TARGET#*:}"

  echo ""
  echo "📥 Lade Borg-Repository von ${SELECTED_TARGET}..."
  local rclone_opts=(
    --progress
    --transfers "${RCLONE_TRANSFERS:-4}"
    --checkers  "${RCLONE_CHECKERS:-8}"
  )
  [[ -n "${RCLONE_BWLIMIT:-}" ]] && rclone_opts+=(--bwlimit "${RCLONE_BWLIMIT}")
  rclone sync "${REMOTE_NAME}:${REMOTE_PATH}" "${BORG_REPO}" "${rclone_opts[@]}"

  echo ""
  echo "📋 Verfügbare Archive:"
  borg list "${BORG_REPO}"
  echo ""
  read -rp "Archiv-Name eingeben: " ARCHIVE_NAME

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
    read -rp "Ziel-Basisverzeichnis (z.B. /tmp/paperless-staging): " TARGET_PREFIX
    # B2-Fix: mkdir-Fehler mit klarer Meldung abfangen statt stummen set -e Abbruch
    mkdir -p "$TARGET_PREFIX" || {
      echo "❌ Konnte Zielverzeichnis nicht erstellen: ${TARGET_PREFIX}"
      echo "   Bitte Pfad und Berechtigungen prüfen."
      exit 1
    }
    restore_type="1"
    echo "   Restore nach: ${TARGET_PREFIX}"
  fi

  echo ""
  echo "⚠️  ACHTUNG: Daten werden nach ${TARGET_PREFIX} wiederhergestellt!"
  read -rp "Fortfahren? (ja/nein): " confirm
  [[ "$confirm" != "ja" ]] && { echo "Abgebrochen."; exit 0; }

  cd "$TARGET_PREFIX"

  if [[ "$restore_type" == "1" || "$restore_type" == "3" ]]; then
    echo "📂 Stelle Media wieder her..."
    borg extract "${BORG_REPO}::${ARCHIVE_NAME}" \
      "${MEDIA_DIR#/}" || {
        send_telegram "❌ Restore fehlgeschlagen
🔴 [MEDIA] borg extract
🔢 Exit-Code: ${EXIT_RESTORE}"
        exit $EXIT_RESTORE
      }
    echo "   ✅ Media wiederhergestellt"
  fi

  if [[ "$restore_type" == "1" || "$restore_type" == "4" ]]; then
    echo "📂 Stelle Data wieder her..."
    borg extract "${BORG_REPO}::${ARCHIVE_NAME}" \
      "${DATA_DIR#/}" || {
        send_telegram "❌ Restore fehlgeschlagen
🔴 [DATA] borg extract
🔢 Exit-Code: ${EXIT_RESTORE}"
        exit $EXIT_RESTORE
      }
    echo "   ✅ Data wiederhergestellt"
  fi

  if [[ "$restore_type" == "1" ]]; then
    echo "📄 Stelle docker-compose.yml wieder her..."
    borg extract "${BORG_REPO}::${ARCHIVE_NAME}" \
      "${COMPOSE_FILE#/}" || {
        echo "⚠️  docker-compose.yml konnte nicht wiederhergestellt werden"
      }
    echo "   ✅ docker-compose.yml wiederhergestellt"
  fi

  if [[ "$restore_type" == "1" || "$restore_type" == "2" ]]; then
    echo "🗃️  Stelle Datenbank wieder her..."
    # N2-Fix: Hinweis direkt hier sichtbar für den Operator.
    # Das SQL enthält DROP/CREATE via --clean --if-exists (aus pg_dump).
    # Bei schwerer DB-Korruption: Container stoppen, manuell
    # DROP DATABASE / CREATE DATABASE durchführen, dann erneut restore.
    borg extract --stdout "${BORG_REPO}::${ARCHIVE_NAME}" \
      backup/paperless-tmp/paperless-db.sql | \
      docker exec -i "${DB_CONTAINER}" psql -U "${DB_USER}" "${DB_NAME}" || {
        send_telegram "❌ Restore fehlgeschlagen
🔴 [DB] pg_restore
🔢 Exit-Code: ${EXIT_RESTORE}"
        exit $EXIT_RESTORE
      }
    echo "   ✅ Datenbank wiederhergestellt"
  fi

  if [[ "$restore_type" == "1" && "$TARGET_PREFIX" == "/" ]]; then
    echo ""
    echo "🚀 Starte Paperless..."
    docker compose -f "$COMPOSE_FILE" up -d
  fi

  echo ""
  echo "✅ Restore abgeschlossen!"
  send_telegram "✅ Paperless Restore abgeschlossen
🗄 Archiv: ${ARCHIVE_NAME}
☁️ Quelle: ${SELECTED_TARGET}
📍 Ziel: ${TARGET_PREFIX}"
}

# ─────────────────────────────────────────────
# KONFIG CHECK
# ─────────────────────────────────────────────

run_config_check() {
  load_conf
  validate_conf
  check_passphrase
  export BORG_PASSCOMMAND="cat /root/.borg_passphrase"

  echo "╔══════════════════════════════════════╗"
  echo "║     Paperless Konfig-Check           ║"
  echo "╚══════════════════════════════════════╝"
  echo ""

  local ERRORS=0
  check_ok()   { echo "   ✅ $*"; }
  check_fail() { echo "   ❌ $*"; ERRORS=$(( ERRORS + 1 )); }
  check_info() { echo "   ℹ️  $*"; }

  echo "🐳 Docker Container:"
  if docker ps --format '{{.Names}}' | grep -q "^${PAPERLESS_CONTAINER}$"; then
    check_ok "Paperless Container läuft: ${PAPERLESS_CONTAINER}"
  else
    check_fail "Paperless Container nicht gefunden: ${PAPERLESS_CONTAINER}"
  fi
  if docker ps --format '{{.Names}}' | grep -q "^${DB_CONTAINER}$"; then
    check_ok "DB Container läuft: ${DB_CONTAINER}"
  else
    check_fail "DB Container nicht gefunden: ${DB_CONTAINER}"
  fi

  echo ""
  echo "☁️  rclone Remotes:"
  local REMOTE_NAME
  for target in "${BACKUP_TARGETS[@]}"; do
    REMOTE_NAME="${target%%:*}"
    if rclone listremotes | grep -q "^${REMOTE_NAME}:$"; then
      check_ok "Remote vorhanden: ${REMOTE_NAME}"
    else
      check_fail "Remote fehlt: ${REMOTE_NAME}"
    fi
  done

  echo ""
  echo "🔒 Borg Repository:"
  if borg info "${BORG_REPO}" > /dev/null 2>&1; then
    check_ok "Repository erreichbar: ${BORG_REPO}"
  else
    check_fail "Repository nicht erreichbar: ${BORG_REPO}"
  fi
  if [[ -w "${BORG_REPO}" ]]; then
    check_ok "Schreibrechte auf ${BORG_REPO}"
  else
    check_fail "Keine Schreibrechte auf ${BORG_REPO}"
  fi

  echo ""
  echo "📂 Pfade:"
  if [[ -d "${MEDIA_DIR}" ]]; then
    check_ok "Media-Verzeichnis: ${MEDIA_DIR}"
  else
    check_fail "Media-Verzeichnis fehlt: ${MEDIA_DIR}"
  fi
  if [[ -d "${DATA_DIR}" ]]; then
    check_ok "Data-Verzeichnis: ${DATA_DIR}"
  else
    check_fail "Data-Verzeichnis fehlt: ${DATA_DIR}"
  fi
  if [[ -f "${COMPOSE_FILE}" ]]; then
    check_ok "docker-compose.yml: ${COMPOSE_FILE}"
  else
    check_fail "docker-compose.yml fehlt: ${COMPOSE_FILE}"
  fi
  if [[ -w "${BACKUP_TMP}" ]]; then
    check_ok "Schreibrechte auf ${BACKUP_TMP}"
  else
    check_fail "Keine Schreibrechte auf ${BACKUP_TMP}"
  fi

  echo ""
  echo "📦 Versionen:"
  check_info "$(borg --version)"
  check_info "$(rclone --version | head -1)"
  check_info "$(docker --version)"
  check_info "jq $(jq --version)"

  echo ""
  if [[ $ERRORS -eq 0 ]]; then
    echo "✅ Alle Checks bestanden – System bereit."
  else
    echo "❌ ${ERRORS} Check(s) fehlgeschlagen – bitte beheben!"
    exit 1
  fi
}

# ─────────────────────────────────────────────
# TEST
# ─────────────────────────────────────────────

run_test() {
  load_conf
  validate_conf

  echo ""
  echo "🧪 Test auswählen:"
  local idx=1
  for target in "${BACKUP_TARGETS[@]}"; do
    echo "  ${idx}) Backup → ${target}"
    idx=$(( idx + 1 ))
  done
  echo "  ${idx}) Backup Dry-Run (Ziel auswählen)"
  local DRYRUN_IDX=$idx; idx=$(( idx + 1 ))
  echo "  ${idx}) Borg Check"
  local BORGCHECK_IDX=$idx; idx=$(( idx + 1 ))
  echo "  ${idx}) Restore Dry-Run Test"
  local RESTORETEST_IDX=$idx
  local MAX_IDX=$idx

  local choice
  prompt_int "Auswahl: " 1 "$MAX_IDX" choice

  local REMOTE_NAME SAFE_NAME
  if (( choice <= ${#BACKUP_TARGETS[@]} )); then
    REMOTE_NAME="${BACKUP_TARGETS[$((choice-1))]%%:*}"
    SAFE_NAME=$(sanitize_remote_name "$REMOTE_NAME")
    bash "${SCRIPT_DIR}/paperless-backup-${SAFE_NAME}.sh"
  elif [[ "$choice" -eq "$DRYRUN_IDX" ]]; then
    echo ""
    echo "Dry-Run für welches Ziel?"
    for i in "${!BACKUP_TARGETS[@]}"; do
      echo "  $((i+1))) ${BACKUP_TARGETS[$i]}"
    done
    local dry_idx
    prompt_int "Auswahl: " 1 "${#BACKUP_TARGETS[@]}" dry_idx
    local DRY_TARGET="${BACKUP_TARGETS[$((dry_idx-1))]}"
    # M2(neu)-Fix: LOG_FILE exportieren – stellt sicher dass run_backup den
    # richtigen Wert nutzt, auch wenn source "$LIB_FILE" ihn neu setzt
    export LOG_FILE
    # shellcheck source=/dev/null
    source "$LIB_FILE"
    run_backup "$DRY_TARGET" "true"
  elif [[ "$choice" -eq "$BORGCHECK_IDX" ]]; then
    bash "${SCRIPT_DIR}/paperless-borg-check.sh"
  elif [[ "$choice" -eq "$RESTORETEST_IDX" ]]; then
    bash "${SCRIPT_DIR}/paperless-restore-test.sh"
  fi
}

# ─────────────────────────────────────────────
# STATUS
# ─────────────────────────────────────────────

run_status() {
  load_conf
  validate_conf
  check_passphrase
  export BORG_PASSCOMMAND="cat /root/.borg_passphrase"

  echo "╔══════════════════════════════════════╗"
  echo "║     Paperless Backup Status          ║"
  echo "╚══════════════════════════════════════╝"

  echo ""
  echo "🐳 Docker Container:"
  docker ps --format "table {{.Names}}\t{{.Status}}" \
    | grep -iE "paperless|redis|tika|gotenberg" || echo "   (keine gefunden)"

  echo ""
  echo "⏰ Systemd Timer:"
  systemctl list-timers --no-pager | grep paperless || echo "   (keine aktiven Timer)"

  echo ""
  echo "📦 Borg Archive (letzte 5):"
  borg list "${BORG_REPO}" 2>/dev/null | tail -5 || echo "   (nicht verfügbar)"

  echo ""
  echo "💾 Repository Größe: $(borg_repo_size "${BORG_REPO}")"

  echo ""
  echo "☁️  Cloud-Ziele:"
  for target in "${BACKUP_TARGETS[@]}"; do
    echo "   • ${target}"
  done

  echo ""
  echo "📋 Letzte Backup-Logs:"
  tail -5 "$LOG_FILE" 2>/dev/null || echo "   (keine Logs)"

  echo ""
  echo "📋 Letzter Borg Check:"
  tail -3 "$BORG_CHECK_LOG" 2>/dev/null || echo "   (noch kein Check gelaufen)"

  echo ""
  echo "📋 Letzter Restore-Test:"
  tail -3 "$RESTORE_TEST_LOG" 2>/dev/null || echo "   (noch kein Test gelaufen)"
}

# ─────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  ██████╗  █████╗ ██████╗  ██████╗               ║"
echo "║  ██╔══██╗██╔══██╗██╔══██╗██╔═══██╗              ║"
echo "║  ██████╔╝███████║██████╔╝██║   ██║              ║"
echo "║  ██╔═══╝ ██╔══██║██╔══██╗██║   ██║              ║"
echo "║  ██║     ██║  ██║██████╔╝╚██████╔╝              ║"
echo "║  ╚═╝     ╚═╝  ╚═╝╚═════╝  ╚═════╝  v1.0        ║"
echo "║  Paperless-Borg Backup Orchestrator              ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "  1) setup        – Ersteinrichtung / Ziele ändern"
echo "  2) restore      – Daten wiederherstellen"
echo "  3) test         – Manuellen Test starten"
echo "  4) status       – System-Status anzeigen"
echo "  5) config-check – Konfiguration prüfen"
echo ""
read -rp "Aktion wählen (1-5): " action

case "$action" in
  1|setup)        run_setup ;;
  2|restore)      run_restore ;;
  3|test)         run_test ;;
  4|status)       run_status ;;
  5|config-check) run_config_check ;;
  *) echo "Ungültige Auswahl." ; exit 1 ;;
esac
