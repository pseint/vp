#!/usr/bin/env bash
# =============================================================
# ORACLE VPS FREE - SERVIDOR HOSTING COMPLETO v22 (ARM64 / Ubuntu 24.04)
# Stack: Traefik v3 + PowerDNS + Nginx + PHP-FPM + MariaDB + Redis + Portainer
# Uso: sudo bash install.sh
# =============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()   { echo -e "${YELLOW}[⚠]${NC} $1"; }
error()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()   { echo -e "${CYAN}[→]${NC} $1"; }
header() {
  echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════${NC}"
  echo -e "${BOLD}${BLUE}  $1${NC}"
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════${NC}"
}

check_root()  { [[ $EUID -eq 0 ]] || error "Ejecutar como root: sudo bash install.sh"; }
check_arch()  { info "Arquitectura: $(uname -m)"; }
check_os()    { source /etc/os-release 2>/dev/null; info "OS: ${PRETTY_NAME:-desconocido}"; }

check_preflight() {
  header "Verificaciones previas"

  # Disco: mínimo 10GB libres en /
  local FREE_GB
  FREE_GB=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
  if [[ "$FREE_GB" -lt 10 ]]; then
    error "Espacio insuficiente: ${FREE_GB}GB libres, se necesitan mínimo 10GB"
  fi
  log "Disco: ${FREE_GB}GB libres ✓"

  # RAM: mínimo 1GB
  local RAM_MB
  RAM_MB=$(free -m | awk 'NR==2{print $2}')
  if [[ "$RAM_MB" -lt 1024 ]]; then
    warn "RAM: ${RAM_MB}MB — recomendado mínimo 2GB para el stack completo"
  else
    log "RAM: ${RAM_MB}MB ✓"
  fi

  # Puerto 80/443 libres (no hay otro web server corriendo)
  if ss -tlnp 2>/dev/null | grep -qE ':80 |:443 '; then
    warn "Puerto 80 o 443 ya en uso — verifica que no haya otro servidor web"
  fi

  # Arquitectura compatible
  local ARCH
  ARCH=$(uname -m)
  if [[ "$ARCH" != "aarch64" && "$ARCH" != "x86_64" ]]; then
    warn "Arquitectura ${ARCH} no probada — diseñado para aarch64/x86_64"
  fi

  log "Preflight completado"
}

load_env() {
  [[ -f ".env" ]] || error ".env no encontrado. Ejecuta primero: bash scripts/setup-env.sh"
  set -a; source .env; set +a
  info "Variables de entorno cargadas"
  for v in DOMAIN ACME_EMAIL SERVER_IP PDNS_API_KEY DB_ROOT_PASS DB_PASS REDIS_PASS; do
    [[ -n "${!v:-}" ]] || error "Variable \$$v no definida en .env"
  done

  # FIX: Verificar que .htpasswd exista — sin él Traefik no puede cargar auth@file
  # y el dashboard + SFTPGo WebAdmin devuelven 500
  if [[ ! -f "traefik/dynamic/.htpasswd" ]]; then
    error "traefik/dynamic/.htpasswd no encontrado. Ejecuta primero: bash scripts/setup-env.sh"
  fi

  # FIX #15: Reemplazar placeholders si setup-env.sh no se ejecutó
  # (el usuario copió .env.example y editó manualmente)
  for f in php/php.ini redis/redis.conf dns/pdns.conf; do
    [[ -f "$f" ]] || continue
    if grep -q "REDIS_PASS_PLACEHOLDER" "$f" 2>/dev/null; then
      REDIS_PASS_VAL="${REDIS_PASS}" python3 -c "
import os
with open('$f') as fin: c = fin.read()
c = c.replace('REDIS_PASS_PLACEHOLDER', os.environ['REDIS_PASS_VAL'])
with open('$f', 'w') as fout: fout.write(c)
" && info "  $f — REDIS_PASS_PLACEHOLDER reemplazado"
    fi
    if grep -q "PDNS_DB_PASS_PLACEHOLDER" "$f" 2>/dev/null; then
      PDNS_DB_PASS_VAL="${PDNS_DB_PASS}" python3 -c "
import os
with open('$f') as fin: c = fin.read()
c = c.replace('PDNS_DB_PASS_PLACEHOLDER', os.environ['PDNS_DB_PASS_VAL'])
with open('$f', 'w') as fout: fout.write(c)
" && info "  $f — PDNS_DB_PASS_PLACEHOLDER reemplazado"
    fi
    if grep -q "PDNS_API_KEY_PLACEHOLDER" "$f" 2>/dev/null; then
      PDNS_API_KEY_VAL="${PDNS_API_KEY}" python3 -c "
import os
with open('$f') as fin: c = fin.read()
c = c.replace('PDNS_API_KEY_PLACEHOLDER', os.environ['PDNS_API_KEY_VAL'])
with open('$f', 'w') as fout: fout.write(c)
" && info "  $f — PDNS_API_KEY_PLACEHOLDER reemplazado"
    fi
  done
  # SQL init
  for f in mariadb/init/01-init.sql; do
    [[ -f "$f" ]] || continue
    if grep -q "PDNS_ADMIN_DB_PASS" "$f" 2>/dev/null; then
      PDNS_ADMIN_DB_PASS_VAL="${PDNS_ADMIN_DB_PASS}" WEB_DB_PASS_VAL="${DB_PASS}" python3 -c "
import os
with open('$f') as fin: c = fin.read()
c = c.replace('PDNS_ADMIN_DB_PASS', os.environ['PDNS_ADMIN_DB_PASS_VAL']).replace('WEB_DB_PASS', os.environ['WEB_DB_PASS_VAL'])
with open('$f', 'w') as fout: fout.write(c)
" && info "  $f — passwords SQL reemplazadas"
    fi
  done
}

