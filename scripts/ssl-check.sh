#!/usr/bin/env bash
set -uo pipefail
# =============================================================
# SSL-CHECK — Verifica estado y vencimiento de certificados SSL
# Uso: ./scripts/ssl-check.sh [dominio]
# Sin argumento: verifica todos los dominios activos
# =============================================================
INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
[[ -f "$INSTALL_DIR/.env" ]] && source "$INSTALL_DIR/.env"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { printf "${GREEN}%-45s %-12s %s${NC}\n" "$1" "✓ OK"     "$2"; }
warn() { printf "${YELLOW}%-45s %-12s %s${NC}\n" "$1" "⚠ PRONTO" "$2"; }
fail() { printf "${RED}%-45s %-12s %s${NC}\n"   "$1" "✗ ERROR"  "$2"; }

check_domain_ssl() {
  local domain="$1"
  local port="${2:-443}"

  # Obtener info del certificado
  local cert_info
  cert_info=$(echo | timeout 5 openssl s_client \
    -servername "$domain" \
    -connect "${domain}:${port}" 2>/dev/null | \
    openssl x509 -noout -dates -subject -issuer 2>/dev/null) || {
    fail "$domain" "No responde / Sin SSL"
    return
  }

  local not_after
  not_after=$(echo "$cert_info" | grep "notAfter" | cut -d= -f2)
  local issuer
  issuer=$(echo "$cert_info" | grep "issuer" | sed 's/.*O = //' | cut -d, -f1 | cut -c1-20)

  # Calcular días restantes
  local expire_epoch
  expire_epoch=$(date -d "$not_after" +%s 2>/dev/null || \
                 date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null || echo 0)
  local now_epoch
  now_epoch=$(date +%s)
  local days_left=$(( (expire_epoch - now_epoch) / 86400 ))

  local expire_str
  expire_str=$(date -d "$not_after" '+%Y-%m-%d' 2>/dev/null || echo "$not_after")

  if [[ $days_left -lt 0 ]]; then
    fail "$domain" "EXPIRADO hace $((days_left * -1)) días | $issuer"
  elif [[ $days_left -lt 14 ]]; then
    warn "$domain" "${days_left}d restantes (${expire_str}) | $issuer"
  else
    ok "$domain" "${days_left}d restantes (${expire_str}) | $issuer"
  fi
}

echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  VERIFICACIÓN DE CERTIFICADOS SSL${NC}"
echo -e "${BOLD}${CYAN}  $(date '+%F %T')${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}\n"

printf "${BOLD}%-45s %-12s %s${NC}\n" "DOMINIO" "ESTADO" "DETALLE"
printf "%-45s %-12s %s\n" "$(printf '%.0s-' {1..44})" "$(printf '%.0s-' {1..11})" "$(printf '%.0s-' {1..20})"

# ── Dominio especificado o todos ──────────────────────────────
if [[ -n "${1:-}" ]]; then
  check_domain_ssl "$1"
else
  # Verificar dominio principal
  [[ -n "${DOMAIN:-}" ]] && check_domain_ssl "$DOMAIN"
  [[ -n "${DOMAIN:-}" ]] && check_domain_ssl "www.${DOMAIN}"
  [[ -n "${DOMAIN:-}" ]] && check_domain_ssl "traefik.${DOMAIN}"
  [[ -n "${DOMAIN:-}" ]] && check_domain_ssl "dns.${DOMAIN}"
  [[ -n "${DOMAIN:-}" ]] && check_domain_ssl "portainer.${DOMAIN}"

  # Verificar todos los vhosts activos
  NGINX_SITES="${INSTALL_DIR}/nginx/sites-enabled"
  if [[ -d "$NGINX_SITES" ]]; then
    while IFS= read -r conf_file; do
      [[ -f "$conf_file" ]] || continue
      # Extraer server_name del conf
      while IFS= read -r sn; do
        [[ -z "$sn" || "$sn" == "_" ]] && continue
        [[ "$sn" == www.* ]] && continue  # Evitar duplicados
        check_domain_ssl "$sn"
      done < <(grep -oP 'server_name\s+\K[^;]+' "$conf_file" 2>/dev/null | \
               tr ' ' '\n' | grep -v '^$' | sort -u)
    done < <(find "$NGINX_SITES" -name "*.conf" -type f)
  fi

  # Verificar también desde acme.json
  ACME_VOL=$(docker volume inspect hosting_traefik-acme \
    --format '{{.Mountpoint}}' 2>/dev/null || echo "")
  if [[ -n "$ACME_VOL" && -f "${ACME_VOL}/acme.json" ]]; then
    echo ""
    echo -e "${BOLD}Certificados en Traefik ACME:${NC}"
    python3 -c "
import json, sys
try:
    with open('${ACME_VOL}/acme.json') as f:
        d = json.load(f)
    certs = []
    for resolver, data in d.items():
        for cert in data.get('Certificates', []):
            domain = cert.get('domain', {}).get('main', 'N/A')
            certs.append(domain)
    print('  Dominios con cert: ' + str(len(certs)))
    for c in sorted(set(certs)):
        print(f'  → {c}')
except Exception as e:
    print(f'  Error leyendo acme.json: {e}')
" 2>/dev/null || true
  fi
fi

echo ""
echo -e "${YELLOW}Traefik renueva automáticamente los certs 30 días antes de expirar.${NC}"
echo -e "Para renovar manualmente: ${CYAN}docker compose restart traefik${NC}"
echo ""

# ── Auto-renovación si hay certs próximos a expirar ──────────
auto_renew_if_needed() {
  local any_expiring=false

  for conf in "${INSTALL_DIR}/nginx/sites-enabled"/*.conf; do
    [[ -f "$conf" ]] || continue
    domain=$(grep -oP 'server_name\s+\K[^\s;]+' "$conf" 2>/dev/null | head -1)
    [[ -z "$domain" || "$domain" == "_" ]] && continue

    expire_epoch=$(echo | timeout 5 openssl s_client \
      -servername "$domain" -connect "${domain}:443" 2>/dev/null | \
      openssl x509 -noout -enddate 2>/dev/null | \
      cut -d= -f2 | xargs -I{} date -d "{}" +%s 2>/dev/null || echo 0)

    days_left=$(( (expire_epoch - $(date +%s)) / 86400 ))

    if [[ "$days_left" -lt 14 && "$days_left" -gt 0 ]]; then
      any_expiring=true
      echo -e "${YELLOW}  ⚠ ${domain}: ${days_left}d → forzando renovación...${NC}"
    fi
  done

  if [[ "$any_expiring" == "true" ]]; then
    echo ""
    echo -e "${CYAN}Reiniciando Traefik para forzar renovación ACME...${NC}"
    cd "${INSTALL_DIR}" && docker compose restart traefik
    echo -e "${GREEN}Traefik reiniciado — los certs se renovarán en los próximos minutos${NC}"
  fi
}

# Solo ejecutar si se llama sin argumento (verificación completa)
[[ -z "${1:-}" ]] && auto_renew_if_needed
