#!/usr/bin/env bash
# =============================================================
# AGREGAR VIRTUAL HOST WEB (Nginx + SSL automático)
# Uso: ./scripts/add-vhost.sh dominio.com [tipo: php|static|wordpress]
# =============================================================
set -euo pipefail

DOMAIN="${1:-}"
TYPE="${2:-php}"
INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
SITES_DATA=$(docker volume inspect hosting_sites-data \
  --format '{{.Mountpoint}}' 2>/dev/null || \
  echo "/var/lib/docker/volumes/hosting_sites-data/_data")
NGINX_SITES="${INSTALL_DIR}/nginx/sites-enabled"
NGINX_AVAIL="${INSTALL_DIR}/nginx/sites-available"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[⚠]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()  { echo -e "${CYAN}[→]${NC} $1"; }

[[ -f "$INSTALL_DIR/.env" ]] && source "$INSTALL_DIR/.env"
[[ -z "$DOMAIN" ]] && error "Uso: $0 dominio.com [php|static|wordpress]"

DOMAIN_SAFE=$(echo "$DOMAIN" | tr '.' '_' | tr '-' '_')
DOCROOT="${SITES_DATA}/${DOMAIN}"
VHOST_FILE="${NGINX_AVAIL}/${DOMAIN}.conf"
VHOST_LINK="${NGINX_SITES}/${DOMAIN}.conf"

echo -e "${YELLOW}Configurando sitio web: ${DOMAIN} (tipo: ${TYPE})${NC}"

# ── Crear directorio del sitio ────────────────────────────────
mkdir -p "${DOCROOT}"

# ── Crear página de bienvenida ────────────────────────────────
if [[ ! -f "${DOCROOT}/index.php" ]]; then
  cat > "${DOCROOT}/index.php" << PHPEOF
<?php
\$domain = '${DOMAIN}';
\$date = date('Y-m-d H:i:s');
?>
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title><?= htmlspecialchars(\$domain) ?></title>
  <style>
    body{font-family:system-ui,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;background:#f8f9fa}
    .card{text-align:center;padding:3rem;background:#fff;border-radius:1rem;box-shadow:0 4px 20px rgba(0,0,0,.08)}
    h1{color:#333;margin-bottom:.5rem}
    p{color:#666}
    .badge{display:inline-block;padding:.25rem .75rem;background:#e8f5e9;color:#2e7d32;border-radius:999px;font-size:.875rem}
  </style>
</head>
<body>
  <div class="card">
    <div class="badge">✓ Sitio funcionando</div>
    <h1><?= htmlspecialchars(\$domain) ?></h1>
    <p>Sube tu contenido a este directorio para reemplazar esta página.</p>
    <p style="font-size:.8rem;color:#999">PHP <?= PHP_VERSION ?> · <?= \$date ?></p>
  </div>
</body>
</html>
PHPEOF
  log "Página de bienvenida creada en ${DOCROOT}"
fi

# ── Crear configuración Nginx ─────────────────────────────────
case "$TYPE" in
  wordpress)
    # BUG FIX #1: La zona fastcgi_cache_path NO va dentro del heredoc del vhost.
    # Debe estar en nginx.conf al nivel http {}. Aquí solo referenciamos
    # la zona global FASTCGI_CACHE que ya está definida en nginx.conf.
    # Antes había un bloque "levels=1:2 / keys_zone=..." suelto FUERA del
    # server{} block y DENTRO del fichero de vhost → nginx rechazaba la config.
    cat > "${VHOST_FILE}" << NGINXEOF
# WordPress Virtual Host — ${DOMAIN}
# Generado por add-vhost.sh el $(date)
# NOTA: La zona fastcgi_cache_path "FASTCGI_CACHE" está definida en nginx.conf

server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root /var/www/html/${DOMAIN};
    index index.php;

    access_log /var/log/nginx/${DOMAIN}.access.log main_json;
    error_log  /var/log/nginx/${DOMAIN}.error.log warn;

    client_max_body_size 100m;

    # Seguridad WordPress
    # FIX v19: wp-login.php usaba zone=one (5r/s) — demasiado permisivo para un endpoint de login.
    # zone=login (1r/s, burst=3) es la zona diseñada exactamente para esto: protección brute-force
    # manteniendo usabilidad para admin (3 intentos rápidos permitidos antes de throttle).
    location = /wp-login.php {
        limit_req zone=login burst=3 nodelay;
        fastcgi_pass php-fpm;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_param HTTPS on;
    }

    location ~* /wp-content/uploads/.*\.php\$ { deny all; return 404; }
    location ~* /(wp-config\.php|readme\.html|license\.txt|\.git) { return 404; }
    location = /xmlrpc.php { deny all; }
    location ~* /\.(env|ht|git|svn) { deny all; }

    # Admin WordPress — excluido del FastCGI cache siempre
    location ~* ^/wp-admin/ {
        fastcgi_pass php-fpm;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_param HTTPS on;
        fastcgi_cache off;
        fastcgi_no_cache 1;
        fastcgi_read_timeout 300;
        # BUG FIX v21: zone=login (1r/s) era demasiado restrictivo para wp-admin —
        # la UI del panel hace docenas de requests al cargar y los admins recibían 503.
        # zone=general (10r/s, burst=20) es correcto para el área de administración.
        # zone=login se mantiene SOLO para /wp-login.php (endpoint de autenticación).
        limit_req zone=general burst=20 nodelay;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_pass php-fpm;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_param HTTPS on;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
        fastcgi_read_timeout 300;
        # FIX: Propagar request_id para trazabilidad end-to-end (igual que template.conf)
        fastcgi_param HTTP_X_REQUEST_ID \$request_id;
        # BUG FIX #1: Usar zona global FASTCGI_CACHE (definida en nginx.conf)
        # NO intentar redefinir una zona por dominio aquí (sintaxis inválida)
        fastcgi_cache FASTCGI_CACHE;
        fastcgi_cache_valid 200 5m;
        # Bypass cache: usuarios logueados, admin, carritos WooCommerce
        # FIX v20: $skip_cache_post (mapeada en nginx.conf) bloquea cache de POST/PUT/PATCH/DELETE
        # → checkout, login, formularios WooCommerce NUNCA se cachean
        # FIX: NO incluir \$is_args — deshabilitaría el cache para toda URL con query string
        fastcgi_cache_bypass \$skip_cache_post \$http_authorization \$cookie_wordpress_logged_in
                             \$cookie_PHPSESSID \$cookie_woocommerce_items_in_cart;
        fastcgi_no_cache \$skip_cache_post \$http_authorization \$cookie_wordpress_logged_in
                         \$cookie_PHPSESSID \$cookie_woocommerce_items_in_cart;
        add_header X-Cache \$upstream_cache_status;
    }

    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|eot|webp|avif)\$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }
}
NGINXEOF
    ;;
  static)
    cat > "${VHOST_FILE}" << NGINXEOF
