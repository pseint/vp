#!/usr/bin/env bash
# =============================================================
# SFTPGO — Crear/gestionar usuario SFTP por cliente (Feature #1)
# Cada usuario accede SOLO a su dominio con cuota configurable
# Uso: ./scripts/sftp-user.sh <dominio.com> [cuota_GB] [accion: add|del|list|passwd]
# =============================================================
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
[[ -f "$INSTALL_DIR/.env" ]] && source "$INSTALL_DIR/.env"

DOMAIN="${1:-}"
QUOTA_GB="${2:-5}"
ACTION="${3:-add}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[⚠]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info()  { echo -e "${CYAN}[→]${NC} $1"; }

SFTPGO_URL="http://localhost:8090"
ADMIN_TOKEN=""

# ── Obtener token de SFTPGo ───────────────────────────────────
get_token() {
  # BUG FIX v15: usar python3 para parsear JSON en lugar de grep regex frágil.
  # El grep anterior fallaba si el JSON tenía espacios o el orden de campos cambiaba.
  local response
  response=$(curl -s -X POST \
    "${SFTPGO_URL}/api/v2/token" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"${SFTPGO_ADMIN_PASS:-admin}\"}")

  ADMIN_TOKEN=$(echo "$response" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('access_token', ''))
except Exception:
    print('')
" 2>/dev/null)

  [[ -z "$ADMIN_TOKEN" ]] && error "No se pudo autenticar con SFTPGo. ¿Está corriendo? docker compose --profile sftp up -d sftpgo"
}

# ── Listar usuarios SFTP ──────────────────────────────────────
list_users() {
  get_token
  echo -e "${YELLOW}Usuarios SFTP activos:${NC}"
  curl -s -X GET \
    "${SFTPGO_URL}/api/v2/users" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    | python3 -c "
import sys, json
users = json.load(sys.stdin)
if not users:
    print('  (ninguno)')
for u in users:
    quota_used = u.get('used_quota_size', 0) // (1024**3)
    quota_total = u.get('quota_size', 0) // (1024**3)
    print(f\"  {u['username']:30s} | Cuota: {quota_used}GB/{quota_total}GB | Home: {u.get('home_dir','')}\")
"
}

# ── Añadir usuario SFTP ───────────────────────────────────────
add_user() {
  [[ -z "$DOMAIN" ]] && error "Uso: $0 dominio.com [cuota_GB] add"

  get_token

  USERNAME=$(echo "$DOMAIN" | tr '.' '_' | tr '-' '_')
  HOME_DIR="/var/www/html/${DOMAIN}"
  QUOTA_BYTES=$((QUOTA_GB * 1024 * 1024 * 1024))
  PASSWORD=$(openssl rand -base64 16 | tr -d '=/+' | head -c 20)

  info "Creando usuario SFTP: ${USERNAME}"
  info "Directorio home:      ${HOME_DIR}"
  info "Cuota:                ${QUOTA_GB}GB"

  # Crear directorio si no existe
  SITES_DATA=$(docker volume inspect hosting_sites-data --format '{{.Mountpoint}}' 2>/dev/null || echo "/var/lib/docker/volumes/hosting_sites-data/_data")
  mkdir -p "${SITES_DATA}/${DOMAIN}" 2>/dev/null || true

  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "${SFTPGO_URL}/api/v2/users" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"username\": \"${USERNAME}\",
      \"password\": \"${PASSWORD}\",
      \"home_dir\": \"${HOME_DIR}\",
      \"quota_size\": ${QUOTA_BYTES},
      \"quota_files\": 0,
      \"max_upload_file_size\": $((100 * 1024 * 1024)),
      \"status\": 1,
      \"permissions\": {\"/\": [\"list\",\"download\",\"upload\",\"overwrite\",\"delete\",\"rename\",\"create_dirs\",\"chmod\",\"chown\",\"chtimes\"]},
      \"description\": \"Cliente: ${DOMAIN}\"
    }")

  if [[ "$RESPONSE" == "201" ]]; then
    log "Usuario SFTP creado exitosamente"
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════${NC}"
    echo -e "${YELLOW} CREDENCIALES SFTP PARA: ${DOMAIN}${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════${NC}"
    echo -e "  Host:     ${SERVER_IP:-tu.ip.del.servidor}"
    echo -e "  Puerto:   2022"
    echo -e "  Usuario:  ${USERNAME}"
    echo -e "  Password: ${PASSWORD}"
    echo -e "  Ruta:     /  (raíz = ${HOME_DIR})"
    echo -e "  Cuota:    ${QUOTA_GB}GB"
    echo -e "${YELLOW}═══════════════════════════════════════════${NC}"
    echo ""
    warn "¡Guarda estas credenciales! No se pueden recuperar."
  else
    error "Error al crear usuario SFTP (HTTP ${RESPONSE}). ¿Ya existe?"
  fi
}