install_deps() {
  header "Instalando dependencias del sistema"
  apt-get update -qq
  apt-get install -y -qq \
    curl wget git unzip jq \
    ca-certificates gnupg lsb-release \
    fail2ban \
    apache2-utils \
    net-tools dnsutils \
    htop ncdu iotop \
    cron logrotate \
    openssl python3 \
    iptables-persistent \
    rclone
  log "Dependencias instaladas"
}

install_docker() {
  header "Instalando Docker Engine"
  if command -v docker &>/dev/null; then
    warn "Docker ya instalado: $(docker --version)"
    return
  fi
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  log "Docker: $(docker --version)"
  log "Compose: $(docker compose version)"
}

tune_system() {
  header "Optimizando sistema para producción"
  cat > /etc/sysctl.d/99-hosting.conf << 'EOF'
# Red
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 10
net.ipv4.tcp_tw_reuse = 1
# FIX v19: tcp_timestamps OBLIGATORIO para que tcp_tw_reuse funcione en Linux >= 4.12.
# Sin él, el kernel ignora silenciosamente tcp_tw_reuse y las conexiones en TIME_WAIT no se reusan.
net.ipv4.tcp_timestamps = 1
# FIX v19: ip_forward explícito — Docker lo activa en runtime pero si el servicio Docker arranca
# después del sysctl del boot, puede quedar en 0 hasta que Docker lo fuerce. Explicitarlo garantiza
# que el routing de contenedores funcione desde el inicio.
net.ipv4.ip_forward = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
# Seguridad
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
# BUG FIX v15: tcp_syncookies faltaba — protección crítica contra SYN flood
net.ipv4.tcp_syncookies = 1
# Archivos
fs.file-max = 1048576
fs.inotify.max_user_watches = 524288
# VM
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
EOF
  sysctl -p /etc/sysctl.d/99-hosting.conf -q
  log "Kernel optimizado"

  cat > /etc/security/limits.d/99-hosting.conf << 'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

  if [[ $(swapon --show | wc -l) -eq 0 ]]; then
    info "Creando 2GB de swap..."
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile
    mkswap /swapfile -q
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Swap de 2GB configurado"
  fi
}

