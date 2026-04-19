#!/usr/bin/env bash
# =============================================================
# INSTALAR WORDPRESS — Descarga, configura y prepara WP
# Uso: ./scripts/install-wordpress.sh dominio.com
# =============================================================
set -euo pipefail

DOMAIN="${1:-}"
INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
[[ -f "$INSTALL_DIR/.env" ]] && source "$INSTALL_DIR/.env"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
log()   { echo -e "${GREEN}[✓]${NC} $1"; }
info()  { echo -e "${CYAN}[→]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[[ -z "$DOMAIN" ]] && error "Uso: $0 dominio.com"

SITES_VOL=$(docker volume inspect hosting_sites-data \
  --format '{{.Mountpoint}}' 2>/dev/null || \
  echo "/var/lib/docker/volumes/hosting_sites-data/_data")
DOCROOT="${SITES_VOL}/${DOMAIN}"

# ── Crear vhost tipo WordPress ────────────────────────────────
info "Configurando vhost WordPress para ${DOMAIN}..."
bash "${INSTALL_DIR}/scripts/add-vhost.sh" "${DOMAIN}" "wordpress"

# ── Crear base de datos ───────────────────────────────────────
DB_NAME=$(echo "${DOMAIN}" | tr '.' '_' | tr '-' '_' | cut -c1-64 | tr '[:upper:]' '[:lower:]')
DB_USER="${DB_NAME:0:32}"
DB_PASS=$(openssl rand -base64 24 | tr -d '=/+' | cut -c1-24)

bash "${INSTALL_DIR}/scripts/create-db.sh" "${DB_NAME}" "${DB_USER}" "${DB_PASS}"

# ── Descargar WordPress ────────────────────────────────────────
info "Descargando WordPress..."
docker exec php-fpm sh -c "
  cd /var/www/html
  mkdir -p ${DOMAIN}
  rm -rf /tmp/wp-latest.tar.gz
  wget -q https://wordpress.org/latest.tar.gz -O /tmp/wp-latest.tar.gz
  tar -xzf /tmp/wp-latest.tar.gz -C /tmp/
  cp -r /tmp/wordpress/. ${DOMAIN}/
  rm -rf /tmp/wordpress /tmp/wp-latest.tar.gz
  chown -R www-data:www-data ${DOMAIN}/
  chmod -R 755 ${DOMAIN}/
  # Permisos correctos: directorios 755, archivos 644, wp-content 775 (no 777)
  find ${DOMAIN}/ -type d -exec chmod 755 {} \;
  find ${DOMAIN}/ -type f -exec chmod 644 {} \;
  chmod -R 775 ${DOMAIN}/wp-content/
"
log "WordPress descargado en ${DOCROOT}"

# ── Generar wp-config.php ─────────────────────────────────────
WP_AUTH_KEY=$(openssl rand -base64 64 | tr -d '\n/=+' | cut -c1-64)
WP_SECURE_KEY=$(openssl rand -base64 64 | tr -d '\n/=+' | cut -c1-64)
WP_LOGGED_KEY=$(openssl rand -base64 64 | tr -d '\n/=+' | cut -c1-64)
WP_NONCE_KEY=$(openssl rand -base64 64 | tr -d '\n/=+' | cut -c1-64)
WP_AUTH_SALT=$(openssl rand -base64 64 | tr -d '\n/=+' | cut -c1-64)
WP_SECURE_SALT=$(openssl rand -base64 64 | tr -d '\n/=+' | cut -c1-64)
WP_LOGGED_SALT=$(openssl rand -base64 64 | tr -d '\n/=+' | cut -c1-64)
WP_NONCE_SALT=$(openssl rand -base64 64 | tr -d '\n/=+' | cut -c1-64)

cat > "${DOCROOT}/wp-config.php" << WPEOF
<?php
/** Base de datos */
define( 'DB_NAME',     '${DB_NAME}' );
define( 'DB_USER',     '${DB_USER}' );
define( 'DB_PASSWORD', '${DB_PASS}' );
define( 'DB_HOST',     'mariadb' );
define( 'DB_CHARSET',  'utf8mb4' );
define( 'DB_COLLATE',  'utf8mb4_unicode_ci' );

/** Keys y Salts de seguridad */
define( 'AUTH_KEY',         '${WP_AUTH_KEY}' );
define( 'SECURE_AUTH_KEY',  '${WP_SECURE_KEY}' );
define( 'LOGGED_IN_KEY',    '${WP_LOGGED_KEY}' );
define( 'NONCE_KEY',        '${WP_NONCE_KEY}' );
define( 'AUTH_SALT',        '${WP_AUTH_SALT}' );
define( 'SECURE_AUTH_SALT', '${WP_SECURE_SALT}' );
define( 'LOGGED_IN_SALT',   '${WP_LOGGED_SALT}' );
define( 'NONCE_SALT',       '${WP_NONCE_SALT}' );

/** Prefijo de tablas */
\$table_prefix = 'wp_';

/** Debug (DESACTIVADO en producción) */
define( 'WP_DEBUG',         false );
define( 'WP_DEBUG_LOG',     false );
define( 'WP_DEBUG_DISPLAY', false );

/** Redis Cache (si usas el plugin WP Redis) */
define( 'WP_REDIS_HOST',     'redis' );
define( 'WP_REDIS_PORT',     6379 );
define( 'WP_REDIS_AUTH',     '${REDIS_PASS:-}' );
define( 'WP_REDIS_DATABASE', 0 );

/** HTTPS detrás de proxy Traefik */
define( 'FORCE_SSL_ADMIN', true );
if ( isset( \$_SERVER['HTTP_X_FORWARDED_PROTO'] ) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https' ) {
    \$_SERVER['HTTPS'] = 'on';
}

/** Limite de memoria */
define( 'WP_MEMORY_LIMIT', '256M' );
define( 'WP_MAX_MEMORY_LIMIT', '512M' );

/** URLs */
define( 'WP_HOME',    'https://${DOMAIN}' );
define( 'WP_SITEURL', 'https://${DOMAIN}' );

/** Deshabilitar editor de archivos en admin (seguridad) */
define( 'DISALLOW_FILE_EDIT', true );

/** Deshabilitar instalación/actualización de plugins/temas desde admin */
define( 'DISALLOW_FILE_MODS', false ); // Cambiar a true en producción estable

/** Límite de revisiones de posts */
define( 'WP_POST_REVISIONS', 5 );

/** Deshabilitar WP-Cron interno (usar cron del sistema para mejor rendimiento) */
define( 'DISABLE_WP_CRON', true );

/** XML-RPC está bloqueado por el bloque location en el vhost Nginx.
 *  No existe constante de WP para deshabilitarlo desde wp-config.php. */

/** Bootstrap */
if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}
require_once ABSPATH . 'wp-settings.php';
WPEOF

