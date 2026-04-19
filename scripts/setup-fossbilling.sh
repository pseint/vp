#!/usr/bin/env bash
# =============================================================
# SETUP FOSSBILLING — Sistema de facturación libre (Feature #4)
# FOSSBilling = fork activo de BoxBilling (alternativa libre a WHMCS/Blesta)
# Instala como sitio PHP dentro del stack Nginx/PHP-FPM existente
# Uso: ./scripts/setup-fossbilling.sh billing.tudominio.com
# =============================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
[[ -f "$INSTALL_DIR/.env" ]] && source "$INSTALL_DIR/.env"

BILLING_DOMAIN="${1:-billing.${DOMAIN}}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[⚠]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()  { echo -e "${CYAN}[→]${NC} $1"; }

SITES_DATA=$(docker volume inspect hosting_sites-data \
  --format '{{.Mountpoint}}' 2>/dev/null || \
  echo "/var/lib/docker/volumes/hosting_sites-data/_data")
BILLING_DIR="${SITES_DATA}/${BILLING_DOMAIN}"

echo -e "${YELLOW}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║         INSTALACIÓN FOSSBILLING — FACTURACIÓN        ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${CYAN}FOSSBilling incluye:${NC}"
echo "  ✓ Gestión de clientes y facturas"
echo "  ✓ Órdenes y productos/servicios"
echo "  ✓ Pasarelas de pago (PayPal, Stripe, etc.)"
echo "  ✓ Tickets de soporte"
echo "  ✓ API REST"
echo "  ✓ Panel de cliente"
echo ""
echo -e "  Dominio: ${YELLOW}${BILLING_DOMAIN}${NC}"
echo ""
read -rp "¿Continuar instalación? [y/N] " confirm
[[ "$confirm" != "y" ]] && { warn "Cancelado."; exit 0; }

# ── Crear base de datos ───────────────────────────────────────
DB_NAME="fossbilling"
DB_USER="fossbilling"
DB_PASS=$(openssl rand -base64 16 | tr -d '=/+' | head -c 24)

info "Creando base de datos ${DB_NAME}..."
# BUG FIX v19: Los comentarios inline dentro de comandos multi-línea bash (después de \)
# son válidos PERO consumen el resto de las líneas como comentario, dejando el -e "..."
# como un comando separado que falla. Solución: agrupar todo en un único -e con ;
docker exec -e MYSQL_PWD="${DB_ROOT_PASS}" mariadb mariadb -uroot \
  -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
      CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
      GRANT ALL ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
      FLUSH PRIVILEGES;" \
  2>/dev/null && log "Base de datos y usuario creados" || warn "La base de datos ya existe — continuando"

log "Base de datos creada"

# ── Descargar FOSSBilling ─────────────────────────────────────
info "Descargando FOSSBilling (versión más reciente)..."
mkdir -p "${BILLING_DIR}"

# Obtener la URL de la última versión desde GitHub
LATEST_URL=$(curl -s https://api.github.com/repos/FOSSBilling/FOSSBilling/releases/latest \
  | grep "browser_download_url" \
  | grep "FOSSBilling.zip" \
  | cut -d'"' -f4)

if [[ -z "$LATEST_URL" ]]; then
  warn "No se pudo obtener URL automática — usando URL conocida"
  LATEST_URL="https://github.com/FOSSBilling/FOSSBilling/releases/latest/download/FOSSBilling.zip"
fi

info "Descargando desde: ${LATEST_URL}"
# BUG FIX v15: añadido --retry 3 para redes inestables (Oracle Free Tier)
curl -L --retry 3 --retry-delay 2 --fail -o /tmp/fossbilling.zip "$LATEST_URL" || \
  error "No se pudo descargar FOSSBilling desde ${LATEST_URL}"

info "Extrayendo archivos..."
# BUG FIX v15: -o (overwrite) evita que unzip falle si el directorio ya existe de un intento previo
unzip -q -o /tmp/fossbilling.zip -d /tmp/fossbilling-extracted/
cp -r /tmp/fossbilling-extracted/. "${BILLING_DIR}/"
rm -rf /tmp/fossbilling.zip /tmp/fossbilling-extracted/

log "FOSSBilling descargado y extraído"

# ── Configurar permisos ───────────────────────────────────────
# FIX: 775 en vez de 777 — world-write no necesario, www-data es owner
# BUG FIX v15: siempre usar docker exec para chown — UID de www-data en el host
# puede ser 33 (Debian) pero en el contenedor Alpine es 1000.
docker exec php-fpm chown -R www-data:www-data "/var/www/html/${BILLING_DOMAIN}" 2>/dev/null || true
chmod -R 755 "${BILLING_DIR}"
chmod -R 775 "${BILLING_DIR}/data/cache" \
             "${BILLING_DIR}/data/log" \
             "${BILLING_DIR}/data/uploads" 2>/dev/null || true

log "Permisos configurados"