configure_firewall() {
  header "Configurando Firewall (iptables)"
  # BUG FIX #8: UFW + Docker tienen conflicto conocido — UFW bloquea FORWARD de Docker.
  # Usamos iptables directamente (más predecible con Docker en Oracle Cloud).
  # Oracle Cloud ya tiene Security Lists como firewall externo.

  local PORTS_TCP=(22 80 443 53 8080 9443 2022)  # BUG FIX #9: puerto 2022 SFTPGo
  local PORTS_UDP=(53 443)  # 443/udp para HTTP/3 (QUIC)

  # Aceptar establecidas y loopback
  iptables -I INPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  iptables -I INPUT 2 -i lo -j ACCEPT 2>/dev/null || true

  # Puertos TCP
  for port in "${PORTS_TCP[@]}"; do
    iptables -I INPUT 3 -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
  done

  # Puertos UDP
  for port in "${PORTS_UDP[@]}"; do
    iptables -I INPUT 4 -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
  done

  # BUG FIX #8: Permitir tráfico Docker FORWARD (crítico para que contenedores salgan a internet)
  iptables -I FORWARD 1 -i docker0 -j ACCEPT 2>/dev/null || true
  iptables -I FORWARD 2 -o docker0 -j ACCEPT 2>/dev/null || true
  iptables -I FORWARD 3 -i hosting0 -j ACCEPT 2>/dev/null || true
  iptables -I FORWARD 4 -o hosting0 -j ACCEPT 2>/dev/null || true
  iptables -t nat -A POSTROUTING -s 172.20.0.0/16 ! -o docker0 -j MASQUERADE 2>/dev/null || true
  iptables -t nat -A POSTROUTING -s 172.21.0.0/24 ! -o docker0 -j MASQUERADE 2>/dev/null || true  # FIX: dns-net

  # FIX v22: reglas IPv6 — Oracle Cloud puede tener IPv6 activo;
  # sin estas reglas, SSH/HTTP/HTTPS/DNS quedan bloqueados por ip6tables default ACCEPT
  # (seguro de ejecutar aunque IPv6 esté desactivado — ip6tables lo ignora silenciosamente)
  if command -v ip6tables &>/dev/null; then
    ip6tables -I INPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    ip6tables -I INPUT 2 -i lo -j ACCEPT 2>/dev/null || true
    for port in 22 80 443 53 2022; do
      ip6tables -I INPUT 3 -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    done
    for port in 53 443; do
      ip6tables -I INPUT 4 -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
    done
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    log "ip6tables IPv6 configurado"
  fi

  # Guardar reglas para persistencia entre reinicios
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  log "iptables configurado (TCP: ${PORTS_TCP[*]}, UDP: ${PORTS_UDP[*]})"

  warn "IMPORTANTE: Abre también en Oracle Cloud Console → Networking → VCN → Security Lists:"
  warn "  TCP Ingress: 22, 80, 443, 53, 8080, 9443, 2022"
  warn "  UDP Ingress: 53"
}

configure_fail2ban() {
  header "Configurando Fail2ban"
  local INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"

  if [[ -f "${INSTALL_DIR}/fail2ban/jail.local" ]]; then
    # FIX 18: sustituir INSTALL_DIR placeholder con la ruta real
    sed "s|INSTALL_DIR|${INSTALL_DIR}|g" \
      "${INSTALL_DIR}/fail2ban/jail.local" > /etc/fail2ban/jail.local
    log "jail.local instalado"
  else
    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1 172.16.0.0/12 10.0.0.0/8

[sshd]
enabled = true
port    = ssh
logpath = %(sshd_log)s
EOF
  fi

  if [[ -d "${INSTALL_DIR}/fail2ban" ]]; then
    for filter_file in "${INSTALL_DIR}"/fail2ban/filter-*.conf; do
      [[ -f "$filter_file" ]] || continue
      dest_name=$(basename "${filter_file#*filter-}")
      cp "$filter_file" "/etc/fail2ban/filter.d/${dest_name}"
      log "  Filtro: ${dest_name}"
    done
  fi

  # Detectar si el sistema usa nftables (Ubuntu 24.04) y ajustar banaction
  if command -v nft &>/dev/null && nft list tables &>/dev/null 2>&1; then
    sed -i 's/^banaction = iptables-multiport/# banaction = iptables-multiport\nbanaction = nftables-multiport/' /etc/fail2ban/jail.local
    sed -i 's/^banaction_allports = iptables-allports/# banaction_allports = iptables-allports\nbanaction_allports = nftables-allports/' /etc/fail2ban/jail.local
    log "Fail2ban configurado con backend nftables (Ubuntu 24.04)"
  fi

  systemctl enable --now fail2ban
  log "Fail2ban configurado"
}

configure_logrotate() {
  header "Configurando Logrotate"
  local INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
  if [[ -f "${INSTALL_DIR}/logrotate/hosting" ]]; then
    sed "s|/opt/hosting|${INSTALL_DIR}|g" \
      "${INSTALL_DIR}/logrotate/hosting" > /etc/logrotate.d/hosting
    log "Logrotate configurado"
  fi
}

