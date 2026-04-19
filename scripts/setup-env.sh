#!/usr/bin/env bash
# =============================================================
# SETUP-ENV v3 — Genera .env + .htpasswd + reemplaza placeholders
# Uso: bash scripts/setup-env.sh
# =============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[⚠]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════╗"
echo "║   CONFIGURADOR DE ENTORNO — HOSTING ORACLE   ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

[[ -f "docker-compose.yml" ]] || \
  error "Ejecuta desde el directorio raíz (donde está docker-compose.yml)"

# BUG FIX #12: Idempotencia — evitar sobreescribir config en servidor en producción
if [[ -f ".env" ]]; then
  warn "Ya existe un archivo .env en este directorio."
  warn "Re-ejecutar setup-env.sh en un servidor en producción puede corromper la config."
  echo -e "
  Opciones:"
  echo "    1) Continuar y sobrescribir todo (⚠ peligroso si ya está corriendo)"
  echo "    2) Salir (recomendado si el servidor ya está activo)"
  echo ""
  read -rp "¿Continuar de todas formas? [y/N] " overwrite_confirm
  [[ "$overwrite_confirm" == "y" ]] || error "Cancelado. Para reconfigurar, elimina .env manualmente."
fi

# ── Datos básicos ────────────────────────────────────────────
read -rp "$(echo -e ${YELLOW})IP pública del servidor Oracle: $(echo -e ${NC})" SERVER_IP
read -rp "$(echo -e ${YELLOW})Dominio principal (ej: miservidor.com): $(echo -e ${NC})" DOMAIN
read -rp "$(echo -e ${YELLOW})Email para SSL Let's Encrypt: $(echo -e ${NC})" ACME_EMAIL
read -rp "$(echo -e ${YELLOW})Zona horaria [America/Lima]: $(echo -e ${NC})" TZ_INPUT
read -rp "$(echo -e ${YELLOW})Token Cloudflare para Wildcard SSL (opcional, Enter para omitir): $(echo -e ${NC})" CF_DNS_API_TOKEN
CF_DNS_API_TOKEN="${CF_DNS_API_TOKEN:-}"
TZ="${TZ_INPUT:-America/Lima}"