# ── Crear configuración pre-instalación ───────────────────────
if [[ -f "${BILLING_DIR}/config-sample.php" ]]; then
  cp "${BILLING_DIR}/config-sample.php" "${BILLING_DIR}/config.php"
fi

# ── Crear vhost Nginx ─────────────────────────────────────────
info "Creando vhost Nginx para ${BILLING_DOMAIN}..."
cat > "${INSTALL_DIR}/nginx/sites-available/${BILLING_DOMAIN}.conf" << NGINXEOF
# FOSSBilling Virtual Host — ${BILLING_DOMAIN}
server {
    listen 80;
    server_name ${BILLING_DOMAIN};
    root /var/www/html/${BILLING_DOMAIN};
    index index.php index.html;

    access_log /var/log/nginx/${BILLING_DOMAIN}.access.log main_json;
    error_log  /var/log/nginx/${BILLING_DOMAIN}.error.log warn;

    client_max_body_size 50m;

    # Proteger archivos sensibles
    location ~* /(config\.php|composer\.json|composer\.lock|\.env|\.git) {
        deny all;
        return 404;
    }
    location ~* /data/(cache|log|uploads)/.*\.(php|phtml|sh|py)\$ {
        deny all;
        return 404;
    }

    # FOSSBilling — todas las rutas pasan por index.php
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_pass php-fpm;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_param HTTPS on;
        fastcgi_read_timeout 120;
    }

    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires 30d;
        add_header Cache-Control "public";
        access_log off;
    }
}
NGINXEOF

# FIX: usar symlink relativo (portable si INSTALL_DIR cambia), igual que add-vhost.sh
ln -sf "../sites-available/${BILLING_DOMAIN}.conf" \
       "${INSTALL_DIR}/nginx/sites-enabled/${BILLING_DOMAIN}.conf"

# ── Crear registro DNS A para el subdominio de facturación ───
info "Creando registro DNS A para ${BILLING_DOMAIN}..."
if curl -sf -H "X-API-Key: ${PDNS_API_KEY}" \
    "http://localhost:${PDNS_API_PORT:-8053}/api/v1/servers/localhost/zones/${DOMAIN}." &>/dev/null; then
  # Zona del dominio principal existe — añadir solo el registro A del subdominio
  curl -sf -X PATCH \
    -H "X-API-Key: ${PDNS_API_KEY}" \
    -H "Content-Type: application/json" \
    "http://localhost:${PDNS_API_PORT:-8053}/api/v1/servers/localhost/zones/${DOMAIN}." \
    -d "{\"rrsets\":[{\"name\":\"${BILLING_DOMAIN}.\",\"type\":\"A\",\"ttl\":300,\"changetype\":\"REPLACE\",
         \"records\":[{\"content\":\"${SERVER_IP}\",\"disabled\":false}]}]}" \
    && log "Registro DNS A creado: ${BILLING_DOMAIN} → ${SERVER_IP}" \
    || warn "No se pudo crear registro DNS — añádelo manualmente en PDNS Admin"
else
  # Zona no existe — crear zona completa
  bash "${INSTALL_DIR}/scripts/add-domain.sh" "${BILLING_DOMAIN}" "${SERVER_IP}" 2>/dev/null \
    && log "Zona DNS creada para ${BILLING_DOMAIN}" \
    || warn "No se pudo crear zona DNS — añádelo manualmente en PDNS Admin"
fi

# Recargar Nginx
if docker exec nginx nginx -t 2>/dev/null; then
  docker exec nginx nginx -s reload
  log "Nginx recargado"
else
  error "Error en config Nginx — revisa ${INSTALL_DIR}/nginx/sites-available/${BILLING_DOMAIN}.conf"
fi

# ── Resumen ───────────────────────────────────────────────────
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN} FOSSBILLING INSTALADO CORRECTAMENTE${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${CYAN}Siguiente paso — Completar instalación web:${NC}"
echo ""
echo -e "  1. Abre: ${YELLOW}https://${BILLING_DOMAIN}/install/install.php${NC}"
echo ""
echo -e "  2. Datos de base de datos:"
echo -e "     Host:     mariadb"
echo -e "     DB:       ${DB_NAME}"
echo -e "     Usuario:  ${DB_USER}"
echo -e "     Password: ${GREEN}${DB_PASS}${NC}"
echo ""
echo -e "  3. Configura tu cuenta de administrador"
echo ""
echo -e "  4. ${YELLOW}IMPORTANTE: Elimina el directorio /install después:${NC}"
echo -e "     rm -rf ${BILLING_DIR}/install/"
echo ""
echo -e "${CYAN}Pasarelas de pago disponibles:${NC}"
echo "  PayPal, Stripe, Braintree, Mollie, Coinbase, y más"
echo ""
echo -e "${CYAN}DNS necesario:${NC}"
echo "  ${BILLING_DOMAIN}.  IN A  ${SERVER_IP:-tu.ip.publica}"
echo ""
log "FOSSBilling listo — completa la instalación en el navegador"

# Limpiar
rm -f /tmp/fossbilling.zip
