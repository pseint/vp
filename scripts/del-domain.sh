#!/usr/bin/env bash
# =============================================================
# ELIMINAR DOMINIO / VIRTUAL HOST v6
# Uso: ./scripts/del-domain.sh dominio.com [--dns-only|--vhost-only|--all]
# FIX 21: ahora ofrece eliminar la BD y los archivos del sitio
# =============================================================
set -euo pipefail

DOMAIN="${1:-}"
MODE="${2:---vhost-only}"
INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
[[ -f "$INSTALL_DIR/.env" ]] && source "$INSTALL_DIR/.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[⚠]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()  { echo -e "${CYAN}[→]${NC} $1"; }

[[ -z "$DOMAIN" ]] && error "Uso: $0 dominio.com [--dns-only|--vhost-only|--all]"

echo -e "${RED}"
echo "╔══════════════════════════════════════════════╗"
echo "║   ELIMINAR DOMINIO — OPERACIÓN IRREVERSIBLE  ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Dominio: ${YELLOW}${DOMAIN}${NC}"
echo -e "  Modo:    ${YELLOW}${MODE}${NC}"
echo ""
read -rp "Escribe el dominio completo para confirmar: " CONFIRM
[[ "$CONFIRM" == "$DOMAIN" ]] || error "Cancelado — dominio no coincide"

# ── Eliminar Virtual Host Nginx ───────────────────────────────
del_vhost() {
  local VHOST_CONF="${INSTALL_DIR}/nginx/sites-enabled/${DOMAIN}.conf"
  local VHOST_AVAIL="${INSTALL_DIR}/nginx/sites-available/${DOMAIN}.conf"

  [[ -L "$VHOST_CONF" ]] && rm -f "$VHOST_CONF"  && log "Enlace Nginx eliminado"
  [[ -f "$VHOST_AVAIL" ]] && rm -f "$VHOST_AVAIL" && log "Config Nginx eliminada"

  docker exec nginx nginx -t 2>/dev/null && \
    docker exec nginx nginx -s reload && log "Nginx recargado"
}

# ── Eliminar zona DNS ─────────────────────────────────────────
del_dns() {
  curl -sf -X DELETE \
    -H "X-API-Key: ${PDNS_API_KEY}" \
    "http://localhost:8053/api/v1/servers/localhost/zones/${DOMAIN}." \
    && log "Zona DNS ${DOMAIN} eliminada" \
    || warn "No se pudo eliminar zona DNS (puede no existir)"
}

# ── Eliminar archivos del sitio ───────────────────────────────
del_files() {
  local SITES_VOL
  SITES_VOL=$(docker volume inspect hosting_sites-data \
    --format '{{.Mountpoint}}' 2>/dev/null || echo "")

  if [[ -n "$SITES_VOL" && -d "${SITES_VOL}/${DOMAIN}" ]]; then
    local SIZE
    SIZE=$(du -sh "${SITES_VOL}/${DOMAIN}" 2>/dev/null | cut -f1)
    echo ""
    warn "Directorio: ${SITES_VOL}/${DOMAIN} (${SIZE})"
    read -rp "¿Eliminar archivos del sitio? [s/N] " del_files_confirm
    if [[ "$del_files_confirm" =~ ^[sS]$ ]]; then
      rm -rf "${SITES_VOL}/${DOMAIN}"
      log "Archivos del sitio eliminados (${SIZE})"
    else
      warn "Archivos NO eliminados — están en: ${SITES_VOL}/${DOMAIN}"
    fi
  fi
}

