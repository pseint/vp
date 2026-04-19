# =============================================================
# MAKEFILE v13 — Gestión del servidor hosting Oracle VPS
# Uso: make <comando>
# Ejemplo: make up | make logs | make add-site DOMAIN=mi-sitio.com
# =============================================================

INSTALL_DIR ?= /opt/hosting
COMPOSE     := docker compose
SHELL       := /bin/bash

.PHONY: help up down restart status logs ps pull update \
        add-site add-domain add-wp wp update-wp del-site \
        backup restore ssl-check list-sites \
        db-shell redis-shell nginx-reload nginx-test create-db \
        prune monitor fix-perms \
        backup-verify health-check health-json

# ── Ayuda ─────────────────────────────────────────────────────
help: ## Muestra esta ayuda
	@echo ""
	@echo "\033[1m\033[36m SERVIDOR HOSTING — COMANDOS DISPONIBLES\033[0m"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[32m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Ejemplos:"
	@echo "  make add-site DOMAIN=ejemplo.com"
	@echo "  make add-wp   DOMAIN=ejemplo.com"
	@echo "  make backup"
	@echo "  make logs SERVICE=nginx"
	@echo ""

# ── Stack ──────────────────────────────────────────────────────
up: ## Iniciar todos los servicios
	$(COMPOSE) up -d

down: ## Detener todos los servicios
	$(COMPOSE) down

restart: ## Reiniciar todos los servicios (o SERVICE=nginx)
	$(COMPOSE) restart $(SERVICE)

ps: ## Estado de contenedores
	$(COMPOSE) ps

status: ## Diagnóstico completo del servidor
	@bash scripts/status.sh

logs: ## Ver logs en tiempo real (SERVICE=traefik|nginx|php-fpm|mariadb|redis)
	$(COMPOSE) logs -f --tail=100 $(SERVICE)

pull: ## Descargar últimas imágenes
	$(COMPOSE) pull

update: ## Actualizar stack completo (con backup previo)
	@bash scripts/update-stack.sh $(SERVICE)

# ── Sitios web ─────────────────────────────────────────────────
add-site: ## Crear sitio PHP (DOMAIN=ejemplo.com [TYPE=php|static|wordpress])
	@[[ -n "$(DOMAIN)" ]] || (echo "Error: DOMAIN requerido. Ej: make add-site DOMAIN=ejemplo.com" && exit 1)
	@bash scripts/add-vhost.sh $(DOMAIN) $(or $(TYPE),php)

add-domain: ## Agregar dominio al DNS (DOMAIN=ejemplo.com [IP=1.2.3.4])
	@[[ -n "$(DOMAIN)" ]] || (echo "Error: DOMAIN requerido" && exit 1)
	@bash scripts/add-domain.sh $(DOMAIN) $(IP)

add-wp: ## Instalar WordPress completo (DOMAIN=ejemplo.com)
	@[[ -n "$(DOMAIN)" ]] || (echo "Error: DOMAIN requerido. Ej: make add-wp DOMAIN=miwp.com" && exit 1)
	@bash scripts/install-wordpress.sh $(DOMAIN)

wp: ## Ejecutar WP-CLI en un sitio (DOMAIN=ejemplo.com CMD="plugin list")
	@[[ -n "$(DOMAIN)" ]] || (echo "Error: DOMAIN y CMD requeridos. Ej: make wp DOMAIN=miwp.com CMD='plugin list'" && exit 1)
	@[[ -n "$(CMD)" ]] || (echo "Error: CMD requerido. Ej: make wp DOMAIN=miwp.com CMD='core version'" && exit 1)
	@docker exec php-fpm wp --path=/var/www/html/$(DOMAIN) --allow-root $(CMD)

update-wp: ## Actualizar WordPress core + plugins + themes (DOMAIN=ejemplo.com)
	@[[ -n "$(DOMAIN)" ]] || (echo "Error: DOMAIN requerido. Ej: make update-wp DOMAIN=miwp.com" && exit 1)
	@echo "→ Actualizando WordPress en $(DOMAIN)..."
	@docker exec php-fpm wp --path=/var/www/html/$(DOMAIN) --allow-root core update 2>/dev/null && echo "  ✓ Core actualizado" || echo "  ✓ Core ya está al día"
	@docker exec php-fpm wp --path=/var/www/html/$(DOMAIN) --allow-root plugin update --all 2>/dev/null && echo "  ✓ Plugins actualizados" || true
	@docker exec php-fpm wp --path=/var/www/html/$(DOMAIN) --allow-root theme update --all  2>/dev/null && echo "  ✓ Themes actualizados"  || true
	@echo "✓ WordPress $(DOMAIN) actualizado"

del-site: ## Eliminar sitio (DOMAIN=ejemplo.com [MODE=--vhost-only|--all])
	@[[ -n "$(DOMAIN)" ]] || (echo "Error: DOMAIN requerido" && exit 1)
	@bash scripts/del-domain.sh $(DOMAIN) $(or $(MODE),--vhost-only)

list-sites: ## Listar todos los sitios activos
	@bash scripts/list-sites.sh

# ── Backup ────────────────────────────────────────────────────
backup: ## Backup completo (db + archivos + config)
	@bash scripts/backup.sh full

backup-db: ## Backup solo de bases de datos
	@bash scripts/backup.sh db

restore: ## Restaurar backup (BACKUP=/ruta/backup [MODE=--all])
	@[[ -n "$(BACKUP)" ]] || (echo "Error: BACKUP requerido. Ej: make restore BACKUP=/opt/hosting/data/backups/20250101_030000" && exit 1)
	@bash scripts/restore.sh $(BACKUP) $(or $(MODE),--all)

# ── SSL ───────────────────────────────────────────────────────
ssl-check: ## Verificar certificados SSL (DOMAIN=opcional)
	@bash scripts/ssl-check.sh $(DOMAIN)

# ── Bases de datos ─────────────────────────────────────────────
db-shell: ## Acceso a MariaDB (DB=nombre_db opcional)
	@source .env && MYSQL_PWD="$$DB_ROOT_PASS" docker exec -it mariadb mariadb -uroot $(DB)

redis-shell: ## Acceso a Redis CLI
	@source .env && docker exec -it redis redis-cli -a "$$REDIS_PASS"

create-db: ## Crear BD para sitio (SITE=nombre)
	@[[ -n "$(SITE)" ]] || (echo "Error: SITE requerido. Ej: make create-db SITE=mi_sitio" && exit 1)
	@bash scripts/create-db.sh $(SITE)

# ── Nginx ─────────────────────────────────────────────────────
nginx-reload: ## Recargar configuración de Nginx
	@docker exec nginx nginx -t && docker exec nginx nginx -s reload && echo "✓ Nginx recargado"

nginx-test: ## Verificar configuración de Nginx
	@docker exec nginx nginx -t

# ── Mantenimiento ─────────────────────────────────────────────
prune: ## Limpiar imágenes y contenedores no usados
	@docker system prune -f --filter "until=168h"
	@docker image prune -f
	@echo "✓ Limpieza completada"

monitor: ## Ejecutar monitor manual
	@bash scripts/monitor.sh

fix-perms: ## Corregir permisos de archivos de sitios
	@SITES_VOL=$$(docker volume inspect hosting_sites-data --format '{{.Mountpoint}}'); \
	 docker exec php-fpm chown -R www-data:www-data /var/www/html; \
	 docker exec php-fpm find /var/www/html -type d -exec chmod 755 {} \;; \
	 docker exec php-fpm find /var/www/html -type f -exec chmod 644 {} \;; \
	 echo "✓ Permisos corregidos"

# ── Desarrollo ────────────────────────────────────────────────
debug-on: ## Activar modo debug (docker-compose.override.yml)
	@[[ -f docker-compose.override.yml.example ]] && \
	 cp docker-compose.override.yml.example docker-compose.override.yml && \
	 echo "✓ Debug activado. Ejecuta: make restart" || \
	 echo "docker-compose.override.yml.example no encontrado"

debug-off: ## Desactivar modo debug
	@rm -f docker-compose.override.yml
	@make restart
	@echo "✓ Debug desactivado"

# ── Targets v4 nuevos ─────────────────────────────────────────

# SFTPGo
sftp-up: ## Activar SFTPGo (servidor SFTP por cliente)
	docker compose --profile sftp up -d sftpgo
	@echo "SFTPGo activo — Panel: https://sftp.$$(grep '^DOMAIN=' .env | cut -d= -f2)"

sftp-setup: ## Configuración inicial de SFTPGo (solo primera vez)
	@bash scripts/sftp-user.sh - - setup

sftp-add: ## Crear usuario SFTP para un cliente (interactivo)
	@read -p "Dominio del cliente: " d; read -p "Cuota GB [5]: " q; \
	  bash scripts/sftp-user.sh "$$d" "$${q:-5}" add

sftp-passwd: ## Cambiar contraseña SFTP de un cliente (DOMAIN=ejemplo.com)
	@[[ -n "$(DOMAIN)" ]] || (echo "Error: DOMAIN requerido. Ej: make sftp-passwd DOMAIN=cliente.com" && exit 1)
	@bash scripts/sftp-user.sh "$(DOMAIN)" 0 passwd

sftp-del: ## Eliminar usuario SFTP (DOMAIN=ejemplo.com)
	@[[ -n "$(DOMAIN)" ]] || (echo "Error: DOMAIN requerido" && exit 1)
	@bash scripts/sftp-user.sh "$(DOMAIN)" 0 del

sftp-list: ## Listar usuarios SFTP activos
	@bash scripts/sftp-user.sh - - list

# Facturación
billing: ## Instalar FOSSBilling (sistema de facturación)
	@bash scripts/setup-fossbilling.sh

# Correo
mailcow: ## Instalar Mailcow (servidor de correo)
	@bash scripts/setup-mailcow.sh

# Wildcard SSL — test
ssl-wildcard-test:
	@echo "Asegúrate de tener CF_DNS_API_TOKEN en .env"
	@echo "Luego añade en labels: tls.certresolver=letsencrypt-wildcard"

.PHONY: sftp-up sftp-setup sftp-add sftp-passwd sftp-del sftp-list billing mailcow ssl-wildcard-test

# ── Targets v5 ────────────────────────────────────────────────
backup-verify: ## Verificar integridad del último backup (o BACKUP=/ruta)
	@bash scripts/backup-verify.sh $(BACKUP)

health-check: ## Diagnóstico rápido de salud (exit 0=OK, 1=problemas)
	@bash scripts/health-check.sh

health-json: ## Estado de salud en formato JSON
	@bash scripts/health-check.sh --json

backup-offsite: ## Backup completo + sync a remoto rclone
	@bash scripts/backup.sh full --offsite

rclone-config: ## Configurar destino backup offsite (rclone)
	@echo "Configurando rclone para backup offsite..."
	@rclone config
	@echo ""
	@echo "Una vez configurado, añade a .env:"
	@echo '  RCLONE_REMOTE=nombre-remote:bucket/carpeta'

alert-test: ## Probar alertas Telegram/webhook
	@source .env; \
	  if [[ -n "$$TELEGRAM_BOT_TOKEN" ]]; then \
	    curl -s -X POST "https://api.telegram.org/bot$$TELEGRAM_BOT_TOKEN/sendMessage" \
	      -d "chat_id=$$TELEGRAM_CHAT_ID" \
	      -d "text=✅ Test alerta hosting $(hostname -s)" > /dev/null && \
	    echo "✓ Alerta Telegram enviada"; \
	  else \
	    echo "TELEGRAM_BOT_TOKEN no configurado en .env"; \
	  fi

.PHONY: backup-offsite rclone-config alert-test backup-verify health-check health-json

# ── Targets v6 ────────────────────────────────────────────────
fail2ban-status: ## Estado de Fail2ban y IPs baneadas
	@fail2ban-client status 2>/dev/null || echo "Fail2ban no activo"

fail2ban-unban: ## Desbanear IP (IP=1.2.3.4)
	@[[ -n "$(IP)" ]] || (echo "Error: IP requerida. Ej: make fail2ban-unban IP=1.2.3.4" && exit 1)
	@fail2ban-client unban $(IP) && echo "✓ IP $(IP) desbaneada"

del-site-full: ## Eliminar sitio completo con BD y DNS (DOMAIN=ejemplo.com)
	@[[ -n "$(DOMAIN)" ]] || (echo "Error: DOMAIN requerido" && exit 1)
	@bash scripts/del-domain.sh $(DOMAIN) --all

ssl-renew: ## Forzar renovación de certificados SSL
	@bash scripts/ssl-check.sh

nginx-cache-clear: ## Limpiar caché FastCGI de Nginx
	@docker exec nginx find /var/cache/nginx/fastcgi -type f -delete 2>/dev/null || true
	@echo "✓ Caché Nginx limpiada"

nginx-cache-size: ## Ver tamaño actual de la caché Nginx
	@CACHE_VOL=$$(docker volume inspect hosting_nginx-cache --format '{{.Mountpoint}}' 2>/dev/null); \
	  [[ -n "$$CACHE_VOL" ]] && du -sh "$$CACHE_VOL" || echo "Caché no encontrada"

.PHONY: fail2ban-status fail2ban-unban del-site-full ssl-renew nginx-cache-clear nginx-cache-size

# ── Targets v7 — Diagnóstico avanzado ─────────────────────────
db-list: ## Listar todas las bases de datos con tamaño
	@source .env && MYSQL_PWD="$$DB_ROOT_PASS" docker exec mariadb mariadb -uroot \
	  --batch \
	  -e "SELECT table_schema AS 'Base de datos', \
	      ROUND(SUM(data_length+index_length)/1024/1024,1) AS 'Tamaño (MB)', \
	      COUNT(*) AS 'Tablas' \
	      FROM information_schema.tables \
	      WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys') \
	      GROUP BY table_schema ORDER BY 2 DESC;"

php-info: ## Ver configuración PHP activa
	@docker exec php-fpm php -i | grep -E "^(PHP Version|memory_limit|upload_max|post_max|disable_functions|session.save_path)" | head -20

php-error-log: ## Ver errores PHP recientes
	@docker logs php-fpm --since=1h 2>&1 | grep -i "error\|warning\|fatal" | tail -50

cache-stats: ## Estadísticas de caché (Redis + Nginx FastCGI)
	@echo "=== Redis ===" && source .env && \
	  docker exec redis redis-cli -a "$$REDIS_PASS" INFO memory | \
	  grep -E "used_memory_human|maxmemory_human|mem_fragmentation"
	@echo "=== Nginx FastCGI Cache ===" && \
	  CACHE=$$(docker volume inspect hosting_nginx-cache --format '{{.Mountpoint}}' 2>/dev/null); \
	  [[ -n "$$CACHE" ]] && du -sh "$$CACHE" || echo "Cache no montada"

top-containers: ## Ver uso de CPU/RAM de contenedores
	@docker stats --no-stream --format "table {{.Name}}	{{.CPUPerc}}	{{.MemUsage}}	{{.MemPerc}}"

inode-check: ## Verificar uso de inodos en disco
	@df -i / | awk 'NR==2 {printf "Inodos: %s usados de %s (%.1f%%)\n", $$3, $$2, $$5+0}'
	@find /var/lib/docker -maxdepth 3 -type d 2>/dev/null | wc -l | xargs echo "Directorios en Docker:"

.PHONY: db-list php-info php-error-log cache-stats top-containers inode-check


# ── SSL staging/production toggle ────────────────────────────
ssl-staging: ## Cambiar a Let's Encrypt STAGING (pruebas, sin rate limits)
	@echo "⚠ Eliminando acme.json de staging previo (si existe)..."
	@docker volume inspect hosting_traefik-acme &>/dev/null && \
	  docker run --rm -v hosting_traefik-acme:/acme alpine rm -f /acme/acme-staging.json || true
	@sed -i 's/certresolver=letsencrypt$$/certresolver=letsencrypt-staging/g' docker-compose.yml
	@sed -i 's/certresolver=letsencrypt-staging$$/certresolver=letsencrypt-staging/g' nginx/sites-enabled/*.conf 2>/dev/null || true
	@docker compose restart traefik
	@echo "✓ Traefik usando STAGING — certificados de prueba (navegador mostrará advertencia)"

ssl-production: ## Cambiar a Let's Encrypt PRODUCTION (certificados válidos)
	@sed -i 's/certresolver=letsencrypt-staging/certresolver=letsencrypt/g' docker-compose.yml
	@docker compose restart traefik
	@echo "✓ Traefik usando PRODUCTION — certificados válidos"

health: ## Ver estado de salud de todos los contenedores
	@docker ps --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}"

.PHONY: ssl-staging ssl-production health

# ── Diagnóstico avanzado v20 ──────────────────────────────────
diagnose: ## Diagnóstico completo: sistema, red, stack, SSL, BD, fail2ban
	@bash scripts/diagnose.sh --full

diagnose-net: ## Diagnóstico solo de red y DNS
	@bash scripts/diagnose.sh --net

diagnose-stack: ## Diagnóstico solo de contenedores y HTTP
	@bash scripts/diagnose.sh --stack

diagnose-ssl: ## Diagnóstico solo de certificados SSL
	@bash scripts/diagnose.sh --ssl

.PHONY: diagnose diagnose-net diagnose-stack diagnose-ssl

# ── Herramientas adicionales v20 ──────────────────────────────
build: ## Reconstruir imagen PHP-FPM (aplica cambios en Dockerfile/php.ini)
	@echo "→ Reconstruyendo php-fpm..."
	@cd "$$INSTALL_DIR" 2>/dev/null || true && docker compose build --no-cache php-fpm
	@docker compose up -d php-fpm
	@echo "✓ php-fpm reconstruido y reiniciado"

wp-cache-flush: ## Vaciar caché de WordPress (Redis + Nginx FastCGI)
	@echo "=== Vaciando caché WordPress ==="
	@source .env && docker exec php-fpm bash -c \
	  "for site in /var/www/html/*/; do \
	     [[ -f \"\$${site}wp-config.php\" ]] && wp --path=\"\$$site\" --allow-root cache flush 2>/dev/null && echo \"  ✓ \$${site}\"; \
	   done" 2>/dev/null || echo "Sin sitios WP o wp-cli no disponible"
	@source .env && docker exec redis redis-cli -a "$$REDIS_PASS" FLUSHDB 2>/dev/null && echo "  ✓ Redis FLUSHDB" || true
	@CACHE=$$(docker volume inspect hosting_nginx-cache --format '{{.Mountpoint}}' 2>/dev/null); \
	  [[ -n "$$CACHE" ]] && find "$$CACHE" -type f -delete 2>/dev/null && echo "  ✓ Nginx FastCGI cache limpiado" || true

redis-flush: ## Vaciar completamente Redis (todos los datos)
	@source .env && docker exec redis redis-cli -a "$$REDIS_PASS" FLUSHALL
	@echo "✓ Redis vaciado completamente (FLUSHALL)"

logs-size: ## Ver tamaño de logs de Docker por contenedor
	@echo "=== Tamaño de logs Docker ==="
	@for c in $$(docker ps --format '{{.Names}}'); do \
	  log_path=$$(docker inspect "$$c" --format '{{.LogPath}}' 2>/dev/null); \
	  [[ -f "$$log_path" ]] && printf "  %-20s %s\n" "$$c" "$$(du -sh "$$log_path" | cut -f1)"; \
	done

disk-full: ## Limpieza agresiva de disco: prune imágenes, build cache, logs truncados
	@echo "=== Limpieza agresiva de disco ==="
	@docker system prune -af --volumes 2>/dev/null && echo "  ✓ docker system prune -af --volumes"
	@docker builder prune -af 2>/dev/null && echo "  ✓ builder cache limpiado"
	@find /var/log -name "*.log" -size +50M -exec truncate -s 0 {} \; 2>/dev/null && echo "  ✓ Logs >50MB truncados"
	@echo "→ Espacio libre:"; df -h / | tail -1

.PHONY: build wp-cache-flush redis-flush logs-size disk-full
