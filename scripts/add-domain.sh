#!/usr/bin/env bash
# =============================================================
# AGREGAR DOMINIO AL SERVIDOR DNS (PowerDNS) v5
# Uso: ./scripts/add-domain.sh dominio.com [IP] [TTL]
# Fix v5: SOA serial correcto, NS usa DOMAIN como fallback
# =============================================================
set -euo pipefail

DOMAIN="${1:-}"
IP="${2:-}"
TTL="${3:-300}"
INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[⚠]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[[ -f "$INSTALL_DIR/.env" ]] && source "$INSTALL_DIR/.env"

[[ -z "$DOMAIN" ]] && error "Uso: $0 dominio.com [IP] [TTL]"

# BUG FIX #15: SERVER_DOMAIN puede no estar definido — usar DOMAIN del servidor como NS
# El SERVER_DOMAIN es el dominio del propio servidor (donde están ns1/ns2)
NS_DOMAIN="${SERVER_DOMAIN:-${DOMAIN}}"
IP="${IP:-${SERVER_IP:-}}"
[[ -z "$IP" ]] && error "Especifica una IP: $0 dominio.com 1.2.3.4"

echo -e "${YELLOW}Agregando dominio: ${DOMAIN} → ${IP}${NC}"
echo "  Nameservers: ns1.${NS_DOMAIN} / ns2.${NS_DOMAIN}"

PDNS_API_URL="http://localhost:${PDNS_API_PORT:-8053}"
HEADERS=(-H "X-API-Key: ${PDNS_API_KEY}" -H "Content-Type: application/json")

# ── Verificar si ya existe ────────────────────────────────────
EXISTING=$(curl -sf "${HEADERS[@]}" \
  "${PDNS_API_URL}/api/v1/servers/localhost/zones/${DOMAIN}." 2>/dev/null || echo "")

if [[ -n "$EXISTING" ]] && echo "$EXISTING" | grep -q '"id"'; then
  warn "El dominio ${DOMAIN} ya existe. Actualizando registros..."
  ACTION="update"
else
  ACTION="create"
fi

# BUG FIX #15: SOA serial en formato YYYYMMDDNN (10 dígitos estándar DNS)
# Usar segundos desde epoch como serial garantiza unicidad siempre
SOA_SERIAL=$(date +%s)

if [[ "$ACTION" == "create" ]]; then
  curl -sf -X POST \
    "${HEADERS[@]}" \
    "${PDNS_API_URL}/api/v1/servers/localhost/zones" \
    -d "{
      \"name\": \"${DOMAIN}.\",
      \"kind\": \"Native\",
      \"nameservers\": [],
      \"rrsets\": []
    }" > /dev/null
  log "Zona ${DOMAIN} creada"
fi

