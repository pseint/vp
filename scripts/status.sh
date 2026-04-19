#!/usr/bin/env bash
set -uo pipefail
# =============================================================
# DIAGNÓSTICO v22 — Estado completo del servidor hosting
# Uso: ./scripts/status.sh
# =============================================================
INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
[[ -f "$INSTALL_DIR/.env" ]] && source "$INSTALL_DIR/.env"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { printf "${GREEN}  %-38s %-8s${NC} %s\n" "$1" "✓ OK" "$2"; }
fail() { printf "${RED}  %-38s %-8s${NC} %s\n"   "$1" "✗ ERR" "$2"; }
warn() { printf "${YELLOW}  %-38s %-8s${NC} %s\n" "$1" "⚠ WARN" "$2"; }

echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  DIAGNÓSTICO DEL SERVIDOR — v22${NC}"
echo -e "${BOLD}${CYAN}  $(date '+%F %T') | $(hostname)${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}\n"

# ── Sistema ───────────────────────────────────────────────────
echo -e "${BOLD}Sistema:${NC}"
echo "  Kernel:     $(uname -r) [$(uname -m)]"
echo "  Uptime:     $(uptime -p 2>/dev/null || uptime)"
LOAD=$(awk '{print $1}' /proc/loadavg)
CORES=$(nproc)
echo "  Load avg:   $(cat /proc/loadavg | awk '{print $1, $2, $3}') (${CORES} cores)"
echo ""

# ── RAM ───────────────────────────────────────────────────────
echo -e "${BOLD}Memoria:${NC}"
free -h | awk 'NR==2 {printf "  Total: %s  Usada: %s  Disponible: %s\n", $2, $3, $7}'
SWAP=$(free -h | awk 'NR==3 {print $3"/"$2}')
echo "  Swap:       ${SWAP}"
echo ""

# ── Disco ─────────────────────────────────────────────────────
echo -e "${BOLD}Disco:${NC}"
df -h / | awk 'NR==2 {printf "  Raíz: %s total, %s usado (%s)\n", $2, $3, $5}'
SITES_VOL=$(docker volume inspect hosting_sites-data --format '{{.Mountpoint}}' 2>/dev/null || echo "")
[[ -n "$SITES_VOL" ]] && echo "  Sitios web: $(du -sh "$SITES_VOL" 2>/dev/null | cut -f1)"
NGINX_CACHE=$(docker volume inspect hosting_nginx-cache --format '{{.Mountpoint}}' 2>/dev/null || echo "")
[[ -n "$NGINX_CACHE" ]] && echo "  Nginx cache: $(du -sh "$NGINX_CACHE" 2>/dev/null | cut -f1)"
echo "  Logs:       $(du -sh "${INSTALL_DIR}/logs" 2>/dev/null | cut -f1)"
BACKUP_DIR="${BACKUP_DIR:-/opt/hosting/data/backups}"
[[ -d "$BACKUP_DIR" ]] && echo "  Backups:    $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)"
echo ""

# ── Contenedores ──────────────────────────────────────────────
echo -e "${BOLD}Contenedores:${NC}"
SERVICES=("traefik" "powerdns" "pdns-admin" "nginx" "php-fpm" "mariadb" "redis" "portainer")
for svc in "${SERVICES[@]}"; do
  STATUS=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "not found")
  if [[ "$STATUS" == "running" ]]; then
    STATS=$(docker stats --no-stream --format='Mem:{{.MemUsage}} CPU:{{.CPUPerc}}' "$svc" 2>/dev/null | \
            awk '{print $1"  "$2}' || echo "")
    ok "$svc" "$STATS"
  else
    fail "$svc" "$STATUS"
  fi
done

# SFTPGo (optional)
if docker inspect sftpgo &>/dev/null 2>&1; then
  STATUS=$(docker inspect --format='{{.State.Status}}' "sftpgo" 2>/dev/null || echo "not found")
  if [[ "$STATUS" == "running" ]]; then
    STATS=$(docker stats --no-stream --format='Mem:{{.MemUsage}} CPU:{{.CPUPerc}}' "sftpgo" 2>/dev/null | \
            awk '{print $1"  "$2}' || echo "")
    ok "sftpgo (opcional)" "$STATS"
  else
    warn "sftpgo" "$STATUS"
  fi
fi
echo ""

