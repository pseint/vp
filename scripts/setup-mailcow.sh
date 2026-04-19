#!/usr/bin/env bash
# =============================================================
# SETUP MAILCOW — Servidor de correo propio (Feature #3)
# Mailcow es la opción más robusta para self-hosted email
# Requisitos: ~2GB RAM extra, dominio configurado con DNS
# Uso: ./scripts/setup-mailcow.sh
# =============================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
[[ -f "$INSTALL_DIR/.env" ]] && source "$INSTALL_DIR/.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[⚠]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()  { echo -e "${CYAN}[→]${NC} $1"; }

MAILCOW_DIR="${INSTALL_DIR}/../mailcow-dockerized"
MAIL_DOMAIN="${MAIL_DOMAIN:-mail.${DOMAIN}}"

echo -e "${YELLOW}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║           INSTALACIÓN MAILCOW — SERVIDOR EMAIL       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Verificar RAM ─────────────────────────────────────────────
TOTAL_RAM=$(free -m | awk 'NR==2{print $2}')
if [[ "$TOTAL_RAM" -lt 3072 ]]; then
  warn "RAM disponible: ${TOTAL_RAM}MB — Mailcow necesita mínimo 3GB total"
  warn "Oracle Free Tier tiene 24GB — esto es suficiente."
  read -rp "¿Continuar de todas formas? [y/N] " confirm
  [[ "$confirm" != "y" ]] && exit 0
fi

# ── Verificar puertos necesarios ──────────────────────────────
# BUG FIX v15: check_port() usaba error() (exit 1), por lo que el `|| warn`
# del bucle NUNCA se ejecutaba — el script moría al encontrar el primer puerto ocupado.
# Reescrito para retornar código de salida 1 sin llamar exit.
check_port() {
  local port=$1
  if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
    return 1
  fi
  return 0
}

info "Verificando puertos de correo..."
PORTS_BUSY=()
for port in 25 465 587 143 993 110 995; do
  if ! check_port "$port"; then
    PORTS_BUSY+=("$port")
    warn "Puerto ${port} ya está en uso"
  fi
