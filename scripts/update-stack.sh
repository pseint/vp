#!/usr/bin/env bash
# =============================================================
# ACTUALIZAR STACK — Pull de nuevas imágenes + redeploy seguro
# Uso: ./scripts/update-stack.sh [servicio]
# Sin argumento: actualiza todo el stack
# =============================================================
set -euo pipefail

SERVICE="${1:-}"
INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
[[ -f "$INSTALL_DIR/.env" ]] && source "$INSTALL_DIR/.env"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "[$(date '+%T')] ${GREEN}[OK]${NC}  $1"; }
info() { echo -e "[$(date '+%T')] ${CYAN}[→]${NC}  $1"; }
warn() { echo -e "[$(date '+%T')] ${YELLOW}[⚠]${NC}  $1"; }

cd "$INSTALL_DIR"

# ── Backup preventivo antes de actualizar ─────────────────────
info "Backup preventivo antes de actualizar..."
bash "${INSTALL_DIR}/scripts/backup.sh" db 2>/dev/null && log "Backup de BD completado"

# ── Pull de imágenes ──────────────────────────────────────────
if [[ -n "$SERVICE" ]]; then
  info "Actualizando servicio: ${SERVICE}"
  # FIX v19: php-fpm es imagen LOCAL (build), docker compose pull no hace nada útil.
  # Para cualquier servicio que sea imagen registrada, pull + recreate.
  # Para php-fpm específicamente: rebuild con --pull --no-cache para actualizar Alpine base.
  if [[ "$SERVICE" == "php-fpm" ]]; then
    info "  php-fpm es imagen local — reconstruyendo con Alpine actualizado..."
    docker compose build --pull --no-cache php-fpm
    docker compose up -d --no-deps --force-recreate php-fpm
  else
    docker compose pull "$SERVICE"
    docker compose up -d --no-deps --force-recreate "$SERVICE"
  fi
else
  info "Actualizando todo el stack..."
  docker compose pull
  # Actualizar servicios sin tiempo de caída (rolling update)
  # Primero los que no sirven tráfico directo
  for svc in mariadb redis; do
    info "  Actualizando ${svc}..."
    docker compose up -d --no-deps --force-recreate "$svc"
    sleep 5
  done
  # Reconstruir php-fpm (imagen local custom — pull no la actualiza)
  # BUG FIX v15: --no-cache fuerza reconstrucción completa con capas Alpine actualizadas.
  # Sin él, Docker reutilizaba capas en caché aunque la imagen base tuviera parches de seguridad.
  info "  Reconstruyendo imagen PHP-FPM (Alpine base actualizada)..."
  docker compose build --pull --no-cache php-fpm
  docker compose up -d --no-deps --force-recreate php-fpm
  sleep 5

  # Actualizar nginx
  info "  Actualizando nginx..."
  docker compose up -d --no-deps --force-recreate nginx
  sleep 3
  # Finalmente el proxy (causa ~1s de interrupción)
  info "  Actualizando traefik (interrupción mínima)..."
  docker compose up -d --no-deps --force-recreate traefik
  docker compose up -d --no-deps --force-recreate powerdns pdns-admin portainer
fi

# ── Limpiar imágenes viejas ────────────────────────────────────
info "Limpiando imágenes obsoletas..."
docker image prune -f 2>/dev/null || true

log "Actualización completada"
docker compose ps
