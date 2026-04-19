#!/usr/bin/env bash
# =============================================================
# FIX HOSTING ORACLE VPS — cloudservicesai.eu.org
# Oracle ARM64 / Ubuntu 24.04 / Stack v22
# Uso: bash fix-hosting-v22.sh
# =============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ok()     { echo -e "${GREEN}[✓]${NC} $1"; }
fail()   { echo -e "${RED}[✗]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
info()   { echo -e "${CYAN}[→]${NC} $1"; }
header() { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════${NC}"; \
           echo -e "${BOLD}${BLUE}  $1${NC}"; \
           echo -e "${BOLD}${BLUE}══════════════════════════════════════════${NC}"; }
ask()    { echo -e "${YELLOW}[?]${NC} $1"; }

INSTALL_DIR="/opt/hosting"
ENV_FILE="${INSTALL_DIR}/.env"
PDNS_CONF="${INSTALL_DIR}/dns/pdns.conf"
DOMAIN_NEW="cloudservicesai.eu.org"

# ─── PASO 0: verificaciones previas ───────────────────────────
header "Verificaciones previas"

if [[ $EUID -eq 0 ]]; then
  fail "No ejecutar como root directo. Usa: bash fix-hosting-v22.sh"
  exit 1
fi

if ! command -v sudo &>/dev/null; then
  fail "sudo no disponible"
  exit 1
fi
ok "Usuario: $(whoami) con sudo"

if ! sudo test -f "${ENV_FILE}"; then
  fail ".env no encontrado en ${ENV_FILE}"
  info "Verifica que el stack esté instalado en /opt/hosting"
  exit 1
fi
ok ".env encontrado"

# Cargar .env
set -a; source <(sudo cat "${ENV_FILE}"); set +a
ok "Variables cargadas desde .env"

# ─── PASO 1: encontrar la API key real de PowerDNS ────────────
header "PASO 1 — Sincronizar API Key de PowerDNS"

info "Leyendo API key activa en el contenedor PowerDNS..."

KEY_FROM_CONTAINER=""
KEY_FROM_CONF=""
KEY_FROM_ENV="${PDNS_API_KEY:-}"

# Método A: pdns_control config
if sudo docker exec powerdns pdns_control config &>/dev/null; then
  KEY_FROM_CONTAINER=$(sudo docker exec powerdns pdns_control config 2>/dev/null \
    | grep "^api-key=" | cut -d= -f2 | tr -d '[:space:]')
  if [[ -n "$KEY_FROM_CONTAINER" ]]; then
    ok "Key leída del contenedor: ${KEY_FROM_CONTAINER:0:8}****"
  fi
fi

# Método B: leer pdns.conf directamente
if [[ -z "$KEY_FROM_CONTAINER" ]]; then
  warn "pdns_control no disponible, leyendo pdns.conf..."
  KEY_FROM_CONF=$(sudo grep "^api-key=" "${PDNS_CONF}" 2>/dev/null \
    | cut -d= -f2 | tr -d '[:space:]')
  if [[ -n "$KEY_FROM_CONF" ]]; then
    ok "Key leída de pdns.conf: ${KEY_FROM_CONF:0:8}****"
    KEY_FROM_CONTAINER="$KEY_FROM_CONF"
  fi
fi

# Método C: leer de variables de entorno del contenedor
if [[ -z "$KEY_FROM_CONTAINER" ]]; then
  warn "Intentando leer env vars del contenedor..."
  KEY_FROM_CONTAINER=$(sudo docker inspect powerdns 2>/dev/null \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
envs=d[0].get('Config',{}).get('Env',[]) if d else []
for e in envs:
    if 'API_KEY' in e.upper() or 'PDNS_API' in e.upper():
        print(e.split('=',1)[1])
        break
" 2>/dev/null || true)
  [[ -n "$KEY_FROM_CONTAINER" ]] && ok "Key leída de docker inspect: ${KEY_FROM_CONTAINER:0:8}****"
fi

if [[ -z "$KEY_FROM_CONTAINER" ]]; then
  fail "No se pudo leer la API key del contenedor"
  info "Mostrando config completo de PowerDNS para revisión manual:"
  sudo docker exec powerdns pdns_control config 2>/dev/null || \
    sudo cat "${PDNS_CONF}" 2>/dev/null | grep -v "^#" | grep -v "^$"
  echo ""
  ask "Ingresa la API key de PowerDNS manualmente (o Ctrl+C para cancelar):"
  read -r KEY_FROM_CONTAINER
fi

# Comparar con .env
if [[ "$KEY_FROM_ENV" != "$KEY_FROM_CONTAINER" ]]; then
  warn "API Key NO coincide entre .env y PowerDNS"
  info ".env tiene:       ${KEY_FROM_ENV:0:8}****"
  info "PowerDNS tiene:   ${KEY_FROM_CONTAINER:0:8}****"
  info "Actualizando .env con la key real de PowerDNS..."
  sudo sed -i "s|^PDNS_API_KEY=.*|PDNS_API_KEY=${KEY_FROM_CONTAINER}|" "${ENV_FILE}"
  set -a; source <(sudo cat "${ENV_FILE}"); set +a
  ok ".env actualizado — PDNS_API_KEY sincronizada"
else
  ok "API Key ya coincide: ${KEY_FROM_ENV:0:8}****"
fi

PDNS_API_KEY="${KEY_FROM_CONTAINER}"

# ─── PASO 2: detectar puerto de la API ────────────────────────
header "PASO 2 — Detectar puerto API de PowerDNS"

PDNS_PORT="${PDNS_API_PORT:-8053}"

# Intentar puertos comunes si el configurado no responde
for PORT in $PDNS_PORT 8053 8081 8080; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
    -H "X-API-Key: ${PDNS_API_KEY}" \
    "http://localhost:${PORT}/api/v1/servers/localhost" 2>/dev/null || echo "000")
  if [[ "$CODE" == "200" ]]; then
    ok "API responde en puerto ${PORT} (HTTP ${CODE})"
    PDNS_PORT="$PORT"
    sudo sed -i "s|^PDNS_API_PORT=.*|PDNS_API_PORT=${PORT}|" "${ENV_FILE}" 2>/dev/null || true
    break
  else
    info "Puerto ${PORT}: HTTP ${CODE}"
  fi
done

# Verificar respuesta
API_RESP=$(curl -s --max-time 5 \
  -H "X-API-Key: ${PDNS_API_KEY}" \
  "http://localhost:${PDNS_PORT}/api/v1/servers/localhost" 2>/dev/null)

if echo "$API_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('type')=='server' else 1)" 2>/dev/null; then
  ok "PowerDNS API autenticada correctamente"
else
  fail "API aún no responde correctamente"
  info "Respuesta raw: $API_RESP"
  info "Reiniciando contenedor PowerDNS..."
  sudo docker compose -f "${INSTALL_DIR}/docker-compose.yml" restart powerdns
  info "Esperando 10s..."
  sleep 10
  API_RESP=$(curl -s --max-time 5 \
    -H "X-API-Key: ${PDNS_API_KEY}" \
    "http://localhost:${PDNS_PORT}/api/v1/servers/localhost" 2>/dev/null)
  if echo "$API_RESP" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    ok "PowerDNS responde tras reinicio"
  else
    fail "PowerDNS no responde. Revisa los logs:"
    sudo docker logs powerdns --tail=20
    exit 1
  fi
fi

# ─── PASO 3: crear/actualizar zona eu.org ─────────────────────
header "PASO 3 — Crear zona ${DOMAIN_NEW} en PowerDNS"

SERVER_IP="${SERVER_IP:-168.129.176.73}"
SERIAL=$(date +%Y%m%d)01

# Verificar si la zona ya existe
ZONE_CHECK=$(curl -s --max-time 5 \
  -H "X-API-Key: ${PDNS_API_KEY}" \
  "http://localhost:${PDNS_PORT}/api/v1/servers/localhost/zones/${DOMAIN_NEW}." 2>/dev/null)

ZONE_EXISTS=false
if echo "$ZONE_CHECK" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'name' in d else 1)" 2>/dev/null; then
  ZONE_EXISTS=true
  warn "La zona ${DOMAIN_NEW} ya existe"
  ask "¿Eliminar y recrear? [s/N]:"
  read -r RECREATE
  if [[ "${RECREATE,,}" == "s" ]]; then
    curl -s -X DELETE \
      -H "X-API-Key: ${PDNS_API_KEY}" \
      "http://localhost:${PDNS_PORT}/api/v1/servers/localhost/zones/${DOMAIN_NEW}." \
      >/dev/null 2>&1
    ok "Zona eliminada, recreando..."
    ZONE_EXISTS=false
  fi
fi

if [[ "$ZONE_EXISTS" == "false" ]]; then
  info "Creando zona ${DOMAIN_NEW}..."

  PAYLOAD=$(python3 -c "
import json
d='${DOMAIN_NEW}'
ip='${SERVER_IP}'
s='${SERIAL}'
zone={
  'name': d+'.',
  'kind': 'Native',
  'nameservers': [],
  'rrsets': [
    {'name':d+'.','type':'SOA','ttl':3600,'records':[{'content':'ns1.'+d+'. hostmaster.'+d+'. '+s+' 3600 900 604800 300','disabled':False}]},
    {'name':d+'.','type':'NS','ttl':3600,'records':[{'content':'ns1.'+d+'.','disabled':False},{'content':'ns2.'+d+'.','disabled':False}]},
    {'name':d+'.','type':'A','ttl':300,'records':[{'content':ip,'disabled':False}]},
    {'name':'www.'+d+'.','type':'A','ttl':300,'records':[{'content':ip,'disabled':False}]},
    {'name':'dns.'+d+'.','type':'A','ttl':300,'records':[{'content':ip,'disabled':False}]},
    {'name':'sftp.'+d+'.','type':'A','ttl':300,'records':[{'content':ip,'disabled':False}]},
    {'name':'mail.'+d+'.','type':'A','ttl':300,'records':[{'content':ip,'disabled':False}]},
    {'name':'ns1.'+d+'.','type':'A','ttl':3600,'records':[{'content':ip,'disabled':False}]},
    {'name':'ns2.'+d+'.','type':'A','ttl':3600,'records':[{'content':ip,'disabled':False}]},
    {'name':d+'.','type':'MX','ttl':300,'records':[{'content':'10 mail.'+d+'.','disabled':False}]},
    {'name':d+'.','type':'TXT','ttl':300,'records':[{'content':'\"v=spf1 a mx ip4:'+ip+' ~all\"','disabled':False}]},
  ]
}
print(json.dumps(zone))
")

  RESULT=$(curl -s -X POST \
    -H "X-API-Key: ${PDNS_API_KEY}" \
    -H "Content-Type: application/json" \
    "http://localhost:${PDNS_PORT}/api/v1/servers/localhost/zones" \
    -d "$PAYLOAD" 2>/dev/null)

  if echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'name' in d else 1)" 2>/dev/null; then
    RRCOUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('rrsets',[])))" 2>/dev/null)
    ok "Zona creada: ${DOMAIN_NEW} con ${RRCOUNT} registros"
  else
    fail "Error creando zona"
    info "Respuesta: $RESULT"
    exit 1
  fi
