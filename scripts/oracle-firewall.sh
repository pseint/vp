#!/usr/bin/env bash
# =============================================================
# ORACLE CLOUD — Configuración de iptables + guía de consola
# Oracle VPS tiene reglas iptables por defecto muy restrictivas
# EJECUTAR PRIMERO antes del install.sh
# =============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()   { echo -e "${YELLOW}[⚠]${NC} $1"; }
info()   { echo -e "${CYAN}[→]${NC} $1"; }
header() { echo -e "\n${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BOLD}${YELLOW}  $1${NC}"; echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

[[ $EUID -eq 0 ]] || { echo "Ejecutar como root: sudo bash oracle-firewall.sh"; exit 1; }

header "Oracle Cloud VPS — Configuración de firewall"

# ── Obtener IP pública ─────────────────────────────────────────
PUBLIC_IP=$(curl -sf http://169.254.169.254/opc/v1/vnics/ 2>/dev/null | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0].get('publicIp',''))" 2>/dev/null || \
  curl -sf ifconfig.me 2>/dev/null || \
  curl -sf api.ipify.org 2>/dev/null || echo "DESCONOCIDA")
info "IP pública detectada: ${PUBLIC_IP}"

# ── Paso 1: iptables del sistema ────────────────────────────────
header "PASO 1: Configurando iptables del sistema"

# Oracle instala reglas REJECT por defecto en INPUT
# Ver reglas actuales:
echo "Reglas actuales:"
iptables -L INPUT --line-numbers -n 2>/dev/null | head -30 || true

# Eliminar reglas REJECT que bloquean puertos necesarios
info "Eliminando reglas REJECT restrictivas de Oracle..."
# Guardar reglas actuales
iptables-save > /tmp/iptables-before-hosting.backup

# Función para eliminar regla REJECT si existe
remove_reject() {
  local port="$1"
  local proto="${2:-tcp}"
  while iptables -D INPUT -p "$proto" --dport "$port" -j REJECT 2>/dev/null; do
    echo "  Eliminada regla REJECT para $proto:$port"
  done
}

# Insertar ACCEPT antes de cualquier REJECT
insert_accept() {
  local port="$1"
  local proto="${2:-tcp}"
  # Insertar en posición 1 para que sea la primera regla
  iptables -I INPUT 1 -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null && \
    log "  Aceptando $proto:$port" || warn "  No se pudo agregar regla para $proto:$port"
}

# Puertos necesarios para el stack
insert_accept 80  tcp    # HTTP
insert_accept 443 tcp    # HTTPS
insert_accept 53  tcp    # DNS TCP
insert_accept 53  udp    # DNS UDP
insert_accept 8080 tcp   # Traefik Dashboard
insert_accept 9443 tcp   # Portainer
insert_accept 22   tcp    # SSH (debería estar ya permitido)
insert_accept 2022 tcp    # SFTPGo
insert_accept 443  udp    # HTTP/3 (QUIC)

# Permitir tráfico establecido y relacionado
iptables -I INPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
iptables -I INPUT 1 -i lo -j ACCEPT 2>/dev/null || true

# ── Guardar reglas iptables ────────────────────────────────────
apt-get install -y -qq iptables-persistent 2>/dev/null || true
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
log "Reglas iptables guardadas en /etc/iptables/rules.v4"

# ── Paso 2: Verificación ───────────────────────────────────────
header "PASO 2: Verificación de puertos"
echo "Reglas INPUT actuales:"
iptables -L INPUT -n --line-numbers 2>/dev/null | head -20

# ── Paso 3: Guía para consola de Oracle ────────────────────────
header "PASO 3: CONFIGURAR EN ORACLE CLOUD CONSOLE"
echo ""
echo -e "${BOLD}OBLIGATORIO: También debes abrir los puertos en la consola de Oracle Cloud${NC}"
echo ""
echo -e "${CYAN}Método A — Security Lists (VCN):${NC}"
echo "  1. Ve a: Oracle Cloud Console"
echo "     https://cloud.oracle.com → Networking → Virtual Cloud Networks"
echo "  2. Selecciona tu VCN → Security Lists → Default Security List"
echo "  3. Haz clic en 'Add Ingress Rules' y agrega:"
echo ""
echo "  ┌────────────────────────────────────────────────────────────────────┐"
echo "  │  Source CIDR   │ IP Protocol │ Dest Port  │ Descripción           │"
echo "  ├────────────────────────────────────────────────────────────────────┤"
echo "  │  0.0.0.0/0     │ TCP         │ 80         │ HTTP Web              │"
echo "  │  0.0.0.0/0     │ TCP         │ 443        │ HTTPS Web             │"
echo "  │  0.0.0.0/0     │ TCP         │ 53         │ DNS TCP               │"
echo "  │  0.0.0.0/0     │ UDP         │ 53         │ DNS UDP               │"
echo "  │  0.0.0.0/0     │ TCP         │ 8080       │ Traefik Dashboard     │"
echo "  │  0.0.0.0/0     │ TCP         │ 9443       │ Portainer HTTPS       │
  │  0.0.0.0/0     │ TCP         │ 2022       │ SFTPGo (SFTP)         │
  │  0.0.0.0/0     │ UDP         │ 443        │ HTTP/3 (QUIC)         │"
echo "  └────────────────────────────────────────────────────────────────────┘"
echo ""
echo -e "${CYAN}Método B — Network Security Groups (recomendado):${NC}"
echo "  1. Networking → Virtual Cloud Networks → Network Security Groups"
echo "  2. Crea un NSG llamado 'hosting-nsg'"
echo "  3. Agrega las mismas reglas de ingress de la tabla anterior"
echo "  4. Asigna el NSG a tu instancia:"
echo "     Compute → Instances → [tu instancia] → Edit → NSG"
echo ""
echo -e "${YELLOW}Tu IP pública: ${PUBLIC_IP}${NC}"
echo ""
echo -e "${CYAN}Verificar puertos abiertos desde otro equipo:${NC}"
echo "  nmap -p 22,80,443,53,8080,9443 ${PUBLIC_IP}"
echo "  dig @${PUBLIC_IP} tudominio.com A    # Probar DNS"
echo "  curl -I http://${PUBLIC_IP}           # Probar HTTP"
echo ""

# ── Paso 4: Persistencia ───────────────────────────────────────
header "PASO 4: Configurando persistencia de iptables"
# Crear servicio systemd para restaurar reglas en cada reinicio
cat > /etc/systemd/system/iptables-restore.service << 'SVCEOF'
[Unit]
Description=Restore iptables rules for hosting
After=network.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/sbin/iptables-restore /etc/iptables/rules.v4 2>/dev/null || /usr/sbin/iptables-restore /etc/iptables/rules.v4'
ExecStart=/bin/sh -c '/sbin/ip6tables-restore /etc/iptables/rules.v6 2>/dev/null || /usr/sbin/ip6tables-restore /etc/iptables/rules.v6 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable iptables-restore.service
log "Servicio de restauración de iptables habilitado"

echo ""
log "Configuración de Oracle Cloud completada"
echo -e "${YELLOW}RECUERDA: Abre los puertos en Oracle Cloud Console antes de continuar${NC}"