# Static Site Virtual Host — ${DOMAIN}
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root /var/www/html/${DOMAIN};
    index index.html index.htm;

    access_log /var/log/nginx/${DOMAIN}.access.log main_json;
    error_log  /var/log/nginx/${DOMAIN}.error.log warn;

    limit_conn conn_limit 20;
    limit_req zone=general burst=30 nodelay;

    gzip_static on;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|eot|webp|avif|mp4|webm)\$ {
        expires 365d;
        add_header Cache-Control "public, immutable";
        access_log off;
        try_files \$uri =404;
    }

    location ~* /\.(env|ht|git|svn) { deny all; return 404; }
    location ~* \.(sql|bak|log|sh|config)\$ { deny all; return 404; }

    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
    location = /404.html { root /var/www/html/default; internal; }
    location = /50x.html { root /var/www/html/default; internal; }
}
NGINXEOF
    ;;
  php|*)
    # Usar template genérico PHP
    sed \
      -e "s|%%DOMAIN%%|${DOMAIN}|g" \
      -e "s|%%DOMAIN_SAFE%%|${DOMAIN_SAFE}|g" \
      -e "s|%%DOCROOT%%|/var/www/html/${DOMAIN}|g" \
      "${NGINX_AVAIL}/template.conf" > "${VHOST_FILE}"
    ;;
esac

log "Configuración Nginx creada: ${VHOST_FILE}"

# Crear enlace simbólico relativo (portable si se mueve INSTALL_DIR)
# ln -sf usa path relativo desde sites-enabled/ → ../sites-available/DOMAIN.conf
ln -sf "../sites-available/${DOMAIN}.conf" "${VHOST_LINK}"
log "Sitio activado: ${VHOST_LINK}"

# ── Recargar Nginx ────────────────────────────────────────────
info "Validando configuración Nginx..."
if docker exec nginx nginx -t 2>/dev/null; then
  docker exec nginx nginx -s reload
  log "Nginx recargado exitosamente"
else
  # Mostrar error completo para diagnóstico
  docker exec nginx nginx -t
  error "Error en configuración Nginx. Revisa ${VHOST_FILE}"
fi

echo ""
log "Sitio ${DOMAIN} configurado exitosamente"
echo ""
echo -e "${YELLOW}Detalles:${NC}"
echo "  Directorio:    ${DOCROOT}"
echo "  Config Nginx:  ${VHOST_FILE}"
echo "  URL:           https://${DOMAIN}"
echo "  SSL:           Automático (Let's Encrypt vía Traefik)"
echo ""
echo -e "${YELLOW}Para crear base de datos:${NC}"
DB_NAME=$(echo "${DOMAIN}" | tr '.' '_' | tr '-' '_' | cut -c1-64)
DB_PASS=$(openssl rand -base64 16 | tr -d '=/+' | cut -c1-24)
echo "  docker exec mariadb mariadb -uroot -p\${DB_ROOT_PASS} -e \\"
echo "    'CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4;'"
echo "  docker exec mariadb mariadb -uroot -p\${DB_ROOT_PASS} -e \\"
echo "    \"CREATE USER IF NOT EXISTS '${DB_NAME}'@'%' IDENTIFIED BY '${DB_PASS}';\""
echo "  docker exec mariadb mariadb -uroot -p\${DB_ROOT_PASS} -e \\"
echo "    'GRANT ALL ON ${DB_NAME}.* TO ${DB_NAME}@\"%\";'"