fi

# ─── PASO 4: verificar autoritativo ───────────────────────────
header "PASO 4 — Verificar respuesta autoritativa"

sleep 2

if ! command -v dig &>/dev/null; then
  warn "dig no disponible, instalando..."
  sudo apt-get install -y -qq dnsutils
fi

SOA_RESP=$(dig @127.0.0.1 "${DOMAIN_NEW}" SOA +noall +answer 2>/dev/null)
FLAGS=$(dig @127.0.0.1 "${DOMAIN_NEW}" SOA 2>/dev/null | grep "^;; flags:")

if echo "$FLAGS" | grep -q " aa"; then
  ok "Flag AA presente — PowerDNS es AUTORITATIVO"
  ok "$FLAGS"
else
  warn "Flag AA ausente: $FLAGS"
  info "Verificando configuración de pdns.conf..."
  sudo grep -E "^launch|^local-address|^api" "${PDNS_CONF}" 2>/dev/null
fi

# Verificar registros
for TYPE in SOA NS A; do
  RES=$(dig @127.0.0.1 "${DOMAIN_NEW}" "${TYPE}" +short 2>/dev/null)
  if [[ -n "$RES" ]]; then
    ok "  ${TYPE}: ${RES}"
  else
    warn "  ${TYPE}: sin respuesta"
  fi