# ── Puertos ───────────────────────────────────────────────────
echo -e "${BOLD}Puertos en escucha:${NC}"
# FIX 20: add port 2022 check for SFTPGo
PORTS_CHECK=(22 80 443 53 8080 9443)
PORTS_NAMES=("SSH" "HTTP" "HTTPS" "DNS" "Traefik" "Portainer")
for i in "${!PORTS_CHECK[@]}"; do
  port="${PORTS_CHECK[$i]}"
  name="${PORTS_NAMES[$i]}"
  if ss -tuln 2>/dev/null | grep -q ":${port} "; then
    ok "Puerto ${port} (${name})" ""
  else
    fail "Puerto ${port} (${name})" "cerrado"
  fi
done

# SFTPGo puerto 2022 (solo si está activo)
if docker inspect sftpgo &>/dev/null 2>&1; then
  if ss -tuln 2>/dev/null | grep -q ":2022 "; then
    ok "Puerto 2022 (SFTPGo)" ""
  else
    warn "Puerto 2022 (SFTPGo)" "no escucha"
  fi
fi
echo ""

# ── DNS ───────────────────────────────────────────────────────
echo -e "${BOLD}PowerDNS:${NC}"
if curl -sf -H "X-API-Key: ${PDNS_API_KEY:-}" \
    "http://localhost:8053/api/v1/servers/localhost" &>/dev/null; then
  ZONES=$(curl -sf -H "X-API-Key: ${PDNS_API_KEY:-}" \
    "http://localhost:8053/api/v1/servers/localhost/zones" 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "?")
  ok "API PowerDNS" "Zonas activas: ${ZONES}"
else
  fail "API PowerDNS" "no responde"
fi
echo ""

# ── SSL ───────────────────────────────────────────────────────
echo -e "${BOLD}Certificados SSL (Traefik ACME):${NC}"
ACME_VOL=$(docker volume inspect hosting_traefik-acme \
  --format '{{.Mountpoint}}' 2>/dev/null || echo "")
if [[ -n "$ACME_VOL" && -f "${ACME_VOL}/acme.json" ]]; then
  python3 - "${ACME_VOL}/acme.json" << 'PYEOF'
import json, sys, datetime
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    certs = []
    for resolver, data in d.items():
        for cert in data.get('Certificates', []):
            main = cert.get('domain', {}).get('main', 'N/A')
            certs.append(main)
    total = len(set(certs))
    print(f"  ✓ {total} dominio(s) con certificado SSL activo:")
    for c in sorted(set(certs))[:10]:
        print(f"    → {c}")
    if total > 10:
        print(f"    ... y {total-10} más")
except Exception as e:
    print(f"  ⚠ Error leyendo acme.json: {e}")
PYEOF
else
  warn "Certificados ACME" "acme.json aún no generado"
fi
echo ""

# ── Último backup ─────────────────────────────────────────────
echo -e "${BOLD}Último backup:${NC}"
if [[ -d "$BACKUP_DIR" ]]; then
  LAST=$(ls -t "$BACKUP_DIR" 2>/dev/null | head -1)
  if [[ -n "$LAST" ]]; then
    SIZE=$(du -sh "${BACKUP_DIR}/${LAST}" 2>/dev/null | cut -f1)
    ok "Último backup" "${LAST} (${SIZE})"
  else
    warn "Backups" "ninguno encontrado en ${BACKUP_DIR}"
  fi
fi
echo ""

# ── Fail2ban ──────────────────────────────────────────────────
echo -e "${BOLD}Fail2ban:${NC}"
if systemctl is-active fail2ban &>/dev/null; then
  BANNED=$(fail2ban-client status 2>/dev/null | grep "Jail list" | \
           sed 's/.*Jail list:\s*//' | tr ',' '\n' | \
           while read jail; do
             [[ -z "$jail" ]] && continue
             fail2ban-client status "$jail" 2>/dev/null | \
               grep "Currently banned" | awk '{sum+=$NF} END{print sum}'
           done | awk '{sum+=$1} END{print sum}')
  ok "Fail2ban activo" "IPs baneadas actualmente: ${BANNED:-0}"
else
  warn "Fail2ban" "no activo"
fi
echo ""

# ── URLs ──────────────────────────────────────────────────────
echo -e "${BOLD}URLs del servidor:${NC}"
echo "  🌐  Web:         https://${DOMAIN:-[configura DOMAIN en .env]}"
echo "  🔀  Traefik:     http://${SERVER_IP:-[ip]}:8080"
echo "  🐳  Portainer:   https://${SERVER_IP:-[ip]}:9443"
echo "  🌍  DNS Admin:   https://dns.${DOMAIN:-[tu-dominio]}"
[[ -n "${DOMAIN:-}" ]] && echo "  📦  Billing:     https://billing.${DOMAIN}"

echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${NC}\n"