prepare_dirs() {
  header "Preparando estructura de directorios"
  local INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"

  mkdir -p "${INSTALL_DIR}"/{nginx/{conf.d,sites-available,sites-enabled,snippets,html},dns,php,mariadb/{conf.d,init},redis,traefik/dynamic,scripts,logs/{nginx,traefik,backup,sftpgo},data/{sites,backups},fail2ban,logrotate}

  if [[ "$(pwd)" != "$INSTALL_DIR" ]]; then
    info "Copiando archivos a ${INSTALL_DIR}..."
    cp -r . "${INSTALL_DIR}/" 2>/dev/null || true
  fi

  chmod +x "${INSTALL_DIR}"/scripts/*.sh 2>/dev/null || true
  log "Directorios preparados en ${INSTALL_DIR}"
}

create_docker_network() {
  header "Configurando red Docker"
  docker network inspect hosting-net &>/dev/null || \
    docker network create \
      --driver bridge \
      --subnet 172.20.0.0/16 \
      --opt com.docker.network.bridge.name=hosting0 \
      hosting-net
  log "Red 'hosting-net' lista"
}

deploy_stack() {
  header "Desplegando stack de contenedores"
  local INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
  cd "$INSTALL_DIR"

  info "Descargando imágenes Docker para ARM64..."
  docker compose pull --quiet

  info "Construyendo imagen PHP-FPM personalizada..."
  docker compose build php-fpm

  info "Iniciando servicios..."
  docker compose up -d --remove-orphans

  log "Stack desplegado"
  sleep 8
  docker compose ps
}

setup_initial_dns() {
  header "Configurando zona DNS inicial para ${DOMAIN}"
  local INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
  cd "$INSTALL_DIR"

  info "Esperando que PowerDNS inicie (15s)..."
  sleep 15

  curl -sf -X POST \
    -H "X-API-Key: ${PDNS_API_KEY}" \
    -H "Content-Type: application/json" \
    "http://localhost:${PDNS_API_PORT:-8053}/api/v1/servers/localhost/zones" \
    -d "{
      \"name\": \"${DOMAIN}.\",
      \"kind\": \"Native\",
      \"nameservers\": [],
      \"rrsets\": [
        {\"name\": \"${DOMAIN}.\",     \"type\": \"SOA\", \"ttl\": 3600, \"records\": [{\"content\": \"ns1.${DOMAIN}. hostmaster.${DOMAIN}. $(date +%Y%m%d)01 3600 900 604800 300\", \"disabled\": false}]},
        {\"name\": \"${DOMAIN}.\",     \"type\": \"NS\",  \"ttl\": 3600, \"records\": [{\"content\": \"ns1.${DOMAIN}.\", \"disabled\": false}, {\"content\": \"ns2.${DOMAIN}.\", \"disabled\": false}]},
        {\"name\": \"${DOMAIN}.\",     \"type\": \"A\",   \"ttl\": 300,  \"records\": [{\"content\": \"${SERVER_IP}\", \"disabled\": false}]},
        {\"name\": \"www.${DOMAIN}.\", \"type\": \"A\",   \"ttl\": 300,  \"records\": [{\"content\": \"${SERVER_IP}\", \"disabled\": false}]},
        {\"name\": \"ns1.${DOMAIN}.\", \"type\": \"A\",   \"ttl\": 3600, \"records\": [{\"content\": \"${SERVER_IP}\", \"disabled\": false}]},
        {\"name\": \"ns2.${DOMAIN}.\", \"type\": \"A\",   \"ttl\": 3600, \"records\": [{\"content\": \"${SERVER_IP}\", \"disabled\": false}]},
        {\"name\": \"mail.${DOMAIN}.\",\"type\": \"A\",   \"ttl\": 300,  \"records\": [{\"content\": \"${SERVER_IP}\", \"disabled\": false}]},
        {\"name\": \"${DOMAIN}.\",     \"type\": \"MX\",  \"ttl\": 300,  \"records\": [{\"content\": \"10 mail.${DOMAIN}.\", \"disabled\": false}]},
        {\"name\": \"${DOMAIN}.\",     \"type\": \"TXT\", \"ttl\": 300,  \"records\": [{\"content\": \"\\\"v=spf1 a mx ip4:${SERVER_IP} ~all\\\"\", \"disabled\": false}]}
      ]
    }" && log "Zona DNS ${DOMAIN} creada" || \
    warn "No se pudo crear zona DNS — hazlo manualmente en PDNS Admin"
}

setup_cron() {
  header "Configurando tareas programadas"
  local INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"

  crontab -l 2>/dev/null | grep -v "hosting" > /tmp/crontab_tmp || true

  cat >> /tmp/crontab_tmp << CRONEOF
# ── Hosting Oracle VPS v22 ─────────────────────────────────────────
# Backup diario a las 3:00 AM
0 3 * * * ${INSTALL_DIR}/scripts/backup.sh full --offsite >> ${INSTALL_DIR}/logs/backup/backup.log 2>&1
# Monitor de servicios cada 5 minutos
*/5 * * * * ${INSTALL_DIR}/scripts/monitor.sh >> ${INSTALL_DIR}/logs/monitor.log 2>&1
# Verificación SSL semanal (domingo 9 AM)
0 9 * * 0 ${INSTALL_DIR}/scripts/ssl-check.sh >> ${INSTALL_DIR}/logs/ssl-check.log 2>&1
# Verificación integridad backup (diario 4 AM, tras el backup de las 3 AM)
0 4 * * * ${INSTALL_DIR}/scripts/backup-verify.sh >> ${INSTALL_DIR}/logs/backup/verify.log 2>&1 || true
# Limpieza de logs viejos (+30 días) — domingos 4 AM
0 4 * * 0 find ${INSTALL_DIR}/logs -name "*.log" -mtime +30 -delete
# Limpieza de imágenes Docker sin uso — domingos 4:30 AM
30 4 * * 0 docker image prune -f --filter "until=168h" >> /dev/null 2>&1
CRONEOF

  crontab /tmp/crontab_tmp
  rm -f /tmp/crontab_tmp
  log "Cron jobs configurados"
}