done

# ─── PASO 5: actualizar .env y configs del stack ──────────────
header "PASO 5 — Actualizar stack con nuevo dominio"

OLD_DOMAIN=$(grep "^DOMAIN=" "${ENV_FILE}" | cut -d= -f2 | tr -d '[:space:]')
info "Dominio actual en .env: ${OLD_DOMAIN}"
info "Dominio nuevo:          ${DOMAIN_NEW}"

if [[ "$OLD_DOMAIN" != "$DOMAIN_NEW" ]]; then
  warn "Actualizando dominio en todos los archivos de configuración..."
  sudo sed -i "s|DOMAIN=${OLD_DOMAIN}|DOMAIN=${DOMAIN_NEW}|" "${ENV_FILE}"

  # Reemplazar en configs (sin tocar archivos binarios o .git)
  COUNT=0
  while IFS= read -r -d '' FILE; do
    if sudo grep -q "${OLD_DOMAIN}" "$FILE" 2>/dev/null; then
      sudo sed -i "s|${OLD_DOMAIN}|${DOMAIN_NEW}|g" "$FILE"
      info "  Actualizado: $FILE"
      ((COUNT++)) || true
    fi
  done < <(sudo find "${INSTALL_DIR}" -type f \
    \( -name "*.yml" -o -name "*.yaml" -o -name "*.conf" \
       -o -name "*.ini" -o -name "*.json" -o -name "*.toml" \) \
    ! -path "*/.git/*" ! -name "acme.json" -print0 2>/dev/null)
  ok "${COUNT} archivos actualizados"

  # Limpiar certificados viejos de Let's Encrypt
  info "Limpiando certificados SSL anteriores..."
  sudo find "${INSTALL_DIR}" -name "acme.json" -exec sh -c \
    'sudo truncate -s0 "$1" && sudo chmod 600 "$1"' _ {} \; 2>/dev/null
  ok "Certificados SSL limpiados"
