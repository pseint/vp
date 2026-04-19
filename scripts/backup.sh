#!/usr/bin/env bash
# =============================================================
# BACKUP AUTOMÁTICO v6 — DB + Archivos + Config + Offsite (rclone)
# Uso: ./scripts/backup.sh [full|db|files|config] [--offsite]
# Offsite: configurar rclone con: rclone config
# =============================================================
set -euo pipefail

BACKUP_TYPE="${1:-full}"
OFFSITE="${2:-}"
INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
[[ -f "$INSTALL_DIR/.env" ]] && source "$INSTALL_DIR/.env"

BACKUP_DIR="${BACKUP_DIR:-/opt/hosting/data/backups}"
RETENTION="${BACKUP_RETENTION_DAYS:-7}"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="${BACKUP_DIR}/${DATE}"
LOG_FILE="${INSTALL_DIR}/logs/backup/backup.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "[$(date '+%F %T')] ${GREEN}[OK]${NC}  $1" | tee -a "$LOG_FILE"; }
warn()  { echo -e "[$(date '+%F %T')] ${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
error() { 
  echo -e "[$(date '+%F %T')] ${RED}[ERR]${NC}  $1" | tee -a "$LOG_FILE"
  send_alert "❌ ERROR en backup de $(hostname -s): $1"
  exit 1
}

mkdir -p "${BACKUP_PATH}"/{db,files,config} "$(dirname "$LOG_FILE")"

# ── Alerta Telegram ───────────────────────────────────────────
send_alert() {
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || return 0
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" -d "text=$1" > /dev/null 2>&1 || true
}

# BUG FIX v14: trap registrado DESPUÉS de send_alert para que la función exista
# cuando el handler se dispare (bash resuelve nombres de función al momento de ejecución,
# pero registrar el trap antes de la definición es un antipatrón que confunde)
trap 'send_alert "💀 Backup interrumpido en $(hostname -s) — revisar logs"' ERR

# ── Backup de Bases de Datos ──────────────────────────────────
backup_databases() {
  log "Iniciando backup de bases de datos..."

  # Verificar que MariaDB esté healthy antes de intentar el dump
  local retries=0
  while [[ $retries -lt 12 ]]; do
    if docker exec mariadb healthcheck.sh --connect --innodb_initialized &>/dev/null 2>&1; then
      break
    fi
    warn "MariaDB aún no está lista (intento $((retries+1))/12) — esperando 5s..."
    sleep 5
    ((retries++)) || true
  done
  if [[ $retries -eq 12 ]]; then
    error "MariaDB no responde después de 60s — abortando backup de BD"
  fi

  DATABASES=$(docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb \
    -uroot \
    --batch --skip-column-names \
    -e "SHOW DATABASES WHERE \`Database\` NOT IN ('information_schema','performance_schema','mysql','sys');" \
    2>/dev/null)

  local count=0
  while IFS= read -r db; do
    [[ -z "$db" ]] && continue
    local dump_file="${BACKUP_PATH}/db/${db}.sql.gz"
    # FIX v19: MYSQL_PWD evita que la contraseña aparezca en ps aux
    docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb-dump \
      -uroot \
      --single-transaction \
      --routines \
      --triggers \
      --events \
      --add-drop-database \
      --databases \
      "$db" 2>/dev/null | gzip -9 > "$dump_file"
    local size; size=$(du -sh "$dump_file" | cut -f1)
    log "  DB: $db → ($size)"
    ((count++))
  done <<< "$DATABASES"
  log "Backup completado: $count bases de datos"
}

# ── Backup de Archivos ────────────────────────────────────────
backup_files() {
  log "Iniciando backup de archivos web..."
  local SITES_VOL
  SITES_VOL=$(docker volume inspect hosting_sites-data \
    --format '{{.Mountpoint}}' 2>/dev/null || echo "/var/lib/docker/volumes/hosting_sites-data/_data")

  if [[ -d "$SITES_VOL" ]]; then
    tar -czf "${BACKUP_PATH}/files/sites.tar.gz" \
      -C "$(dirname "$SITES_VOL")" \
      "$(basename "$SITES_VOL")" \
      2>/dev/null
    local size; size=$(du -sh "${BACKUP_PATH}/files/sites.tar.gz" | cut -f1)
    log "Archivos comprimidos: ($size)"
  else
    warn "Volumen de sitios no encontrado"
  fi

  # FIX v16: Backup de volúmenes de servicio (sftpgo-data + portainer-data)
  for vol_name in sftpgo-data portainer-data; do
    local VOL_PATH
    VOL_PATH=$(docker volume inspect "hosting_${vol_name}" \
      --format '{{.Mountpoint}}' 2>/dev/null || echo "")
    if [[ -n "$VOL_PATH" && -d "$VOL_PATH" ]]; then
      tar -czf "${BACKUP_PATH}/files/${vol_name}.tar.gz" \
        -C "$(dirname "$VOL_PATH")" \
        "$(basename "$VOL_PATH")" \
        2>/dev/null
      local vol_size; vol_size=$(du -sh "${BACKUP_PATH}/files/${vol_name}.tar.gz" | cut -f1)
      log "  Volumen ${vol_name} → (${vol_size})"
    else
      warn "Volumen ${vol_name} no encontrado — omitiendo"
    fi
  done
}

# ── Backup de Configuración ───────────────────────────────────
backup_config() {
  log "Iniciando backup de configuración..."
  tar -czf "${BACKUP_PATH}/config/hosting-config.tar.gz" \
    -C "$INSTALL_DIR" \
    --exclude='./data' \
    --exclude='./logs' \
    --exclude='./.env' \
    . 2>/dev/null

  if [[ -f "$INSTALL_DIR/.env" ]]; then
    openssl enc -aes-256-cbc -salt -pbkdf2 \
      -in "$INSTALL_DIR/.env" \
      -out "${BACKUP_PATH}/config/.env.enc" \
      -k "${DB_ROOT_PASS}" 2>/dev/null
    log ".env guardado cifrado"
  fi

  # Certificados SSL
  local ACME_VOL
  ACME_VOL=$(docker volume inspect hosting_traefik-acme \
    --format '{{.Mountpoint}}' 2>/dev/null || echo "")
  if [[ -n "$ACME_VOL" && -d "$ACME_VOL" ]]; then
    cp -r "$ACME_VOL" "${BACKUP_PATH}/config/acme/"
    log "Certificados SSL respaldados"
  fi
}

# ── Backup Offsite con rclone ─────────────────────────────────
backup_offsite() {
  # Requiere: rclone configurado con: rclone config
  # Variables en .env: RCLONE_REMOTE (ej: "s3:mi-bucket/hosting")
  #                    o RCLONE_REMOTE="gdrive:backups/hosting"
  if [[ -z "${RCLONE_REMOTE:-}" ]]; then
    warn "RCLONE_REMOTE no configurado en .env — omitiendo backup offsite"
    warn "  Configura: rclone config → añade S3/GDrive/Backblaze/etc."
    warn "  Luego añade RCLONE_REMOTE=nombre:bucket/path en .env"
    return 0
  fi

  if ! command -v rclone &>/dev/null; then
    warn "rclone no instalado — omitiendo backup offsite"
    return 0
  fi

  log "Subiendo backup a remoto: ${RCLONE_REMOTE}..."
  rclone copy "${BACKUP_PATH}" "${RCLONE_REMOTE}/${DATE}/" \
    --transfers 4 \
    --checkers 8 \
    --contimeout 60s \
    --timeout 300s \
    --retries 3 \
    --log-level NOTICE 2>> "$LOG_FILE" && \
    log "Backup offsite completado: ${RCLONE_REMOTE}/${DATE}/" || \
    warn "Backup offsite falló — revisa logs y configuración de rclone"

  # FIX v19: rclone delete --min-age eliminaba TODO el contenido del bucket/carpeta más viejo que N días,
  # incluyendo backups de otras apps y rutas que no son de esta instalación. BUG DE PÉRDIDA DE DATOS.
  # Solución correcta: listar solo las subcarpetas con nombre de fecha (formato YYYYMMDD_HHMMSS),
  # calcular las que superan la retención, y purgar solo esas.
  local cutoff_epoch
  cutoff_epoch=$(date -d "-${RETENTION} days" +%s 2>/dev/null || \
                 python3 -c "import time; print(int(time.time() - ${RETENTION}*86400))")

  local old_folders
  old_folders=$(rclone lsf "${RCLONE_REMOTE}/" --dirs-only 2>/dev/null | \
    grep -E '^[0-9]{8}_[0-9]{6}/$' | sed 's|/$||') || true

  local pruned=0
  while IFS= read -r folder; do
    [[ -z "$folder" ]] && continue
    # Parsear timestamp de nombre de carpeta: YYYYMMDD_HHMMSS
    local folder_epoch
    folder_epoch=$(date -d "${folder:0:8} ${folder:9:2}:${folder:11:2}:${folder:13:2}" +%s 2>/dev/null || \
                   python3 -c "import time,datetime; \
                     t=datetime.datetime(int('${folder:0:4}'),int('${folder:4:2}'),int('${folder:6:2}'),\
                       int('${folder:9:2}'),int('${folder:11:2}'),int('${folder:13:2}')); \
                     print(int(t.timestamp()))" 2>/dev/null || echo "0")
    if [[ "$folder_epoch" -lt "$cutoff_epoch" ]]; then
      rclone purge "${RCLONE_REMOTE}/${folder}" 2>/dev/null && \
        log "  Backup offsite antiguo eliminado: ${folder}" || \
        warn "  No se pudo eliminar: ${RCLONE_REMOTE}/${folder}"
      ((pruned++)) || true
    fi
  done <<< "$old_folders"

  [[ "$pruned" -gt 0 ]] && log "Backups offsite viejos eliminados: ${pruned}" || \
    log "No hay backups offsite que superen la retención de ${RETENTION} días"
}

# ── Limpieza local ────────────────────────────────────────────
cleanup_old_backups() {
  log "Limpiando backups locales de más de ${RETENTION} días..."
  find "${BACKUP_DIR}" -maxdepth 1 -type d -mtime "+${RETENTION}" -exec rm -rf {} + 2>/dev/null || true
  local remaining; remaining=$(find "${BACKUP_DIR}" -maxdepth 1 -type d | wc -l)
  log "Backups locales restantes: $((remaining - 1))"
}

# ── Resumen ───────────────────────────────────────────────────
print_summary() {
  local total_size; total_size=$(du -sh "${BACKUP_PATH}" | cut -f1)
  log "══════════════════════════════════════"
  log "BACKUP COMPLETADO: ${DATE}"
  log "Ubicación local: ${BACKUP_PATH} (${total_size})"
  [[ -n "${RCLONE_REMOTE:-}" ]] && log "Offsite: ${RCLONE_REMOTE}/${DATE}/"
  log "Retención: ${RETENTION} días"
  log "══════════════════════════════════════"
  send_alert "✅ Backup completado (${total_size}) — $(hostname -s)"
}

# ── Ejecución ─────────────────────────────────────────────────
case "$BACKUP_TYPE" in
  db)     backup_databases ;;
  files)  backup_files ;;
  config) backup_config ;;
  full|*)
    backup_databases
    backup_files
    backup_config
    ;;
esac

# Offsite: si se pide explícitamente o si es full y hay RCLONE_REMOTE
if [[ "$OFFSITE" == "--offsite" ]] || \
   [[ "$BACKUP_TYPE" == "full" && -n "${RCLONE_REMOTE:-}" ]]; then
  backup_offsite
fi

cleanup_old_backups
print_summary
