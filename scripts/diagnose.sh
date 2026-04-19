#!/usr/bin/env bash
# =============================================================
# DIAGNOSE v1 — Diagnóstico completo de red, stack y servicios
# Uso: ./scripts/diagnose.sh [--full|--net|--stack|--ssl|--dns]
# Sin argumento: ejecuta diagnóstico completo
# =============================================================
set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
[[ -f "$INSTALL_DIR/.env" ]] && source "$INSTALL_DIR/.env"

MODE="${1:---full}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; WARN=0; FAIL=0

ok()   { echo -e "  ${GREEN}✓${NC}  $1"; ((PASS++)) || true; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; ((WARN++)) || true; }
fail() { echo -e "  ${RED}✗${NC}  $1"; ((FAIL++)) || true; }
info() { echo -e "  ${CYAN}→${NC}  $1"; }
header() {
  echo ""
  echo -e "${BOLD}${CYAN}══ $1 ══${NC}"
}

# ── Información del sistema ───────────────────────────────────
diag_system() {
  header "SISTEMA"
  info "Hostname:    $(hostname -f 2>/dev/null || hostname)"
  info "OS:          $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"' || uname -s)"
  info "Kernel:      $(uname -r)"
  info "Arch:        $(uname -m)"
  info "Uptime:      $(uptime -p 2>/dev/null || uptime)"
  info "Fecha:       $(date)"

  # Disco
  local disk_pct
  disk_pct=$(df / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
  if [[ "$disk_pct" -gt 90 ]]; then
    fail "Disco /: ${disk_pct}% usado (crítico)"
  elif [[ "$disk_pct" -gt 75 ]]; then
    warn "Disco /: ${disk_pct}% usado"
  else
    ok "Disco /: ${disk_pct}% usado"
  fi

  # RAM
  local ram_avail
  ram_avail=$(free -m | awk 'NR==2 {print $7}')
  if [[ "$ram_avail" -lt 256 ]]; then
    fail "RAM disponible: ${ram_avail}MB (crítico)"
  elif [[ "$ram_avail" -lt 512 ]]; then
    warn "RAM disponible: ${ram_avail}MB"
  else
    ok "RAM disponible: ${ram_avail}MB"
  fi

  # Swap
  local swap_total
  swap_total=$(free -m | awk '/Swap/ {print $2}')
  if [[ "$swap_total" -eq 0 ]]; then
    warn "Sin swap configurado (recomendado 2GB)"
  else
    ok "Swap: ${swap_total}MB configurado"
  fi

  # Load
  local load cores
  load=$(awk '{print $1}' /proc/loadavg | awk -F. '{print $1}')
  cores=$(nproc)
  if [[ "$load" -gt "$((cores * 2))" ]]; then
    warn "Carga CPU alta: ${load} en ${cores} cores"
  else
    ok "Carga CPU: ${load} en ${cores} cores"
  fi
}

# ── Diagnóstico de red ────────────────────────────────────────
diag_network() {
  header "RED"

  # IP pública
  local pub_ip
  pub_ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || \
           curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || echo "N/A")
  info "IP pública detectada: ${pub_ip}"
  if [[ -n "${SERVER_IP:-}" && "$pub_ip" != "$SERVER_IP" ]]; then
    warn "SERVER_IP en .env (${SERVER_IP}) no coincide con IP pública detectada (${pub_ip})"
  fi

  # Conectividad saliente
  for host in "1.1.1.1" "8.8.8.8" "google.com"; do
    if ping -c 1 -W 3 "$host" &>/dev/null 2>&1; then
      ok "Ping a ${host}: OK"
    else
      fail "Ping a ${host}: sin respuesta"
    fi
  done

  # Puertos escuchando
  header "PUERTOS ABIERTOS"
  local expected_ports=(22 80 443 53 8080 9443 2022)
  for port in "${expected_ports[@]}"; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
       ss -ulnp 2>/dev/null | grep -q ":${port} "; then
      ok "Puerto ${port}: escuchando"
    else
      warn "Puerto ${port}: no detectado en ss (puede estar detrás de Docker)"
    fi
  done

  # DNS local
  header "DNS LOCAL"
  if command -v dig &>/dev/null; then
    local dns_resp
    dns_resp=$(dig +short +time=3 google.com @127.0.0.1 2>/dev/null | head -1)
    if [[ -n "$dns_resp" ]]; then
      ok "PowerDNS local responde: google.com → ${dns_resp}"
    else
      fail "PowerDNS local no responde en 127.0.0.1:53"
    fi
    # DNS propio del dominio
    if [[ -n "${DOMAIN:-}" ]]; then
      dns_resp=$(dig +short +time=3 "${DOMAIN}" @127.0.0.1 2>/dev/null | head -1)
      if [[ -n "$dns_resp" ]]; then
        ok "Zona propia ${DOMAIN}: resuelve a ${dns_resp}"
      else
        warn "Zona propia ${DOMAIN}: no resuelve en DNS local (¿zona creada?)"
      fi
    fi
  else
    warn "dig no instalado — omitiendo diagnóstico DNS (instala: apt install dnsutils)"
  fi
}