# ── Eliminar usuario SFTP ─────────────────────────────────────
del_user() {
  [[ -z "$DOMAIN" ]] && error "Uso: $0 dominio.com [quota] del"
  get_token
  USERNAME=$(echo "$DOMAIN" | tr '.' '_' | tr '-' '_')

  read -rp "¿Eliminar usuario SFTP '${USERNAME}'? [y/N] " confirm
  [[ "$confirm" != "y" ]] && { warn "Cancelado."; exit 0; }

  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
    "${SFTPGO_URL}/api/v2/users/${USERNAME}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}")

  [[ "$RESPONSE" == "200" ]] && log "Usuario ${USERNAME} eliminado" \
    || error "Error eliminando usuario (HTTP ${RESPONSE})"
}

# ── Cambiar contraseña ────────────────────────────────────────
passwd_user() {
  [[ -z "$DOMAIN" ]] && error "Uso: $0 dominio.com [quota] passwd"
  get_token
  USERNAME=$(echo "$DOMAIN" | tr '.' '_' | tr '-' '_')
  NEW_PASS=$(openssl rand -base64 16 | tr -d '=/+' | head -c 20)

  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    "${SFTPGO_URL}/api/v2/users/${USERNAME}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"password\": \"${NEW_PASS}\"}")

  if [[ "$RESPONSE" == "200" ]]; then
    log "Contraseña actualizada"
    echo -e "  Nueva contraseña: ${GREEN}${NEW_PASS}${NC}"
  else
    error "Error actualizando contraseña (HTTP ${RESPONSE})"
  fi
}

# ── Setup inicial de SFTPGo ───────────────────────────────────
setup_sftpgo() {
  info "Configurando SFTPGo por primera vez..."
  sleep 5  # Esperar a que arranque

  # FIX: usar SFTPGO_ADMIN_PASS del .env (generado por setup-env.sh)
  # Si no existe, generar uno y guardarlo
  if [[ -z "${SFTPGO_ADMIN_PASS:-}" ]]; then
    SFTPGO_ADMIN_PASS=$(openssl rand -base64 16 | tr -d '=/+' | head -c 20)
    echo "SFTPGO_ADMIN_PASS=${SFTPGO_ADMIN_PASS}" >> "$INSTALL_DIR/.env"
    warn "SFTPGO_ADMIN_PASS no estaba en .env — generado y guardado"
  fi

  RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "${SFTPGO_URL}/api/v2/admin" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"${SFTPGO_ADMIN_PASS}\",\"status\":1,\"permissions\":[\"*\"]}")

  if [[ "$RESPONSE" == "201" ]]; then
    log "Admin SFTPGo creado"
    echo ""
    echo -e "${YELLOW}Admin SFTPGo:${NC}"
    echo -e "  URL:      https://sftp.${DOMAIN:-tu-dominio.com}"
    echo -e "  Usuario:  admin"
    echo -e "  Password: ${SFTPGO_ADMIN_PASS}"
    echo ""
  else
    warn "El admin ya existe o hubo un error (HTTP ${RESPONSE})"
  fi
}

# ── Main ──────────────────────────────────────────────────────
case "$ACTION" in
  add)    add_user ;;
  del)    del_user ;;
  list)   list_users ;;
  passwd) passwd_user ;;
  setup)  setup_sftpgo ;;
  *)
    echo "Uso: $0 <dominio.com> [cuota_GB] [add|del|list|passwd|setup]"
    echo ""
    echo "  add     — Crear usuario SFTP para el dominio"
    echo "  del     — Eliminar usuario SFTP"
    echo "  list    — Listar todos los usuarios"
    echo "  passwd  — Generar nueva contraseña"
    echo "  setup   — Configuración inicial (solo primera vez)"
    echo ""
    echo "Ejemplos:"
    echo "  $0 cliente1.com 10 add    # SFTP con 10GB de cuota"
    echo "  $0 cliente1.com 5  passwd # Nueva contraseña"
    echo "  $0 - - list               # Listar usuarios"
    ;;
esac