[[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || error "IP inválida: $SERVER_IP"

# Advertir si es IP privada (inútil para Oracle Cloud)
if [[ "$SERVER_IP" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
  warn "⚠ $SERVER_IP parece una IP privada"
  warn "  Oracle Cloud Free Tier asigna una IP pública — úsala, no la IP privada de la VNIC"
  warn "  Encuéntrala en: Oracle Console → Compute → Instances → [tu instancia] → Public IP"
  echo ""
  read -rp "¿Continuar con esta IP de todas formas? [y/N] " ip_confirm
  [[ "$ip_confirm" == "y" ]] || error "Cancelado. Usa tu IP pública de Oracle."
fi
[[ "$DOMAIN" =~ \. ]] || error "Dominio inválido: $DOMAIN"
[[ "$ACME_EMAIL" =~ @ ]] || error "Email inválido: $ACME_EMAIL"

# ── Generar contraseñas (solo alfanumérico — seguro con sed/yaml) ──
gen_pass() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32; }
gen_key()  { openssl rand -hex 32; }

echo ""
echo -e "${CYAN}Generando contraseñas seguras...${NC}"

DB_ROOT_PASS=$(gen_pass)
PDNS_API_KEY=$(gen_key)
PDNS_ADMIN_SECRET_KEY=$(gen_key)
PDNS_DB_PASS=$(gen_pass)
PDNS_ADMIN_DB_PASS=$(gen_pass)
DB_PASS=$(gen_pass)
REDIS_PASS=$(gen_pass)
TRAEFIK_PASS=$(gen_pass)

# ── htpasswd ────────────────────────────────────────────────
if ! command -v htpasswd &>/dev/null; then
  apt-get install -y -qq apache2-utils 2>/dev/null || true
fi

TRAEFIK_HASH=""
TRAEFIK_HASH_RAW=""
if command -v htpasswd &>/dev/null; then
  TRAEFIK_HASH=$(htpasswd -nbB admin "$TRAEFIK_PASS" | sed 's/\$/\$\$/g')
  TRAEFIK_HASH_RAW=$(htpasswd -nbB admin "$TRAEFIK_PASS")
  log "Hash Traefik generado con htpasswd (bcrypt)"
else
  TRAEFIK_HASH="admin:GENERA_MANUALMENTE_htpasswd_-nbB_admin_PASS"
  TRAEFIK_HASH_RAW="admin:GENERA_MANUALMENTE_htpasswd_-nbB_admin_PASS"
  warn "htpasswd no disponible — genera el hash manualmente"
fi

# ── Escribir .env ────────────────────────────────────────────
SFTPGO_ADMIN_PASS=$(gen_pass)
cat > .env << ENVEOF
# ============================================================
# ENTORNO GENERADO — $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

SERVER_IP=${SERVER_IP}
DOMAIN=${DOMAIN}
INSTALL_DIR=/opt/hosting
TZ=${TZ}

ACME_EMAIL=${ACME_EMAIL}
ACME_ENV=production

PDNS_API_KEY=${PDNS_API_KEY}
PDNS_ADMIN_SECRET_KEY=${PDNS_ADMIN_SECRET_KEY}
PDNS_API_PORT=8053
PDNS_ADMIN_PORT=8081

DB_ROOT_PASS=${DB_ROOT_PASS}
PDNS_DB_NAME=powerdns
PDNS_DB_USER=pdns
PDNS_DB_PASS=${PDNS_DB_PASS}
PDNS_ADMIN_DB_NAME=pdnsadmin
PDNS_ADMIN_DB_USER=pdnsadmin
PDNS_ADMIN_DB_PASS=${PDNS_ADMIN_DB_PASS}
DB_USER=webuser
DB_PASS=${DB_PASS}

REDIS_PASS=${REDIS_PASS}
TRAEFIK_AUTH=${TRAEFIK_HASH}

TRAEFIK_MEM=128m
TRAEFIK_CPU=0.10
PDNS_MEM=128m
PDNS_CPU=0.10
PDNS_ADMIN_MEM=256m
PDNS_ADMIN_CPU=0.20
NGINX_MEM=256m
NGINX_CPU=0.30
PHP_MEM=512m
PHP_CPU=0.50
MARIADB_MEM=512m
MARIADB_CPU=0.50
REDIS_MEM=128m
REDIS_CPU=0.10
PORTAINER_MEM=128m
PORTAINER_CPU=0.10

BACKUP_DIR=/opt/hosting/data/backups
BACKUP_RETENTION_DAYS=7

# SFTPGo
SFTPGO_ADMIN_PASS=${SFTPGO_ADMIN_PASS}

SFTPGO_MEM=128m
SFTPGO_CPU=0.10

# ── Mailcow ────────────────────────────────────────────────
MAIL_DOMAIN=mail.${DOMAIN}

# Wildcard SSL — Cloudflare DNS Challenge
# Obtén en: https://dash.cloudflare.com/profile/api-tokens
# Permiso: Zone:DNS:Edit
CF_DNS_API_TOKEN=${CF_DNS_API_TOKEN:-}

# ── Alertas ───────────────────────────────────────────────
# Telegram: crea un bot con @BotFather
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=

# Webhook genérico (Slack, Discord, n8n, etc.)
ALERT_WEBHOOK_URL=

# ── Backup Offsite con rclone ─────────────────────────────
# Configurar primero: rclone config
# Ejemplos: s3:mi-bucket/hosting  |  b2:mi-bucket  |  gdrive:backups
RCLONE_REMOTE=

# ── Servidor NS ───────────────────────────────────────────
# Dominio donde están ns1/ns2 (normalmente igual a DOMAIN)
SERVER_DOMAIN=${DOMAIN}
ENVEOF

chmod 600 .env
log "Archivo .env creado (permisos 600)"

# ── .htpasswd para Traefik (FIX CRÍTICO: este archivo DEBE existir) ──
mkdir -p traefik/dynamic
printf '%s\n' "$TRAEFIK_HASH_RAW" > traefik/dynamic/.htpasswd
chmod 640 traefik/dynamic/.htpasswd
log "traefik/dynamic/.htpasswd generado"

# ── Reemplazar placeholders (usando Python para evitar problemas con sed) ──
replace_in_file() {
  local placeholder="$1"
  local value="$2"
  local file="$3"
  [[ -f "$file" ]] || return 0
  python3 -c "
import sys
with open('$file', 'r') as f:
    content = f.read()
content = content.replace('$placeholder', '''$value''')
with open('$file', 'w') as f:
    f.write(content)
" 2>/dev/null && log "  $file — placeholder '$placeholder' reemplazado" || \
  warn "  No se pudo reemplazar en $file"
}

echo ""
echo -e "${CYAN}Configurando archivos...${NC}"

replace_in_file "PDNS_DB_PASS_PLACEHOLDER"  "$PDNS_DB_PASS"       "dns/pdns.conf"
replace_in_file "PDNS_API_KEY_PLACEHOLDER"  "$PDNS_API_KEY"       "dns/pdns.conf"
replace_in_file "REDIS_PASS_PLACEHOLDER"    "$REDIS_PASS"         "php/php.ini"
replace_in_file "REDIS_PASS_PLACEHOLDER"    "$REDIS_PASS"         "redis/redis.conf"
replace_in_file "PDNS_ADMIN_DB_PASS"        "$PDNS_ADMIN_DB_PASS" "mariadb/init/01-init.sql"
replace_in_file "WEB_DB_PASS"               "$DB_PASS"            "mariadb/init/01-init.sql"

# Crear directorio sites-enabled
mkdir -p nginx/sites-enabled logs/{nginx,traefik,backup} data/{sites,backups}
touch nginx/sites-enabled/.gitkeep
log "Estructura de directorios creada"

# NOTA: Logrotate se instala en install.sh (con sustitución correcta de INSTALL_DIR)
# No instalamos aquí para evitar rutas incorrectas si INSTALL_DIR != /opt/hosting

# Instalar filtros fail2ban
if [[ -d "/etc/fail2ban/filter.d" ]] && [[ -d "fail2ban" ]]; then
  cp fail2ban/filter-*.conf /etc/fail2ban/filter.d/ 2>/dev/null || true
  log "Filtros fail2ban instalados"
fi

# ── Resumen ──────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${YELLOW}══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  CREDENCIALES GENERADAS — GUÁRDALAS EN LUGAR SEGURO${NC}"
echo -e "${BOLD}${YELLOW}══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}Servidor:${NC}         ${SERVER_IP} → ${DOMAIN}"
echo -e "  ${CYAN}MariaDB root:${NC}     ${DB_ROOT_PASS}"
echo -e "  ${CYAN}PowerDNS API:${NC}     ${PDNS_API_KEY}"
echo -e "  ${CYAN}Redis:${NC}            ${REDIS_PASS}"
echo -e "  ${CYAN}Traefik usuario:${NC}  admin"
echo -e "  ${CYAN}Traefik password:${NC} ${TRAEFIK_PASS}
  ${CYAN}SFTPGo admin:${NC}    ${SFTPGO_ADMIN_PASS}"
echo ""
echo -e "${YELLOW}  ⚠ También guardadas en .env (chmod 600)${NC}"
echo ""
echo -e "${GREEN}Siguientes pasos:${NC}"
echo "  sudo bash scripts/oracle-firewall.sh"
echo "  sudo bash install.sh"
echo ""

# BUG FIX v14: estas variables ya están en el heredoc principal de .env
# El bloque de append duplicaba entradas si setup-env.sh se ejecutaba más de una vez.
# Eliminado.
