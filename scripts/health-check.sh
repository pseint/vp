#!/usr/bin/env bash
# =============================================================
# HEALTH-CHECK v1 — Diagnóstico rápido de salud de contenedores
# Diferencia con status.sh: este es ligero y retorna exit code
# Útil para CI/CD, scripts externos, cron de verificación rápida
# Uso: ./scripts/health-check.sh [--json]
# =============================================================
set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
[[ -f "$INSTALL_DIR/.env" ]] && source "$INSTALL_DIR/.env"

FORMAT="${1:-}"
ERRORS=0
declare -A RESULTS

SERVICES=("traefik" "powerdns" "pdns-admin" "nginx" "php-fpm" "mariadb" "redis" "portainer")

for svc in "${SERVICES[@]}"; do
  STATUS=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "missing")
  HEALTH=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$svc" 2>/dev/null || echo "unknown")

  if [[ "$STATUS" != "running" ]]; then
    RESULTS[$svc]="DOWN"
    ((ERRORS++)) || true
  elif [[ "$HEALTH" == "unhealthy" ]]; then
    RESULTS[$svc]="UNHEALTHY"
    ((ERRORS++)) || true
  else
    RESULTS[$svc]="OK"
  fi
done

if [[ "$FORMAT" == "--json" ]]; then
  HEALTHY=$([[ $ERRORS -eq 0 ]] && echo true || echo false)
  # Construir JSON de servicios con python3 para garantizar JSON válido
  # Build JSON using jq-safe approach: construct via bash array then python
_SERVICES_JSON=""
for svc in "${SERVICES[@]}"; do
  state="${RESULTS[$svc]:-UNKNOWN}"
  _SERVICES_JSON+="  \"$svc\": \"$state\",\n"
done
# Add optional sftpgo if running
if docker inspect sftpgo &>/dev/null 2>&1; then
  _state="${RESULTS[sftpgo]:-$(docker inspect --format=\'{{.State.Status}}\' sftpgo 2>/dev/null || echo missing)}"
  _SERVICES_JSON+="  \"sftpgo\": \"$_state\",\n"
fi

python3 - << PYEOF
import json, sys

# Parse services from bash-built string
raw = """${_SERVICES_JSON}"""
services = {}
for line in raw.strip().splitlines():
    line = line.strip().rstrip(",")
    if not line:
        continue
    try:
        k, v = line.split(": ", 1)
        services[k.strip('"')] = v.strip('"')
    except ValueError:
        pass

data = {
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "hostname": "$(hostname -s)",
    "healthy": $HEALTHY,
    "errors": $ERRORS,
    "services": services
}
print(json.dumps(data, indent=2))
PYEOF
# FIX v22: retornar exit code correcto en modo JSON (antes siempre salía 0)
exit $([[ $ERRORS -eq 0 ]] && echo 0 || echo 1)
else
  for svc in "${SERVICES[@]}"; do
    state="${RESULTS[$svc]}"
    if [[ "$state" == "OK" ]]; then
      printf "\033[0;32m  ✓ %-20s OK\033[0m\n" "$svc"
    else
      printf "\033[0;31m  ✗ %-20s %s\033[0m\n" "$svc" "$state"
    fi
  done
  echo ""
  if [[ $ERRORS -eq 0 ]]; then
    echo -e "\033[0;32m  Todos los servicios saludables\033[0m"
    exit 0
  else
    echo -e "\033[0;31m  $ERRORS servicio(s) con problemas\033[0m"
    exit 1
  fi
fi