verify_deployment() {
  header "Verificando despliegue"
  local INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
  cd "$INSTALL_DIR"

  local failed=0
  local services=("traefik" "powerdns" "pdns-admin" "nginx" "php-fpm" "mariadb" "redis" "portainer")

  for svc in "${services[@]}"; do
    if docker compose ps "$svc" 2>/dev/null | grep -qE "Up|running|healthy"; then
      log "  $svc — OK"
    else
      warn "  $svc — iniciando (puede tardar 30-60s más)"
      ((failed++)) || true
    fi
  done

  echo ""
  sleep 5
  if curl -sf -o /dev/null --max-time 5 http://localhost; then
    log "HTTP responde correctamente"
  else
    warn "HTTP aún no responde (normal mientras Traefik inicializa)"
  fi

  if curl -sf -H "X-API-Key: ${PDNS_API_KEY}" \
      "http://localhost:${PDNS_API_PORT:-8053}/api/v1/servers/localhost" &>/dev/null; then
    log "PowerDNS API responde"
  else
    warn "PowerDNS API aún no responde — espera 30s y reintenta"
  fi

  log "Verificación completada"
}

print_summary() {
  local INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║    INSTALACIÓN v22 COMPLETADA EXITOSAMENTE            ║${NC}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}Accesos:${NC}"
  echo -e "  🌐  Web:          https://${DOMAIN}"
  echo -e "  🔀  Traefik:      http://${SERVER_IP}:8080"
  echo -e "  🐳  Portainer:    https://${SERVER_IP}:9443"
  echo -e "  🌍  DNS Admin:    https://dns.${DOMAIN}"
  echo -e "  📁  SFTPGo:       https://sftp.${DOMAIN}  (tras: make sftp-up)"
  echo -e "  🔒  SFTP/SSH:     sftp -P 2022 usuario@${SERVER_IP}"
  echo ""
  echo -e "${BOLD}Comandos rápidos (desde ${INSTALL_DIR}):${NC}"
  echo -e "  make status                         # Estado completo"
  echo -e "  make add-site DOMAIN=ejemplo.com    # Nuevo sitio PHP"
  echo -e "  make add-wp   DOMAIN=ejemplo.com    # Instalar WordPress"
  echo -e "  make backup                         # Backup manual"
  echo -e "  make ssl-check                      # Estado de certificados"
  echo -e "  make sftp-up                        # Activar SFTPGo"
  echo ""
  echo -e "${BOLD}${YELLOW}PRÓXIMOS PASOS OBLIGATORIOS:${NC}"
  echo -e "  1. Abre puertos en Oracle Cloud Console → Security Lists:"
  echo -e "     TCP: 22, 80, 443, 53, 8080, 9443, 2022  |  UDP: 53"
  echo -e "  2. En tu registrador de dominios, apunta los nameservers a:"
  echo -e "     ns1.${DOMAIN} → ${SERVER_IP}"
  echo -e "     ns2.${DOMAIN} → ${SERVER_IP}"
  echo -e "  3. Crea la cuenta de admin en Portainer: https://${SERVER_IP}:9443"
  echo ""
}

main() {
  header "ORACLE VPS FREE — SERVIDOR HOSTING COMPLETO v22"
  info "Iniciando en $(hostname) [$(uname -m)] — $(date)"

  check_root
  check_arch
  check_os
  check_preflight
  load_env

  install_deps
  install_docker
  tune_system
  configure_firewall
  prepare_dirs
  configure_fail2ban
  configure_logrotate
  create_docker_network
  #deploy_stack
  setup_initial_dns
  setup_cron
  verify_deployment
  print_summary
}

main "$@"