# ── Diagnóstico del stack Docker ──────────────────────────────
diag_stack() {
  header "DOCKER"

  if ! command -v docker &>/dev/null; then
    fail "Docker no instalado"
    return
  fi
  ok "Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"

  if ! docker compose version &>/dev/null 2>&1; then
    fail "Docker Compose plugin no disponible"
    return
  fi
  ok "Compose: $(docker compose version --short 2>/dev/null || echo 'OK')"

  # Red hosting-net
  if docker network inspect hosting-net &>/dev/null; then
    ok "Red hosting-net: existe"
  else
    fail "Red hosting-net: NO existe (ejecuta: docker network create --subnet 172.20.0.0/16 hosting-net)"
  fi

  header "CONTENEDORES"
  local services=(traefik powerdns pdns-admin nginx php-fpm mariadb redis portainer)
  for svc in "${services[@]}"; do
    local status health
    status=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "missing")
    health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
             "$svc" 2>/dev/null || echo "unknown")

    if [[ "$status" == "missing" ]]; then
      fail "${svc}: no encontrado"
    elif [[ "$status" != "running" ]]; then
      fail "${svc}: ${status}"
    elif [[ "$health" == "unhealthy" ]]; then
      warn "${svc}: running pero UNHEALTHY"
    elif [[ "$health" == "healthy" ]]; then
      ok "${svc}: running + healthy"
    else
      ok "${svc}: running"
    fi
  done

  # Uso de recursos
  header "RECURSOS DOCKER"
  info "Uso de imágenes:"
  docker system df 2>/dev/null | tail -n +1 | while IFS= read -r line; do
    info "  $line"
  done
}

# ── Diagnóstico HTTP/HTTPS ────────────────────────────────────
diag_http() {
  header "HTTP / HTTPS"

  # HTTP local
  local http_code
  http_code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 http://localhost 2>/dev/null || echo "000")
  if [[ "$http_code" =~ ^(200|301|302)$ ]]; then
    ok "HTTP localhost: ${http_code}"
  else
    fail "HTTP localhost: ${http_code} (esperado 200/301/302)"
  fi

  # HTTPS local (si hay dominio)
  if [[ -n "${DOMAIN:-}" ]]; then
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 \
      -H "Host: ${DOMAIN}" https://localhost --insecure 2>/dev/null || echo "000")
    if [[ "$http_code" =~ ^(200|301|302)$ ]]; then
      ok "HTTPS (Host: ${DOMAIN}): ${http_code}"
    else
      warn "HTTPS (Host: ${DOMAIN}): ${http_code}"
    fi

    # Traefik dashboard
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 \
      http://localhost:8080/ping 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" ]]; then
      ok "Traefik /ping: 200 OK"
    else
      fail "Traefik /ping: ${http_code}"
    fi
  fi

  # Nginx health endpoint
  http_code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 \
    -H "Host: localhost" http://localhost/nginx-health 2>/dev/null || echo "000")
  if [[ "$http_code" == "200" ]]; then
    ok "Nginx /nginx-health: 200 OK"
  else
    warn "Nginx /nginx-health: ${http_code}"
  fi
}

# ── Diagnóstico SSL ───────────────────────────────────────────
diag_ssl() {
  header "SSL / TLS"

  if [[ -z "${DOMAIN:-}" ]]; then
    warn "DOMAIN no definido en .env — omitiendo diagnóstico SSL"
    return
  fi

  local domains=("${DOMAIN}" "www.${DOMAIN}" "traefik.${DOMAIN}" "dns.${DOMAIN}")
  for dom in "${domains[@]}"; do
    local cert_info days_left
    cert_info=$(echo | timeout 5 openssl s_client \
      -servername "$dom" -connect "${dom}:443" 2>/dev/null | \
      openssl x509 -noout -enddate 2>/dev/null) || {
      warn "${dom}: no responde en 443 o sin certificado"
      continue
    }
    local expire_epoch
    expire_epoch=$(echo "$cert_info" | cut -d= -f2 | xargs -I{} date -d "{}" +%s 2>/dev/null || echo 0)
    days_left=$(( (expire_epoch - $(date +%s)) / 86400 ))
    if [[ $days_left -lt 0 ]]; then
      fail "${dom}: certificado EXPIRADO hace $((days_left * -1)) días"
    elif [[ $days_left -lt 14 ]]; then
      warn "${dom}: expira en ${days_left} días"
    else
      ok "${dom}: válido ${days_left} días"
    fi
  done

  # Verificar acme.json
  local acme_vol
  acme_vol=$(docker volume inspect hosting_traefik-acme \
    --format '{{.Mountpoint}}' 2>/dev/null || echo "")
  if [[ -n "$acme_vol" && -f "${acme_vol}/acme.json" ]]; then
    local acme_size
    acme_size=$(stat -c%s "${acme_vol}/acme.json" 2>/dev/null || echo 0)
    if [[ "$acme_size" -gt 100 ]]; then
      ok "acme.json: ${acme_size} bytes (certificados guardados)"
    else
      warn "acme.json: muy pequeño (${acme_size} bytes) — sin certificados aún"
    fi
    local acme_perms
    acme_perms=$(stat -c%a "${acme_vol}/acme.json" 2>/dev/null || echo "???")
    if [[ "$acme_perms" == "600" ]]; then
      ok "acme.json permisos: 600 ✓"
    else
      fail "acme.json permisos: ${acme_perms} (debe ser 600 — fix: chmod 600 ${acme_vol}/acme.json)"
    fi
  else
    warn "acme.json no encontrado — Traefik aún no ha solicitado certificados"
  fi
}

