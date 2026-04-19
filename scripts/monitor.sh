#!/usr/bin/env bash
# =============================================================
# MONITOR DE SERVICIOS v22 — Reinicia contenedores caídos
# Ejecutado por cron cada 5 minutos
# Novedades v22: alertas Telegram/webhook + detección OOM killer
# =============================================================
set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
[[ -f "$INSTALL_DIR/.env" ]] && source "$INSTALL_DIR/.env"

DATE=$(date '+%F %T')

# FIX v16: Verificar que hosting-net exista antes de monitorear
if ! docker network inspect hosting-net &>/dev/null; then
  echo "[$DATE] WARN: Red hosting-net no existe — recreando..."
  docker network create hosting-net 2>/dev/null || true
fi

SERVICES=("traefik" "powerdns" "nginx" "php-fpm" "mariadb" "redis" "portainer" "pdns-admin")
RESTARTED=()
FAILED=()

# ── Función de alerta (Telegram opcional) ─────────────────────
# Configurar en .env: TELEGRAM_BOT_TOKEN y TELEGRAM_CHAT_ID
send_alert() {
  local msg="$1"
  local host
  host=$(hostname -s)
  local full_msg="🚨 *Hosting ${host}*%0A${msg}"

  # Telegram
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -s -X POST \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" \
      -d "text=${full_msg}" \
      -d "parse_mode=Markdown" \
      > /dev/null 2>&1 || true
  fi

  # Webhook genérico (Slack, Discord, n8n, etc.)
  if [[ -n "${ALERT_WEBHOOK_URL:-}" ]]; then
    local json_payload
    json_payload=$(python3 -c "import json,sys; print(json.dumps({'text': sys.argv[1]}))" "$msg" 2>/dev/null || echo '{"text":"alert"}')
    curl -s -X POST "${ALERT_WEBHOOK_URL}" \
      -H "Content-Type: application/json" \
      -d "$json_payload" \
      > /dev/null 2>&1 || true
  fi
}

# ── Verificar servicios ────────────────────────────────────────
for svc in "${SERVICES[@]}"; do
  STATUS=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "missing")
  # FIX: guard {{if .State.Health}} — sin él, contenedores sin healthcheck devuelven error de template
  HEALTH=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$svc" 2>/dev/null || echo "none")

  NEEDS_RESTART=false
  if [[ "$STATUS" != "running" ]]; then
    echo "[$DATE] ALERTA: $svc estado '$STATUS' — reiniciando..."
    NEEDS_RESTART=true
  elif [[ "$HEALTH" == "unhealthy" ]]; then
    echo "[$DATE] ALERTA: $svc está UNHEALTHY (running pero sin responder) — reiniciando..."
    NEEDS_RESTART=true
  fi

  if [[ "$NEEDS_RESTART" == "true" ]]; then
    if cd "$INSTALL_DIR" && docker compose restart "$svc" 2>/dev/null; then
      RESTARTED+=("$svc")
    else
      echo "[$DATE] ERROR: No se pudo reiniciar $svc"
      FAILED+=("$svc")
    fi
  fi
done

# Verificar SFTPGo si está activo
if docker inspect sftpgo &>/dev/null 2>&1; then
  STATUS=$(docker inspect --format='{{.State.Status}}' "sftpgo" 2>/dev/null || echo "missing")
  if [[ "$STATUS" != "running" ]]; then
    cd "$INSTALL_DIR" && docker compose --profile sftp up -d sftpgo 2>/dev/null || true
    RESTARTED+=("sftpgo")
  fi
fi

