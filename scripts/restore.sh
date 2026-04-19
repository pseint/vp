#!/usr/bin/env bash
# =============================================================
# RESTORE — Restauración de backups (DB + archivos + config)
# Uso: ./scripts/restore.sh [ruta-backup] [--db|--files|--config|--all]
# Ejemplo: ./scripts/restore.sh /opt/hosting/data/backups/20250101_030000 --all
# =============================================================
set -euo pipefail

BACKUP_PATH="${1:-}"
MODE="${2:---all}"
INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
[[ -f "$INSTALL_DIR/.env" ]] && source "$INSTALL_DIR/.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()    { echo -e "[$(date '+%F %T')] ${GREEN}[OK]${NC}  $1"; }
warn()   { echo -e "[$(date '+%F %T')] ${YELLOW}[⚠]${NC}   $1"; }
error()  { echo -e "[$(date '+%F %T')] ${RED}[ERR]${NC} $1"; exit 1; }
info()   { echo -e "[$(date '+%F %T')] ${CYAN}[→]${NC}  $1"; }
header() { echo -e "\n${BOLD}${CYAN}══ $1 ══${NC}"; }

# ── Validaciones ──────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "Ejecutar como root: sudo bash scripts/restore.sh"
[[ -z "$BACKUP_PATH" ]] && {
  echo -e "${YELLOW}Uso:${NC} $0 <ruta-backup> [--db|--files|--config|--all]"
  echo ""
  echo "Backups disponibles:"
  ls -lt "${BACKUP_DIR:-/opt/hosting/data/backups}" 2>/dev/null | \
    awk 'NR>1 && /^d/ {print "  " $9}' | head -10
  exit 1
}
[[ -d "$BACKUP_PATH" ]] || error "Directorio de backup no encontrado: $BACKUP_PATH"

echo -e "\n${BOLD}${YELLOW}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${YELLOW}║      RESTAURACIÓN DE BACKUP               ║${NC}"
echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════╝${NC}"
echo -e "  Backup:  ${BACKUP_PATH}"
echo -e "  Modo:    ${MODE}"
echo ""
warn "ESTA OPERACIÓN SOBREESCRIBIRÁ DATOS ACTUALES"
read -rp "¿Confirmar restauración? [s/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }

