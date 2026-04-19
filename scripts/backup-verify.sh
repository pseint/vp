#!/usr/bin/env bash
# =============================================================
# BACKUP-VERIFY — Verifica integridad de los backups
# Uso: ./scripts/backup-verify.sh [ruta-backup]
# Sin argumento: verifica el último backup
# =============================================================
set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/hosting}"
[[ -f "$INSTALL_DIR/.env" ]] && source "$INSTALL_DIR/.env"

BACKUP_DIR="${BACKUP_DIR:-/opt/hosting/data/backups}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { printf "${GREEN}  ✓ %-40s OK${NC}\n" "$1"; }
fail() { printf "${RED}  ✗ %-40s FALLO: %s${NC}\n" "$1" "$2"; ((ERRORS++)) || true; }
warn() { printf "${YELLOW}  ⚠ %-40s %s${NC}\n" "$1" "$2"; }

ERRORS=0

# Determinar qué backup verificar
if [[ -n "${1:-}" ]]; then
  BACKUP_PATH="$1"
else
  BACKUP_PATH=$(ls -dt "${BACKUP_DIR}"/*/ 2>/dev/null | head -1 | sed 's|/$||')
fi

[[ -z "$BACKUP_PATH" ]] && { echo "No hay backups en $BACKUP_DIR"; exit 1; }
[[ -d "$BACKUP_PATH" ]] || { echo "Directorio no encontrado: $BACKUP_PATH"; exit 1; }

echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  VERIFICACIÓN DE BACKUP${NC}"
echo -e "${BOLD}${CYAN}  $BACKUP_PATH${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}\n"

# ── Verificar estructura ──────────────────────────────────────
echo -e "${BOLD}Estructura:${NC}"
for dir in db files config; do
  if [[ -d "$BACKUP_PATH/$dir" ]]; then
    size=$(du -sh "$BACKUP_PATH/$dir" 2>/dev/null | cut -f1)
    ok "$dir/" "$size"
  else
    fail "$dir/" "directorio no encontrado"
  fi
done

# ── Verificar dumps de bases de datos ────────────────────────
echo -e "\n${BOLD}Bases de datos:${NC}"
db_count=0
for dump in "$BACKUP_PATH/db/"*.sql.gz; do
  [[ -f "$dump" ]] || continue
  db_name=$(basename "$dump" .sql.gz)
  size=$(du -sh "$dump" | cut -f1)
  
  # Test integridad del gzip
  if gunzip -t "$dump" 2>/dev/null; then
    ok "$db_name.sql.gz ($size)" ""
  else
    fail "$db_name.sql.gz" "archivo gzip corrupto"
  fi
  ((db_count++)) || true
done
[[ $db_count -eq 0 ]] && warn "bases de datos" "ningún dump encontrado"

# ── Verificar archivos de sitios ─────────────────────────────
echo -e "\n${BOLD}Archivos de sitios:${NC}"
SITES_ARCHIVE="$BACKUP_PATH/files/sites.tar.gz"
if [[ -f "$SITES_ARCHIVE" ]]; then
  size=$(du -sh "$SITES_ARCHIVE" | cut -f1)
  if gunzip -t "$SITES_ARCHIVE" 2>/dev/null; then
    site_count=$(tar -tzf "$SITES_ARCHIVE" 2>/dev/null | grep -c "/$" || echo "0")
    ok "sites.tar.gz ($size)" "$site_count directorios"
  else
    fail "sites.tar.gz" "archivo corrupto"
  fi
else
  warn "sites.tar.gz" "no encontrado"
fi

# ── Verificar config ─────────────────────────────────────────
echo -e "\n${BOLD}Configuración:${NC}"
CONFIG_ARCHIVE="$BACKUP_PATH/config/hosting-config.tar.gz"
if [[ -f "$CONFIG_ARCHIVE" ]]; then
  size=$(du -sh "$CONFIG_ARCHIVE" | cut -f1)
  if gunzip -t "$CONFIG_ARCHIVE" 2>/dev/null; then
    ok "hosting-config.tar.gz ($size)" ""
  else
    fail "hosting-config.tar.gz" "archivo corrupto"
  fi
else
  warn "hosting-config.tar.gz" "no encontrado"
fi

[[ -f "$BACKUP_PATH/config/.env.enc" ]] && ok ".env.enc (cifrado)" "" || warn ".env.enc" "no encontrado"

# ── Verificar volúmenes de servicio (FIX v16) ────────────────
echo -e "\n${BOLD}Volúmenes de servicio:${NC}"
for vol in sftpgo-data portainer-data; do
  archive="$BACKUP_PATH/files/${vol}.tar.gz"
  if [[ -f "$archive" ]]; then
    size=$(du -sh "$archive" | cut -f1)
    if gunzip -t "$archive" 2>/dev/null; then
      ok "${vol}.tar.gz ($size)" ""
    else
      fail "${vol}.tar.gz" "archivo corrupto"
    fi
  else
    warn "${vol}.tar.gz" "no encontrado (opcional si servicio inactivo)"
  fi
done

# ── Resumen ───────────────────────────────────────────────────
TOTAL_SIZE=$(du -sh "$BACKUP_PATH" | cut -f1)
echo -e "\n${BOLD}Resumen:${NC}"
echo "  Backup: $BACKUP_PATH"
echo "  Tamaño total: $TOTAL_SIZE"
echo "  DBs verificadas: $db_count"
echo ""

if [[ $ERRORS -eq 0 ]]; then
  echo -e "${GREEN}  ✓ Backup íntegro — todos los archivos OK${NC}"
  exit 0
else
  echo -e "${RED}  ✗ $ERRORS error(es) encontrado(s) — backup puede estar corrupto${NC}"
  exit 1
fi