# ── Log y alertas ──────────────────────────────────────────────
if [[ ${#RESTARTED[@]} -gt 0 ]]; then
  MSG="⚠ Servicios reiniciados: ${RESTARTED[*]}"
  echo "[$DATE] $MSG"
  send_alert "$MSG"
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  MSG="❌ Servicios que NO arrancan: ${FAILED[*]}"
  echo "[$DATE] $MSG" >&2
  send_alert "$MSG"
fi

if [[ ${#RESTARTED[@]} -eq 0 && ${#FAILED[@]} -eq 0 ]]; then
  echo "[$DATE] OK — todos los servicios activos"
fi

# ── Disco (alerta si >85%) ────────────────────────────────────
DISK_USAGE=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
if [[ "$DISK_USAGE" -gt 85 ]]; then
  MSG="💾 DISCO: ${DISK_USAGE}% usado — limpiando imágenes Docker..."
  echo "[$DATE] $MSG"
  send_alert "$MSG"
  docker system prune -f --filter "until=168h" 2>/dev/null || true
fi

# ── Disco en volúmenes Docker (sitios y caché) ──────────────
for vol_name in hosting_sites-data hosting_nginx-cache; do
  VOL_PATH=$(docker volume inspect "$vol_name" --format '{{.Mountpoint}}' 2>/dev/null || echo "")
  if [[ -n "$VOL_PATH" && -d "$VOL_PATH" ]]; then
    VOL_USAGE=$(df "$VOL_PATH" | awk 'NR==2 {print $5}' | tr -d '%')
    if [[ "$VOL_USAGE" -gt 85 ]]; then
      MSG="💾 VOLUMEN ${vol_name}: ${VOL_USAGE}% usado"
      echo "[$DATE] $MSG"
      send_alert "$MSG"
    fi
  fi
done

# ── Inodos (alerta si >90% usados) ─────────────────────────
INODE_USE=$(df -i / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
if [[ -n "$INODE_USE" && "$INODE_USE" -gt 90 ]]; then
  MSG="🗂 INODOS: ${INODE_USE}% usados en / — limpiando sesiones PHP y logs viejos..."
  echo "[$DATE] $MSG"
  send_alert "$MSG"
  # Limpiar sesiones PHP viejas (> 24h)
  find /tmp -name "sess_*" -mtime +1 -delete 2>/dev/null || true
  # Limpiar imágenes Docker colgadas
  docker image prune -f --filter "dangling=true" >> /dev/null 2>&1 || true
fi

# ── RAM (alerta si <512MB disponibles) ───────────────────────
MEM_AVAIL=$(free -m | awk 'NR==2 {print $7}')
if [[ "$MEM_AVAIL" -lt 512 ]]; then
  MSG="🧠 RAM: Solo ${MEM_AVAIL}MB disponibles"
  echo "[$DATE] $MSG"
  send_alert "$MSG"
  docker exec redis redis-cli -a "${REDIS_PASS:-}" MEMORY PURGE 2>/dev/null || true
  # Limpiar logs de Docker de contenedores detenidos
  docker container prune -f 2>/dev/null || true
fi

# ── CPU alta sostenida (>95% 5 min avg) ──────────────────────
CPU_LOAD=$(awk '{print $1}' /proc/loadavg | awk -F. '{print $1}')
CPU_CORES=$(nproc)
if [[ "$CPU_LOAD" -gt "$((CPU_CORES * 2))" ]]; then
  MSG="🔥 CPU: Carga ${CPU_LOAD} en ${CPU_CORES} cores"
  echo "[$DATE] $MSG"
  send_alert "$MSG"
fi

# ── OOM Killer (v19: solo busca eventos en los últimos 10 min) ──────────────
# dmesg sin filtro de tiempo reportaba events desde el boot en CADA ciclo de 5 min
# produciendo alertas repetidas infinitamente por un OOM que ya no es relevante.
if command -v dmesg &>/dev/null; then
  # --since solo disponible en util-linux >= 2.36 (Ubuntu 24.04 lo tiene)
  OOM_HITS=$(dmesg --since "10 minutes ago" 2>/dev/null | \
    grep -c "Out of memory: Kill process\|oom_kill_process\|Killed process" 2>/dev/null || \
    dmesg --time-format=reltime 2>/dev/null | awk -F'[:\\[]' 'NR==1{start=$2} {if ($2-start < 600) print}' | \
    grep -c "Out of memory: Kill process\|oom_kill_process\|Killed process" 2>/dev/null || echo "0")
  if [[ "$OOM_HITS" -gt 0 ]]; then
    OOM_VICTIM=$(dmesg --since "10 minutes ago" 2>/dev/null | \
      grep -E "Out of memory: Kill process|oom_kill_process|Killed process" | \
      tail -1 | grep -oP '(?<=Kill process |Killed process )\d+ \([^)]+\)' || echo "proceso desconocido")
    MSG="💀 OOM KILLER: ${OOM_HITS} proceso(s) matados en los últimos 10min. Último: ${OOM_VICTIM}"
    echo "[$DATE] $MSG"
    send_alert "$MSG"
  fi
fi