# ── Diagnóstico de bases de datos ────────────────────────────
diag_databases() {
  header "MARIADB"

  if ! docker exec -e MYSQL_PWD="${DB_ROOT_PASS:-}" mariadb mariadb -uroot \
      -e "SELECT 1;" &>/dev/null 2>&1; then
    fail "MariaDB: no responde o credenciales incorrectas"
    return
  fi
  ok "MariaDB: accesible con root"

  # Listar BDs (excluyendo sistema)
  local dbs
  dbs=$(docker exec -e MYSQL_PWD="${DB_ROOT_PASS:-}" mariadb mariadb -uroot \
    --batch --skip-column-names \
    -e "SHOW DATABASES WHERE \`Database\` NOT IN ('information_schema','performance_schema','mysql','sys');" \
    2>/dev/null | tr '\n' ' ')
  info "Bases de datos: ${dbs:-ninguna}"

  # Verificar binlog
  local binlog
  binlog=$(docker exec -e MYSQL_PWD="${DB_ROOT_PASS:-}" mariadb mariadb -uroot \
    --batch --skip-column-names \
    -e "SHOW VARIABLES LIKE 'log_bin';" 2>/dev/null | awk '{print $2}')
  [[ "$binlog" == "ON" ]] && ok "Binlog: activado" || warn "Binlog: desactivado"

  header "REDIS"
  if docker exec redis redis-cli -a "${REDIS_PASS:-}" ping 2>/dev/null | grep -q PONG; then
    ok "Redis: PONG OK"
    local mem_used
    mem_used=$(docker exec redis redis-cli -a "${REDIS_PASS:-}" INFO memory 2>/dev/null | \
      grep "used_memory_human" | cut -d: -f2 | tr -d '\r')
    info "Redis memoria usada: ${mem_used:-N/A}"
  else
    fail "Redis: no responde"
  fi
}

# ── Diagnóstico fail2ban ──────────────────────────────────────
diag_fail2ban() {
  header "FAIL2BAN"

  if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
    fail "fail2ban: no activo (instala o inicia con: systemctl start fail2ban)"
    return
  fi
  ok "fail2ban: activo"

  # Listar jails activos
  local jails
  jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | cut -d: -f2 | tr -d ' ')
  if [[ -n "$jails" ]]; then
    info "Jails activos: ${jails//,/ | }"
    # IPs baneadas actualmente
    local banned_count=0
    for jail in ${jails//,/ }; do
      local n
      n=$(fail2ban-client status "$jail" 2>/dev/null | \
        grep "Currently banned" | awk '{print $NF}')
      [[ "${n:-0}" -gt 0 ]] && info "  ${jail}: ${n} IP(s) baneadas"
      banned_count=$((banned_count + ${n:-0}))
    done
    ok "Total IPs baneadas: ${banned_count}"
  else
    warn "Sin jails activos — revisa /etc/fail2ban/jail.local"
  fi
}

# ── Resumen final ────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"
  echo -e "${BOLD}  RESUMEN DIAGNÓSTICO — $(date '+%F %T')${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"
  echo -e "  ${GREEN}✓ OK:${NC}        ${PASS}"
  echo -e "  ${YELLOW}⚠ Avisos:${NC}   ${WARN}"
  echo -e "  ${RED}✗ Errores:${NC}  ${FAIL}"
  echo ""
  if [[ $FAIL -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}Hay ${FAIL} error(es) que requieren atención.${NC}"
    echo -e "  Revisa los puntos marcados con ✗ arriba."
  elif [[ $WARN -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}Stack funcionando con ${WARN} aviso(s) menores.${NC}"
  else
    echo -e "  ${GREEN}${BOLD}✓ Todo OK — stack saludable.${NC}"
  fi
  echo ""
}

# ── Main ─────────────────────────────────────────────────────
echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║  DIAGNÓSTICO HOSTING ORACLE ARM64 v22    ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"

case "$MODE" in
  --net)
    diag_system
    diag_network
    ;;
  --stack)
    diag_stack
    diag_http
    diag_databases
    ;;
  --ssl)
    diag_ssl
    ;;
  --dns)
    diag_network
    ;;
  --full|*)
    diag_system
    diag_network
    diag_stack
    diag_http
    diag_ssl
    diag_databases
    diag_fail2ban
    ;;
esac

print_summary
exit $([[ $FAIL -eq 0 ]] && echo 0 || echo 1)