# ── Registros DNS completos ────────────────────────────────────
RRSETS=$(python3 - << PYEOF
import json

domain = "${DOMAIN}"
ns_domain = "${NS_DOMAIN}"
ip = "${IP}"
ttl = int("${TTL}")
serial = ${SOA_SERIAL}

rrsets = [
    {
        "name": f"{domain}.",
        "type": "SOA",
        "ttl": 3600,
        "changetype": "REPLACE",
        "records": [{
            "content": f"ns1.{ns_domain}. hostmaster.{domain}. {serial} 3600 900 604800 300",
            "disabled": False
        }]
    },
    {
        "name": f"{domain}.",
        "type": "NS",
        "ttl": 3600,
        "changetype": "REPLACE",
        "records": [
            {"content": f"ns1.{ns_domain}.", "disabled": False},
            {"content": f"ns2.{ns_domain}.", "disabled": False}
        ]
    },
    {
        "name": f"{domain}.",
        "type": "A",
        "ttl": ttl,
        "changetype": "REPLACE",
        "records": [{"content": ip, "disabled": False}]
    },
    {
        "name": f"www.{domain}.",
        "type": "A",
        "ttl": ttl,
        "changetype": "REPLACE",
        "records": [{"content": ip, "disabled": False}]
    },
    {
        "name": f"mail.{domain}.",
        "type": "A",
        "ttl": ttl,
        "changetype": "REPLACE",
        "records": [{"content": ip, "disabled": False}]
    },
    {
        "name": f"{domain}.",
        "type": "MX",
        "ttl": ttl,
        "changetype": "REPLACE",
        "records": [{"content": f"10 mail.{domain}.", "disabled": False}]
    },
    {
        "name": f"{domain}.",
        "type": "TXT",
        "ttl": ttl,
        "changetype": "REPLACE",
        "records": [{"content": f'"v=spf1 a mx ip4:{ip} ~all"', "disabled": False}]
    },
    {
        "name": f"_dmarc.{domain}.",
        "type": "TXT",
        "ttl": ttl,
        "changetype": "REPLACE",
        "records": [{"content": f'"v=DMARC1; p=quarantine; rua=mailto:dmarc@{domain}; pct=100"', "disabled": False}]
    },
    {
        # CAA — solo Let's Encrypt puede emitir certificados para este dominio
        # Mejora la seguridad SSL evitando que otras CA emitan certs sin permiso
        "name": f"{domain}.",
        "type": "CAA",
        "ttl": 3600,
        "changetype": "REPLACE",
        "records": [
            {"content": '0 issue "letsencrypt.org"', "disabled": False},
            {"content": '0 issuewild "letsencrypt.org"', "disabled": False}
        ]
    },
    {
        # DKIM placeholder: reemplazar <DKIM_PUBLIC_KEY> con la clave real tras configurar el servidor de correo
        "name": f"mail._domainkey.{domain}.",
        "type": "TXT",
        "ttl": ttl,
        "changetype": "REPLACE",
        "records": [{"content": '"v=DKIM1; k=rsa; p="', "disabled": True}]
    }
]

print(json.dumps({"rrsets": rrsets}))
PYEOF
)

curl -sf -X PATCH \
  "${HEADERS[@]}" \
  "${PDNS_API_URL}/api/v1/servers/localhost/zones/${DOMAIN}." \
  -d "$RRSETS" > /dev/null && log "Registros DNS configurados para ${DOMAIN}"

echo ""
echo -e "${YELLOW}Registros creados:${NC}"
echo "  ${DOMAIN}        A     ${IP}"
echo "  www.${DOMAIN}    A     ${IP}"
echo "  mail.${DOMAIN}   A     ${IP}"
echo "  ${DOMAIN}        NS    ns1.${NS_DOMAIN} / ns2.${NS_DOMAIN}"
echo "  ${DOMAIN}        MX    10 mail.${DOMAIN}."
echo "  ${DOMAIN}        TXT   v=spf1 a mx ip4:${IP} ~all"
echo "  _dmarc.${DOMAIN}  TXT   v=DMARC1; p=quarantine; rua=mailto:dmarc@${DOMAIN}"
echo "  ${DOMAIN}        CAA   0 issue letsencrypt.org"
echo ""
echo -e "${YELLOW}Próximos pasos:${NC}"
echo "  1. Agrega el sitio: ./scripts/add-vhost.sh ${DOMAIN}"
echo "  2. Verifica DNS:    dig @${IP} ${DOMAIN}"
echo "  3. Si el dominio es diferente al principal, apunta los NS en el registrador"
echo ""
echo -e "${YELLOW}Para configurar DKIM (evitar spam):${NC}"
echo "  1. Genera el par de claves DKIM:"
echo "     docker exec powerdns pdnsutil add-zone-key ${DOMAIN} ksk ecdsa256"
echo "  O con OpenSSL:"
echo "     openssl genrsa -out /tmp/dkim.key 2048"
echo "     openssl rsa -in /tmp/dkim.key -pubout -out /tmp/dkim.pub"
echo "  2. Añade el registro TXT en PowerDNS Admin:"
echo "     mail._domainkey.${DOMAIN}  TXT  "v=DKIM1; k=rsa; p=<TU_CLAVE_PUBLICA>""
