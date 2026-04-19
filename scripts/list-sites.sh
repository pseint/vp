#!/usr/bin/env bash
set -uo pipefail
# =============================================================
# LIST-SITES — Lista todos los sitios web y zonas DNS activas
# Uso: ./scripts/list-sites.sh
# =============================================================
INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
[[ -f "$INSTALL_DIR/.env" ]] && source "$INSTALL_DIR/.env"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

echo -e "\n${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  SITIOS WEB Y DOMINIOS DNS ACTIVOS${NC}"
echo -e "${BOLD}${CYAN}  $(date '+%F %T')${NC}"
echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}"

# ── Virtual Hosts Nginx ───────────────────────────────────────
echo -e "\n${BOLD}Virtual Hosts Nginx activos:${NC}"
SITES_DIR="${INSTALL_DIR}/nginx/sites-enabled"
SITES_VOL=$(docker volume inspect hosting_sites-data \
  --format '{{.Mountpoint}}' 2>/dev/null || \
  echo "/var/lib/docker/volumes/hosting_sites-data/_data")

if [[ -d "$SITES_DIR" ]] && [[ -n "$(ls -A "$SITES_DIR" 2>/dev/null)" ]]; then
  printf "  ${BOLD}%-35s %-10s %-10s %s${NC}\n" "DOMINIO" "TIPO" "TAMAÑO" "BD"

  for conf in "${SITES_DIR}"/*.conf; do
    [[ -f "$conf" ]] || continue
    domain=$(basename "$conf" .conf)
    [[ "$domain" == "00-default" ]] && continue

    # Detectar tipo
    tipo="php"
    if grep -q "wp-login" "$conf" 2>/dev/null; then tipo="wordpress"; fi
    if ! grep -q "\.php" "$conf" 2>/dev/null; then tipo="static"; fi

    # Tamaño del sitio
    site_path="${SITES_VOL}/${domain}"
    if [[ -d "$site_path" ]]; then
      size=$(du -sh "$site_path" 2>/dev/null | cut -f1)
    else
      size="N/A"
    fi

    # Verificar si hay BD con el nombre del dominio
    db_name=$(echo "$domain" | tr '.' '_' | tr '-' '_')
    db_exists="—"
    if docker exec -e MYSQL_PWD="${DB_ROOT_PASS:-}" mariadb mariadb -uroot \
        -e "USE \`${db_name}\`;" &>/dev/null 2>&1; then
      db_exists="${db_name}"
    fi

    printf "  %-35s %-10s %-10s %s\n" "$domain" "$tipo" "$size" "$db_exists"
  done
else
  echo "  (ninguno)"
fi

# ── Zonas DNS PowerDNS ───────────────────────────────────────
echo -e "\n${BOLD}Zonas DNS en PowerDNS:${NC}"
# BUG FIX v15: subprocess.run con curl dentro de python exponía PDNS_API_KEY
# en la lista de procesos (visible con 'ps aux'). Reescrito con pipe curl|python3.
PDNS_ZONES_JSON=$(curl -sf \
  -H "X-API-Key: ${PDNS_API_KEY:-}" \
  "http://localhost:${PDNS_API_PORT:-8053}/api/v1/servers/localhost/zones" 2>/dev/null || echo "")

if [[ -n "$PDNS_ZONES_JSON" ]]; then
  echo "$PDNS_ZONES_JSON" | python3 -c "
import json, sys
try:
    zones = json.load(sys.stdin)
    if not zones:
        print('  (ninguna zona)')
    else:
        print(f'  {\"ZONA\":<40} {\"TIPO\":<10} {\"REGISTROS\":<10}')
        for z in sorted(zones, key=lambda x: x.get('name','')):
            name = z.get('name','').rstrip('.')
            kind = z.get('kind','N/A')
            rrsets = z.get('rrsets', [])
            print(f'  {name:<40} {kind:<10} {len(rrsets):<10}')
        print(f'\n  Total: {len(zones)} zona(s)')
except Exception as e:
    print(f'  Error leyendo zonas DNS: {e}')
" 2>/dev/null
else
  echo "  PowerDNS API no responde (¿está iniciado?)"
fi

# ── Bases de datos ────────────────────────────────────────────
echo -e "\n${BOLD}Bases de datos en MariaDB:${NC}"
if docker exec -e MYSQL_PWD="${DB_ROOT_PASS:-}" mariadb mariadb -uroot \
    -e ";" &>/dev/null 2>&1; then

  docker exec -e MYSQL_PWD="${DB_ROOT_PASS:-}" mariadb mariadb -uroot \
    --batch --skip-column-names \
    -e "SELECT table_schema, ROUND(SUM(data_length+index_length)/1024/1024,1) AS MB,
        COUNT(*) AS tablas
        FROM information_schema.tables
        WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys')
        GROUP BY table_schema
        ORDER BY MB DESC;" 2>/dev/null | \
    awk '{printf "  %-35s %6s MB  %s tablas\n", $1, $2, $3}'
else
  echo "  MariaDB no responde"
fi

# ── Resumen de recursos ────────────────────────────────────────
echo -e "\n${BOLD}Uso de disco:${NC}"
[[ -d "$SITES_VOL" ]] && \
  echo "  Sitios web: $(du -sh "$SITES_VOL" 2>/dev/null | cut -f1)"
BACKUP_DIR="${BACKUP_DIR:-/opt/hosting/data/backups}"
[[ -d "$BACKUP_DIR" ]] && \
  echo "  Backups:    $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)"
echo "  Logs:       $(du -sh "${INSTALL_DIR}/logs" 2>/dev/null | cut -f1)"

echo -e "\n${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}\n"