# ── Eliminar base de datos ────────────────────────────────────
# FIX 21: ofrecer eliminar la BD asociada
del_database() {
  local DB_NAME
  DB_NAME=$(echo "${DOMAIN}" | tr '.' '_' | tr '-' '_' | cut -c1-64)

  # Verificar si existe la BD
  if docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -uroot \
      -e "USE \`${DB_NAME}\`;" &>/dev/null 2>&1; then
    local DB_SIZE
    DB_SIZE=$(docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -uroot \
      --batch --skip-column-names \
      -e "SELECT ROUND(SUM(data_length+index_length)/1024/1024,1)
          FROM information_schema.tables
          WHERE table_schema='${DB_NAME}';" 2>/dev/null | tr -d '[:space:]')

    echo ""
    warn "Base de datos: ${DB_NAME} (${DB_SIZE:-0}MB)"
    read -rp "¿Eliminar la base de datos '${DB_NAME}'? [s/N] " del_db_confirm
    if [[ "$del_db_confirm" =~ ^[sS]$ ]]; then
      docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -uroot \
        -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;
            DROP USER IF EXISTS '${DB_NAME}'@'%';
            DROP USER IF EXISTS '${DB_NAME:0:32}'@'%';
            FLUSH PRIVILEGES;" 2>/dev/null
      log "Base de datos '${DB_NAME}' eliminada"
    else
      warn "BD NO eliminada — puedes hacerlo manualmente: make db-shell"
    fi
  else
    info "No se encontró base de datos '${DB_NAME}' — omitiendo"
  fi
}

# ── Limpiar logs del dominio ─────────────────────────────────
del_logs() {
  local LOG_DIR
  LOG_DIR="${INSTALL_DIR}/logs/nginx"
  local found_logs=()

  for log_file in "${LOG_DIR}/${DOMAIN}.access.log" "${LOG_DIR}/${DOMAIN}.error.log"                    "${LOG_DIR}/${DOMAIN}.access.log."* "${LOG_DIR}/${DOMAIN}.error.log."*; do
    [[ -f "$log_file" ]] && found_logs+=("$log_file")
  done

  if [[ ${#found_logs[@]} -gt 0 ]]; then
    # BUG FIX v15: usar la lista ya construida found_logs en lugar del glob sin comillas.
    # El glob "${LOG_DIR}/${DOMAIN}"*.log* en du podía fallar si no había archivos coincidentes.
    local total_kb
    total_kb=$(du -sk "${found_logs[@]}" 2>/dev/null | awk '{sum+=$1} END{printf "%.1fMB", sum/1024}' || echo "?")
    echo ""
    info "Logs encontrados para ${DOMAIN}: ${#found_logs[@]} archivo(s) (${total_kb})"
    read -rp $'¿Eliminar logs de Nginx para '"${DOMAIN}"$'? [s/N] ' del_logs_confirm
    if [[ "$del_logs_confirm" =~ ^[sS]$ ]]; then
      rm -f "${LOG_DIR}/${DOMAIN}".*.log* 2>/dev/null || true
      log "Logs de ${DOMAIN} eliminados"
    else
      info "Logs conservados en ${LOG_DIR}/"
    fi
  fi
}

# ── Eliminar usuario SFTP ─────────────────────────────────────
del_sftp_user() {
  if docker inspect sftpgo &>/dev/null 2>&1; then
    local SFTP_USER
    SFTP_USER=$(echo "$DOMAIN" | tr '.' '_' | tr '-' '_')
    read -rp "¿Eliminar usuario SFTP '${SFTP_USER}'? [s/N] " del_sftp
    if [[ "$del_sftp" =~ ^[sS]$ ]]; then
      bash "${INSTALL_DIR}/scripts/sftp-user.sh" "$DOMAIN" 0 del 2>/dev/null || \
        warn "Usuario SFTP no encontrado o ya eliminado"
    fi
  fi
}

# ── Ejecución ────────────────────────────────────────────────
case "$MODE" in
  --dns-only)
    del_dns
    ;;
  --vhost-only)
    del_vhost
    del_files
    del_database
    del_sftp_user
    del_logs
    ;;
  --all)
    del_vhost
    del_dns
    del_files
    del_database
    del_sftp_user
    del_logs
    ;;
  *)
    del_vhost
    del_files
    del_database
    del_sftp_user
    ;;
esac

echo ""
log "Operación completada para ${DOMAIN}"