# BUG FIX v15: NO hacer chown en el host — el UID de www-data en el host
# puede ser diferente al UID 1000 configurado en el Dockerfile de PHP-FPM.
# Si www-data existe en el host con UID 33 (Debian) el chown silenciosamente
# asignará el propietario incorrecto. Siempre usar docker exec para garantizar
# que el UID sea el correcto dentro del contenedor (www-data = 1000 en Alpine).
docker exec php-fpm chown www-data:www-data "/var/www/html/${DOMAIN}/wp-config.php" 2>/dev/null || true
docker exec php-fpm chmod 440 "/var/www/html/${DOMAIN}/wp-config.php" 2>/dev/null || true
log "wp-config.php generado con claves únicas"

# ── Añadir WP-Cron al crontab del sistema ─────────────────────
# DISABLE_WP_CRON=true en wp-config → el cron nativo de WP está desactivado
# Necesitamos que el sistema lo llame cada 5 minutos
CRON_LINE="*/5 * * * * docker exec php-fpm php /var/www/html/${DOMAIN}/wp-cron.php > /dev/null 2>&1"
( crontab -l 2>/dev/null | grep -v "wp-cron.php.*${DOMAIN}" ; echo "$CRON_LINE" ) | crontab -
log "WP-Cron añadido al crontab del sistema (cada 5 min)"

# ── Instalar WordPress con WP-CLI (si está disponible en la imagen) ──
WP_ADMIN_USER="admin"
WP_ADMIN_PASS=$(openssl rand -base64 16 | tr -d '=/+' | cut -c1-20)
WP_ADMIN_EMAIL="${ACME_EMAIL:-admin@${DOMAIN}}"

info "Intentando instalación automática con WP-CLI..."
if docker exec php-fpm wp --version --allow-root &>/dev/null 2>&1; then
  docker exec -e HOME=/tmp php-fpm wp core install \
    --allow-root \
    --path="/var/www/html/${DOMAIN}" \
    --url="https://${DOMAIN}" \
    --title="${DOMAIN}" \
    --admin_user="${WP_ADMIN_USER}" \
    --admin_password="${WP_ADMIN_PASS}" \
    --admin_email="${WP_ADMIN_EMAIL}" \
    --skip-email 2>/dev/null && {
      log "WordPress instalado automáticamente con WP-CLI"
      WP_CLI_USED=true
    } || {
      warn "WP-CLI falló — completa la instalación en el navegador"
      WP_CLI_USED=false
    }
else
  warn "WP-CLI no disponible en la imagen PHP — completa en el navegador"
  WP_CLI_USED=false
fi

echo ""
log "WordPress instalado exitosamente para ${DOMAIN}"
echo ""
echo -e "${YELLOW}Detalles de acceso:${NC}"
echo "  URL:      https://${DOMAIN}"
echo "  DB:       ${DB_NAME} / ${DB_USER} / ${DB_PASS}"
if [[ "${WP_CLI_USED:-false}" == "true" ]]; then
  echo ""
  echo -e "${YELLOW}Credenciales WordPress (¡GUÁRDALAS!):${NC}"
  echo "  Admin:    https://${DOMAIN}/wp-admin"
  echo "  Usuario:  ${WP_ADMIN_USER}"
  echo "  Password: ${WP_ADMIN_PASS}"
  echo "  Email:    ${WP_ADMIN_EMAIL}"
else
  echo "  1. Visita https://${DOMAIN} para completar la instalación"
fi
echo ""
echo -e "${YELLOW}Comandos WP-CLI útiles (desde el servidor):${NC}"
echo "  docker exec php-fpm wp --allow-root --path=/var/www/html/${DOMAIN} plugin install redis-cache --activate"
echo "  docker exec php-fpm wp --allow-root --path=/var/www/html/${DOMAIN} cache flush"
echo "  docker exec php-fpm wp --allow-root --path=/var/www/html/${DOMAIN} core update"
echo ""
echo -e "${YELLOW}Cron del sistema para WP (añadido automáticamente):${NC}"
echo "  */5 * * * * docker exec php-fpm php /var/www/html/${DOMAIN}/wp-cron.php"
echo ""
echo "  SSL se activará automáticamente (puede tardar 1-2 minutos)"