done
if [[ ${#PORTS_BUSY[@]} -gt 0 ]]; then
  warn "Puertos ocupados: ${PORTS_BUSY[*]} — Mailcow necesita estos puertos libres"
  read -rp "¿Continuar de todas formas? [y/N] " ports_confirm
  [[ "$ports_confirm" == "y" ]] || error "Cancelado — libera los puertos antes de continuar"
fi

# ── Preguntar configuración ────────────────────────────────────
read -rp "$(echo -e ${YELLOW})Dominio para el correo [mail.${DOMAIN}]: $(echo -e ${NC})" MAIL_HOSTNAME_INPUT
MAIL_HOSTNAME="${MAIL_HOSTNAME_INPUT:-mail.${DOMAIN}}"

echo ""
echo -e "${CYAN}Configuración Mailcow:${NC}"
echo "  Hostname: ${MAIL_HOSTNAME}"
echo "  Directorio: ${MAILCOW_DIR}"
echo "  RAM estimada: ~2-3GB"
echo ""
read -rp "¿Confirmar instalación? [y/N] " confirm
[[ "$confirm" != "y" ]] && { warn "Cancelado."; exit 0; }

# ── Instalar Mailcow ─────────────────────────────────────────
info "Clonando Mailcow..."
if [[ -d "$MAILCOW_DIR" ]]; then
  warn "Mailcow ya existe en ${MAILCOW_DIR}"
  cd "$MAILCOW_DIR"
  git pull origin master || true
else
  # BUG FIX v15: --depth 1 evita descargar ~500MB de historial git innecesario
  git clone --depth 1 https://github.com/mailcow/mailcow-dockerized "$MAILCOW_DIR"
  cd "$MAILCOW_DIR"
fi

# ── Generar configuración ─────────────────────────────────────
info "Generando mailcow.conf..."
if [[ ! -f mailcow.conf ]]; then
  MAILCOW_HOSTNAME="$MAIL_HOSTNAME" ./generate_config.sh
else
  warn "mailcow.conf ya existe — omitiendo generación"
fi

# ── Ajustar Mailcow para coexistir con nuestro Traefik ────────
info "Configurando integración con Traefik existente..."

# Deshabilitar el Nginx interno de Mailcow (usamos el nuestro via Traefik)
cat >> mailcow.conf << MCEOF

# Integración con Traefik existente
HTTP_BIND=127.0.0.1
HTTP_PORT=18080
HTTPS_BIND=127.0.0.1
HTTPS_PORT=18443
SKIP_LETS_ENCRYPT=y
ADDITIONAL_SERVER_NAMES=${MAIL_HOSTNAME}
MCEOF

log "mailcow.conf configurado"

# ── Abrir puertos en Oracle Firewall ─────────────────────────
info "Configurando firewall para puertos de correo..."
# Oracle Cloud requiere reglas de firewall tanto en iptables como en la consola web
iptables -I INPUT -p tcp -m multiport --dports 25,465,587,143,993,110,995,4190 -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p udp --dport 4190 -j ACCEPT 2>/dev/null || true

# Guardar reglas
if command -v netfilter-persistent &>/dev/null; then
  netfilter-persistent save
fi

warn "IMPORTANTE: También debes abrir estos puertos en la consola de Oracle Cloud:"
warn "  Networking → VCN → Security Lists → Ingress Rules:"
warn "  TCP: 25, 465, 587, 143, 993, 110, 995, 4190"

# ── Crear docker-compose.override para Traefik ───────────────
info "Creando override para exponer Mailcow vía Traefik..."
cat > docker-compose.override.yml << OVERRIDEEOF
# FIX: 'version:' eliminado — clave deprecada en Docker Compose v2
services:
  nginx-mailcow:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.mailcow.rule=Host(\`${MAIL_HOSTNAME}\`)"
      - "traefik.http.routers.mailcow.entrypoints=websecure"
      - "traefik.http.routers.mailcow.tls.certresolver=letsencrypt"
      - "traefik.http.services.mailcow.loadbalancer.server.port=18080"
    networks:
      hosting-net:
        aliases:
          - nginx-mailcow

networks:
  hosting-net:
    external: true
OVERRIDEEOF

log "Override Traefik creado"

# ── Instrucciones DNS ─────────────────────────────────────────
echo ""
echo -e "${YELLOW}══════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW} REGISTROS DNS QUE DEBES CONFIGURAR EN POWERDNS:${NC}"
echo -e "${YELLOW}══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}# A record para el servidor de correo:${NC}"
echo "  ${MAIL_HOSTNAME}.    IN A      ${SERVER_IP:-tu.ip.publica}"
echo ""
echo -e "${CYAN}# MX record (apunta al servidor de correo):${NC}"
echo "  ${DOMAIN}.           IN MX  10 ${MAIL_HOSTNAME}."
echo ""
echo -e "${CYAN}# SPF (permite al servidor enviar):${NC}"
echo "  ${DOMAIN}.           IN TXT \"v=spf1 mx a:${MAIL_HOSTNAME} ~all\""
echo ""
echo -e "${CYAN}# DMARC (política anti-spoofing):${NC}"
echo "  _dmarc.${DOMAIN}.   IN TXT \"v=DMARC1; p=quarantine; rua=mailto:dmarc@${DOMAIN}\""
echo ""
echo -e "${CYAN}# DKIM — generar después de iniciar Mailcow:${NC}"
echo "  docker compose -f ${MAILCOW_DIR}/docker-compose.yml exec rspamd-mailcow"
echo "  rspamadm dkim_keygen -s mail -d ${DOMAIN}"
echo ""
echo -e "${CYAN}# PTR record (requiere configuración en Oracle Cloud):${NC}"
echo "  ${SERVER_IP:-tu.ip}  →  ${MAIL_HOSTNAME}"
echo -e "${YELLOW}══════════════════════════════════════════════════════${NC}"

# ── Iniciar Mailcow ───────────────────────────────────────────
echo ""
read -rp "¿Iniciar Mailcow ahora? [y/N] " start_confirm
if [[ "$start_confirm" == "y" ]]; then
  info "Descargando imágenes Mailcow (puede tardar varios minutos)..."
  docker compose pull
  docker compose up -d
  log "Mailcow iniciado"
  echo ""
  echo -e "${GREEN}Acceso web:${NC}  https://${MAIL_HOSTNAME}"
  echo -e "${GREEN}Usuario:${NC}     admin"
  echo -e "${GREEN}Password:${NC}    moohoo  ← CAMBIA esto inmediatamente"
fi

echo ""
log "Setup de Mailcow completado"
warn "Recuerda configurar los registros DNS antes de enviar correos"
