#!/usr/bin/env bash
# =============================================================
# CREAR BASE DE DATOS para un sitio web
# Uso: ./scripts/create-db.sh nombre_sitio [usuario] [password]
# =============================================================
set -euo pipefail

SITE="${1:-}"
DB_USER_CUSTOM="${2:-}"
DB_PASS_CUSTOM="${3:-}"
INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
[[ -f "$INSTALL_DIR/.env" ]] && source "$INSTALL_DIR/.env"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()   { echo -e "${GREEN}[✓]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[[ -z "$SITE" ]] && error "Uso: $0 nombre_sitio [usuario] [password]"

# Sanitizar nombre (solo letras, números, guión bajo)
DB_NAME=$(echo "${SITE}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g' | cut -c1-64)
DB_USER="${DB_USER_CUSTOM:-${DB_NAME:0:32}}"
DB_PASS="${DB_PASS_CUSTOM:-$(openssl rand -base64 24 | tr -d '=/+' | cut -c1-24)}"

log "Creando base de datos: ${DB_NAME}"

# FIX v19: MYSQL_PWD evita que DB_ROOT_PASS aparezca en ps aux
docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb \
  -uroot \
  -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
      CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
      GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
      FLUSH PRIVILEGES;" \
  2>/dev/null && log "Base de datos creada exitosamente"

echo ""
echo -e "${YELLOW}Credenciales de la base de datos:${NC}"
echo "  Host:     mariadb  (desde PHP-FPM)  |  127.0.0.1:3306 (desde el host)"
echo "  Database: ${DB_NAME}"
echo "  Usuario:  ${DB_USER}"
echo "  Password: ${DB_PASS}"
echo ""
echo -e "${YELLOW}Para WordPress wp-config.php:${NC}"
echo "  define('DB_NAME', '${DB_NAME}');"
echo "  define('DB_USER', '${DB_USER}');"
echo "  define('DB_PASSWORD', '${DB_PASS}');"
echo "  define('DB_HOST', 'mariadb');"
echo ""
echo -e "${YELLOW}⚠ Guarda estas credenciales, no se vuelven a mostrar${NC}"