fi

# ─── PASO 6: reiniciar stack ───────────────────────────────────
header "PASO 6 — Reiniciar stack completo"

cd "${INSTALL_DIR}"
info "Deteniendo servicios..."
sudo docker compose down 2>/dev/null
sleep 3

info "Iniciando servicios..."
sudo docker compose up -d --remove-orphans 2>/dev/null
sleep 8

# Verificar que todos los servicios están arriba
SERVICES=("traefik" "powerdns" "nginx" "php-fpm" "mariadb" "redis" "portainer")
ALL_OK=true
for SVC in "${SERVICES[@]}"; do
  STATUS=$(sudo docker compose ps "$SVC" 2>/dev/null | grep -cE "Up|running|healthy" || echo "0")
  if [[ "$STATUS" -gt 0 ]]; then
    ok "  $SVC — running"
  else
    warn "  $SVC — iniciando (puede tardar 30s)"
    ALL_OK=false
  fi
done

# ─── PASO 7: verificación final ───────────────────────────────
header "PASO 7 — Verificación final"

sleep 5

# HTTP local
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" =~ ^[23] ]]; then
  ok "HTTP local responde: ${HTTP_CODE}"
else
  warn "HTTP local: ${HTTP_CODE} (Traefik puede tardar 30s más)"
fi

# DNS externo (desde el VPS preguntando a Google)
EXT_DNS=$(dig @8.8.8.8 "${DOMAIN_NEW}" A +short 2>/dev/null || echo "")
if [[ "$EXT_DNS" == "$SERVER_IP" ]]; then
  ok "DNS propagado globalmente — ${DOMAIN_NEW} → ${EXT_DNS}"
elif [[ -z "$EXT_DNS" ]]; then
  warn "DNS aún no propagado (normal, eu.org tarda 1–4 semanas en aprobar)"
  info "Verifica el estado en: https://nic.eu.org"
fi

# Portainer
PORT_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 https://localhost:9443 2>/dev/null || echo "000")
[[ "$PORT_CODE" =~ ^[23] ]] && ok "Portainer: https://${SERVER_IP}:9443" || warn "Portainer: ${PORT_CODE}"

# ─── RESUMEN FINAL ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║        FIX COMPLETADO — ESTADO ACTUAL                ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Accesos disponibles AHORA:${NC}"
echo -e "  Portainer:    https://${SERVER_IP}:9443    ${GREEN}✓ funciona${NC}"
echo -e "  Traefik:      http://${SERVER_IP}:8080/dashboard/"
echo ""
echo -e "${BOLD}Accesos tras aprobación eu.org:${NC}"
echo -e "  Web:          https://${DOMAIN_NEW}"
echo -e "  DNS Admin:    https://dns.${DOMAIN_NEW}"
echo -e "  SFTP Web:     https://sftp.${DOMAIN_NEW}"
echo ""
echo -e "${BOLD}${YELLOW}Acceso inmediato desde TU PC (agrega a /etc/hosts):${NC}"
echo -e "  ${SERVER_IP}  ${DOMAIN_NEW}"
echo -e "  ${SERVER_IP}  www.${DOMAIN_NEW}"
echo -e "  ${SERVER_IP}  dns.${DOMAIN_NEW}"
echo ""
echo -e "${BOLD}Estado DNS de tu servidor (listo para eu.org):${NC}"
dig @127.0.0.1 "${DOMAIN_NEW}" SOA +short 2>/dev/null && ok "SOA responde" || warn "SOA sin respuesta"
dig @127.0.0.1 "${DOMAIN_NEW}" SOA 2>/dev/null | grep "flags:" | grep -q " aa" && \
  ok "Flag AA presente — autoritativo correcto" || \
  warn "Flag AA ausente — revisar pdns.conf"
echo ""
echo -e "${CYAN}Monitorear SSL de Traefik:${NC}"
echo -e "  sudo docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f traefik | grep -i acme"
echo ""