# ── Restaurar bases de datos ──────────────────────────────────
restore_databases() {
  header "Restaurando bases de datos"
  local DB_DIR="${BACKUP_PATH}/db"
  [[ -d "$DB_DIR" ]] || { warn "Directorio db/ no encontrado en backup"; return; }

  local count=0
  for dump_file in "${DB_DIR}"/*.sql.gz; do
    [[ -f "$dump_file" ]] || continue
    local db_name
    db_name=$(basename "$dump_file" .sql.gz)
    info "Restaurando: ${db_name}..."

    # Restaurar dump
    # BUG FIX v19: el dump fue creado con --databases --add-drop-database,
    # por lo que contiene DROP/CREATE DATABASE/USE. No pasar $db_name como
    # argumento de conexión (la BD puede no existir aún y el dump la crea solo).
    # FIX v19: MYSQL_PWD evita que la contraseña aparezca en ps aux
    gunzip -c "$dump_file" | docker exec -i -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb \
      -uroot \
      2>/dev/null
    log "  ✓ ${db_name} restaurada"
    ((count++))
  done
  log "Total: ${count} base(s) de datos restauradas"
}

# ── Restaurar archivos de sitios ──────────────────────────────
restore_files() {
  header "Restaurando archivos de sitios web"
  local FILES_ARCHIVE="${BACKUP_PATH}/files/sites.tar.gz"
  [[ -f "$FILES_ARCHIVE" ]] || { warn "sites.tar.gz no encontrado en backup"; return; }

  local SITES_VOL
  SITES_VOL=$(docker volume inspect hosting_sites-data \
    --format '{{.Mountpoint}}' 2>/dev/null || \
    echo "/var/lib/docker/volumes/hosting_sites-data/_data")

  info "Extrayendo archivos en ${SITES_VOL}..."
  # Backup de lo actual antes de sobreescribir
  if [[ -d "$SITES_VOL" ]] && [[ "$(ls -A "$SITES_VOL" 2>/dev/null)" ]]; then
    local backup_current="/tmp/sites-before-restore-$(date +%s).tar.gz"
    tar -czf "$backup_current" -C "$(dirname "$SITES_VOL")" \
      "$(basename "$SITES_VOL")" 2>/dev/null || true
    warn "Backup de archivos actuales guardado en: $backup_current"
  fi

  tar -xzf "$FILES_ARCHIVE" -C "$(dirname "$SITES_VOL")" 2>/dev/null
  # Ajustar permisos
  chown -R 1000:1000 "$SITES_VOL" 2>/dev/null || true
  docker exec php-fpm chown -R www-data:www-data /var/www/html 2>/dev/null || true
  log "Archivos restaurados en ${SITES_VOL}"

  # FIX v19: Restaurar volúmenes de servicio (sftpgo-data + portainer-data)
  # backup.sh v16+ los respalda — restauramos si existen en el backup
  for vol_name in sftpgo-data portainer-data; do
    local VOL_ARCHIVE="${BACKUP_PATH}/files/${vol_name}.tar.gz"
    if [[ -f "$VOL_ARCHIVE" ]]; then
      local VOL_PATH
      VOL_PATH=$(docker volume inspect "hosting_${vol_name}" --format '{{.Mountpoint}}' 2>/dev/null || echo "")
      if [[ -z "$VOL_PATH" ]]; then
        docker volume create "hosting_${vol_name}" &>/dev/null || true
        VOL_PATH=$(docker volume inspect "hosting_${vol_name}" --format '{{.Mountpoint}}' 2>/dev/null || echo "")
      fi
      if [[ -n "$VOL_PATH" ]]; then
        tar -xzf "$VOL_ARCHIVE" -C "$(dirname "$VOL_PATH")" 2>/dev/null
        log "Volumen ${vol_name} restaurado"
      else
        warn "No se pudo obtener mountpoint de hosting_${vol_name}"
      fi
    fi
  done
}

# ── Restaurar configuración ───────────────────────────────────
restore_config() {
  header "Restaurando configuración"
  local CONFIG_ARCHIVE="${BACKUP_PATH}/config/hosting-config.tar.gz"
  local ENV_ENC="${BACKUP_PATH}/config/.env.enc"

  if [[ -f "$CONFIG_ARCHIVE" ]]; then
    info "Extrayendo configuración en $INSTALL_DIR..."
    tar -xzf "$CONFIG_ARCHIVE" -C "$INSTALL_DIR" 2>/dev/null
    log "Configuración restaurada"
  else
    warn "hosting-config.tar.gz no encontrado"
  fi

  # Restaurar .env cifrado
  if [[ -f "$ENV_ENC" ]]; then
    info "Restaurando .env (necesitas la contraseña de cifrado = DB_ROOT_PASS)..."
    read -rsp "Contraseña de descifrado (DB_ROOT_PASS del momento del backup): " ENC_PASS
    echo ""
    openssl enc -aes-256-cbc -d -salt -pbkdf2 \
      -in "$ENV_ENC" \
      -out "${INSTALL_DIR}/.env.restored" \
      -k "$ENC_PASS" 2>/dev/null && \
      log ".env restaurado en .env.restored — revísalo antes de usar como .env" || \
      warn "No se pudo descifrar .env (contraseña incorrecta?)"
  fi

  # Restaurar certificados SSL
  local ACME_BACKUP="${BACKUP_PATH}/config/acme"
  if [[ -d "$ACME_BACKUP" ]]; then
    local ACME_VOL
    ACME_VOL=$(docker volume inspect hosting_traefik-acme \
      --format '{{.Mountpoint}}' 2>/dev/null || echo "")
    if [[ -n "$ACME_VOL" ]]; then
      cp -r "${ACME_BACKUP}/." "$ACME_VOL/" 2>/dev/null
      chmod 600 "${ACME_VOL}/acme.json" 2>/dev/null || true
      log "Certificados SSL restaurados"
    fi
  fi
}

# ── Reiniciar servicios afectados ─────────────────────────────
restart_services() {
  header "Reiniciando servicios"
  cd "$INSTALL_DIR"
  case "$MODE" in
    --db)
      docker compose restart mariadb php-fpm
      ;;
    --files)
      docker compose restart php-fpm nginx
      ;;
    --config)
      docker compose restart
      ;;
    --all|*)
      docker compose restart
      ;;
  esac
  sleep 5
  docker compose ps
  log "Servicios reiniciados"
}

# ── Verificación post-restauración ───────────────────────────
verify_restore() {
  header "Verificación"
  local ok=0
  local fail=0

  # Verificar MariaDB
  if docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -uroot \
      -e "SHOW DATABASES;" &>/dev/null; then
    log "MariaDB: accesible"
    ((ok++))
  else
    warn "MariaDB: no responde"
    ((fail++))
  fi

  # Verificar Nginx
  if docker exec nginx nginx -t &>/dev/null; then
    log "Nginx: configuración válida"
    ((ok++))
  else
    warn "Nginx: error en configuración"
    ((fail++))
  fi

  # Verificar HTTP
  if curl -sf -o /dev/null http://localhost; then
    log "HTTP: responde"
    ((ok++))
  else
    warn "HTTP: no responde aún"
    ((fail++))
  fi

  echo ""
  log "Restauración completada — OK: ${ok} | Advertencias: ${fail}"
}

# ── Ejecución ──────────────────────────────────────────────────
case "$MODE" in
  --db)     restore_databases ;;
  --files)  restore_files ;;
  --config) restore_config ;;
  --all|*)
    restore_databases
    restore_files
    restore_config
    ;;
esac

restart_services
verify_restore
