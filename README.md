# 🚀 Oracle VPS Free — Servidor Hosting Completo v21

Stack de hosting completo para **Oracle Cloud Free Tier (ARM64 / Ampere A1)** con Docker Compose. SSL automático, DNS autoritativo, PHP-FPM, MariaDB, Redis y gestión visual.

## 📦 Stack

| Servicio | Imagen | Función |
|---|---|---|
| **Traefik v3.1** | `traefik:v3.1` | Reverse proxy + SSL automático (Let's Encrypt) |
| **Nginx** | `nginx:1.27-alpine` | Servidor web / virtual hosts |
| **PHP-FPM 8.3** | Custom (Alpine) | Procesador PHP con extensiones completas |
| **MariaDB 11.4** | `mariadb:11.4` | Base de datos SQL |
| **Redis 7.4** | `redis:7.4-alpine` | Cache y sesiones |
| **PowerDNS 4.9** | `powerdns/pdns-auth-49` | Servidor DNS autoritativo |
| **PowerDNS Admin** | `powerdnsadmin/pda-legacy` | Interfaz web para DNS |
| **Portainer CE** | `portainer/portainer-ce` | Gestión visual Docker |

## ⚡ Instalación rápida

```bash
# 1. Clonar / descomprimir el proyecto
cd /opt && tar -xzf hosting-oracle-arm64-v22-FINAL.tar.gz && cd hosting-oracle-arm64-v22

# 2. Configurar entorno (genera .env + .htpasswd + reemplaza placeholders)
bash scripts/setup-env.sh

# 3. Abrir puertos Oracle Cloud (iptables del sistema)
sudo bash scripts/oracle-firewall.sh

# 4. Instalar todo (Docker, deps, stack completo)
sudo bash install.sh
```

> ⚠️ **Antes de instalar**: Abre los puertos en Oracle Cloud Console → Networking → Security Lists:
> TCP: 22, 80, 443, 53, 8080, 9443 | UDP: 53

## 🌐 Accesos tras la instalación

| Panel | URL |
|---|---|
| Web principal | `https://TU-DOMINIO.com` |
| Traefik dashboard | `http://IP:8080` (usuario: admin) |
| Portainer | `https://IP:9443` |
| PowerDNS Admin | `https://dns.TU-DOMINIO.com` |

## 🛠 Gestión diaria con Make

```bash
# Ver todos los comandos disponibles
make help

# Estado completo del servidor
make status

# Ver logs en tiempo real
make logs SERVICE=nginx
make logs SERVICE=traefik

# Reiniciar un servicio
make restart SERVICE=php-fpm
```

## 🌍 Gestión de sitios web

```bash
# Nuevo sitio PHP
make add-site DOMAIN=ejemplo.com

# Nuevo sitio estático (HTML/CSS/JS)
make add-site DOMAIN=ejemplo.com TYPE=static

# Instalar WordPress completo (vhost + DB + WP descargado + wp-config)
make add-wp DOMAIN=miweb.com

# Listar todos los sitios activos con tamaño y BD
make list-sites

# Eliminar solo el vhost (conserva archivos y DNS)
make del-site DOMAIN=ejemplo.com

# Eliminar vhost + zona DNS
make del-site DOMAIN=ejemplo.com MODE=--all
```

## 🌐 Gestión de DNS

```bash
# Agregar dominio al DNS con registros básicos (A, NS, MX, SPF)
make add-domain DOMAIN=ejemplo.com

# Agregar con IP específica (otro servidor)
make add-domain DOMAIN=ejemplo.com IP=5.6.7.8

# O con el script directamente
bash scripts/add-domain.sh ejemplo.com [IP] [TTL]
```

## 🗄 Bases de datos

```bash
# Crear BD para un nuevo sitio
make create-db SITE=mi_sitio

# Acceso a MariaDB shell
make db-shell

# Acceso a una BD específica
make db-shell DB=nombre_base_de_datos

# Acceso a Redis CLI
make redis-shell
```

## 💾 Backup y restauración

```bash
# Backup completo (DB + archivos + config cifrada)
make backup

# Backup solo de bases de datos
make backup-db

# Ver backups disponibles
ls /opt/hosting/data/backups/

# Restaurar backup completo
make restore BACKUP=/opt/hosting/data/backups/20250601_030000

# Restaurar solo bases de datos
make restore BACKUP=/opt/hosting/data/backups/20250601_030000 MODE=--db
```

Los backups se realizan automáticamente cada día a las 3:00 AM y se retienen 7 días.

## 🔒 Certificados SSL

```bash
# Ver estado de todos los certificados
make ssl-check

# Verificar dominio específico
make ssl-check DOMAIN=ejemplo.com
```

Traefik renueva los certificados automáticamente 30 días antes de expirar. No requiere intervención manual.

## 🔄 Actualizaciones

```bash
# Actualizar todo el stack (con backup previo automático)
make update

# Actualizar un servicio específico
make update SERVICE=nginx
```

## 🔧 Mantenimiento

```bash
# Corregir permisos de archivos de sitios
make fix-perms

# Limpiar imágenes Docker sin uso
make prune

# Ejecutar monitor de servicios manualmente
make monitor

# Recargar configuración de Nginx (tras editar vhosts)
make nginx-reload

# Validar configuración de Nginx sin recargar
make nginx-test
```

## 📁 Estructura del proyecto

```
hosting-oracle-arm64-v13/
├── docker-compose.yml          # Stack principal
├── docker-compose.override.yml.example  # Override para desarrollo
├── install.sh                  # Instalador completo
├── Makefile                    # Comandos de gestión
├── .env.example                # Plantilla de variables
├── .gitignore                  # Excluye secretos del repo
│
├── traefik/
│   ├── traefik.yml             # Config estática Traefik
│   └── dynamic/
│       ├── middlewares.yml     # Middlewares (seguridad, auth, rate limit)
│       └── .htpasswd           # Generado por setup-env.sh ← NO commitear
│
├── nginx/
│   ├── nginx.conf              # Config global + rate limiting zones
│   ├── conf.d/
│   │   └── 00-default.conf    # Upstream PHP-FPM + servidor default
│   ├── sites-available/
│   │   └── template.conf      # Template para nuevos vhosts
│   ├── sites-enabled/          # Symlinks de vhosts activos (vacío inicial)
│   └── html/
│       ├── index.php           # Dashboard de estado del servidor
│       ├── 404.html            # Página 404 personalizada
│       └── 50x.html            # Página de error 5xx
│
├── php/
│   ├── Dockerfile              # PHP 8.3 Alpine + extensiones
│   ├── php.ini                 # Configuración PHP producción
│   ├── www.conf                # Pool PHP-FPM optimizado ARM64
│   └── .dockerignore
│
├── mariadb/
│   ├── conf.d/hosting.cnf     # MariaDB optimizado 512MB RAM
│   └── init/01-init.sql       # Inicialización DB (pdnsadmin, webuser)
│
├── dns/
│   └── pdns.conf              # PowerDNS configuración
│
├── redis/
│   └── redis.conf             # Redis 96MB maxmemory
│
├── fail2ban/
│   ├── jail.local             # Jails: SSH, nginx-limit-req, exploits
│   ├── filter-nginx-limit-req.conf
│   ├── filter-nginx-forbidden.conf
│   └── filter-nginx-exploit.conf
│
├── logrotate/
│   └── hosting                # Rotación diaria de logs Nginx/Traefik
│
├── logs/                      # Logs (nginx/, traefik/)
│
└── scripts/
    ├── setup-env.sh           # ← Ejecutar PRIMERO
    ├── oracle-firewall.sh     # ← Ejecutar SEGUNDO
    ├── install.sh             # ← Ejecutar TERCERO (o make up)
    ├── add-domain.sh          # Agregar zona DNS
    ├── add-vhost.sh           # Agregar virtual host Nginx
    ├── install-wordpress.sh   # WordPress completo en 1 comando
    ├── del-domain.sh          # Eliminar dominio/vhost
    ├── create-db.sh           # Crear base de datos
    ├── backup.sh              # Backup (DB + archivos + config)
    ├── restore.sh             # Restauración de backups
    ├── ssl-check.sh           # Estado de certificados SSL
    ├── list-sites.sh          # Listar sitios activos
    ├── monitor.sh             # Monitor (ejecutado por cron)
    ├── status.sh              # Diagnóstico completo
    ├── health-check.sh        # Health check rápido (exit code)
    ├── backup-verify.sh       # Verificar integridad de backups
    ├── update-stack.sh        # Actualizar imágenes Docker
    └── oracle-firewall.sh     # iptables Oracle Cloud
```

## 🐛 Bugs corregidos en v6 (histórico completo)

| Bug | Versión | Impacto | Fix |
|---|---|---|---|
| `${DOMAIN}` literal en `traefik.yml` | v1→v2 | SSL wildcard no funcionaba | Eliminado bloque `tls.domains` |
| `.htpasswd` nunca generado | v1→v2 | Dashboard Traefik inaccesible | `setup-env.sh` lo genera automáticamente |
| `limit_req_zone` ausente en Nginx | v2→v3 | Nginx fallaba al recargar | 5 zonas definidas en `nginx.conf` |
| `gmysql-socket=` vacío en pdns.conf | v2→v3 | PowerDNS no conectaba a MariaDB | Parámetros problemáticos eliminados |
| Healthcheck PHP-FPM falso (`php-fpm -t`) | v2→v3 | Contenedor siempre healthy aunque caído | `cgi-fcgi` contra `/fpm-ping` real |
| `${REDIS_PASS}` no interpolado en healthcheck | v2→v3 | Redis siempre unhealthy | `CMD-SHELL` con `$$REDIS_PASS` |
| Conflicto MariaDB init SQL vs env vars | v2→v3 | Errores de permisos en arranque | SQL restructurado |
| `acme.json` como bind mount Y named volume | v2→v3 | Certificados SSL no persistían | Solo named volume `traefik-acme` |
| `setup-env.sh` usaba `sed` con passwords | v2→v3 | Caracteres especiales rompían la sustitución | Reemplazado con Python |
| Fail2ban referenciaba filtros inexistentes | v2→v3 | Fail2ban no iniciaba | 3 filtros Nginx creados |
| FastCGI cache zone en vhost (no en http{}) | v3→v4 | Nginx rechazaba config WordPress | Zona global en `nginx.conf`, referencia en vhost |
| Dashboard Traefik ping usaba entrypoint web | v3→v4 | Healthcheck fallaba por redirección HTTPS | Ping usa entrypoint `traefik` (8080) |
| Portainer con headers frameDeny:true | v4→v5 | UI Portainer rota (iframes bloqueados) | Middleware separado `portainer-headers` |
| `insecure-transport` middleware mal definido | v5→v6 | Middleware `passTLSClientCert` incorrecto | Eliminado; solo existe en `serversTransports` |
| Nginx default site sin volumen `nginx/html` | v5→v6 | 404/50x y dashboard no cargaban | Añadido `./nginx/html:/var/www/html/default:ro` |
| `setup-env.sh` sin idempotencia | v5→v6 | Re-ejecución en producción corrompía config | Check interactivo si ya existe `.env` |
| Logrotate instalado sin sustituir INSTALL_DIR | v5→v6 | Rutas incorrectas si INSTALL_DIR ≠ /opt/hosting | Solo `install.sh` instala logrotate (con sed) |
| `MAIL_DOMAIN` ausente en `.env` generado | v5→v6 | `setup-mailcow.sh` usaba fallback silencioso | Añadido `MAIL_DOMAIN=mail.$DOMAIN` en `setup-env.sh` |
| Cron backup sin flag `--offsite` | v5→v6 | Backup offsite no se ejecutaba si RCLONE_REMOTE configurado | `backup.sh full --offsite` en crontab |
| `pdns-admin SECRET_KEY` = `PDNS_API_KEY` | v6→v7 | Mismo secreto para Flask y PowerDNS API | `PDNS_ADMIN_SECRET_KEY` independiente |
| `update-stack.sh` no reconstruía PHP-FPM | v6→v7 | Imagen custom desactualizada tras `make update` | `docker compose build --pull php-fpm` |
| `del-domain.sh` no limpiaba logs | v6→v7 | Logs huérfanos acumulándose en disco | Opción interactiva para eliminar logs |
| `backup.sh` sin esperar MariaDB healthy | v6→v7 | Dump fallaba en arranque de sistema | Espera activa con retries antes del dump |
| `SFTPGo` sin `depends_on: nginx` | v6→v7 | Race condition en arranque con volumen compartido | `depends_on: nginx` añadido |
| Traefik access log sin campo `RouterName` | v6→v7 | Difícil identificar qué sitio causó errores | Campo `RouterName: keep` añadido |
| WordPress vhost sin bypass `/wp-admin/` | v6→v7 | Panel admin de WP podía ser cacheado por FastCGI | Bloque `location /wp-admin` con `fastcgi_cache off` |
| Symlinks en `sites-enabled` absolutos | v6→v7 | Se rompían si se movía `INSTALL_DIR` | Symlinks relativos `../sites-available/` |
| Faltaba directorio `logs/sftpgo/` | v6→v7 | Fail2ban jail sftpgo no podía crear su logpath | Creado en `prepare_dirs()` de `install.sh` |
| Docker logging sin límites | v7→v8 | json-file podía llenar el disco | `max-size: 20m, max-file: 5` en todos los servicios |
| Imágenes `pdns-auth-49:latest` y `sftpgo:v2-alpine` sin pin | v7→v8 | Actualizaciones automáticas breaking | Versiones fijadas a `4.9.4` y `v2.6.4` |
| Traefik sin `forwardedHeaders.trustedIPs` | v7→v8 | Real IP de cliente podía ser spoofeable | Subredes Docker en `trustedIPs` |
| PHP sin `realpath_cache` | v7→v8 | `stat()` extra en cada `include/require` | `realpath_cache_size=4096K, ttl=600` |
| `add-domain.sh` sin registro DMARC | v7→v8 | Correos marcados como spam | Registro `_dmarc TXT v=DMARC1` añadido |
| `install.sh` sin preflight (disco/RAM) | v7→v8 | Instalación fallaba a mitad con disco lleno | Check de 10GB libres + RAM mínima |
| `setup-env.sh` acepta IPs privadas sin advertir | v7→v8 | Confusión con IPs privadas de Oracle | Detección y advertencia de rango privado |
| WordPress sin WP-CLI | v7→v8 | Gestión manual tedioso, no automatizable | WP-CLI instalado en PHP Dockerfile |
| fail2ban usa `iptables` en Ubuntu 24.04 (nftables) | v7→v8 | Fail2ban podía fallar silenciosamente | Auto-detect nftables en `install.sh` |
| Nginx sin `gzip_static` | v7→v8 | Assets pre-comprimidos no se servían como .gz | `gzip_static on` en nginx.conf |
| `REDIS_PASS` ausente en env de `php-fpm` | v8→v9 | Sesiones PHP fallaban si Redis tenía contraseña | `REDIS_PASS` + `DB_HOST/USER/PASS` en env |
| WP-CLI sin verificación de integridad | v8→v9 | Descarga sin checksum sha512 | `sha512sum -c` antes de instalar |
| `wp-config.php` sin `DISABLE_WP_CRON` | v8→v9 | WP-Cron interno lento y no confiable | `DISABLE_WP_CRON=true` + crontab sistema |
| `wp-config.php` sin `XMLRPC_REQUEST=false` | v8→v9 | XML-RPC habilitado (vector DDoS) | Deshabilitado en wp-config |
| Redis `allkeys-lru` evictaba sesiones PHP | v8→v9 | Usuarios perdían sesión sin avisar | `volatile-lru`: protege keys con TTL |
| `nginx-test` faltaba en `.PHONY` | v8→v9 | `make nginx-test` podía no funcionar como target | Añadido a `.PHONY` |
| Vhost estático sin error pages ni rate limit | v8→v9 | 404/50x sin página propia, sin protección | Error pages + `limit_req` añadidos |
| `add-domain.sh` sin instrucciones DKIM | v8→v9 | Admins sin guía para completar configuración email | Instrucciones de generación de clave DKIM |
| Nginx sin `$request_id` en logs | v8→v9 | Imposible correlacionar peticiones entre Nginx y PHP | `$request_id` en log JSON + header a PHP-FPM |
| **`x-logging` dentro de `services:`** | v9→v10 | Docker lo interpretaba como un servicio extra `x-logging` | Movido al nivel raíz del YAML |
| `php.ini` `session.save_path` solo en archivo | v9→v10 | Sin `setup-env.sh`, sesiones PHP fallaban | `www.conf` inyecta `$REDIS_PASS` como env var |
| `open_basedir` vacío en `www.conf` | v9→v10 | PHP podía leer `/etc/passwd`, `/etc/shadow` | Restringido a `/var/www/html:/tmp:/tmp/php-uploads` |
| Portainer sin rate-limit en Traefik | v9→v10 | Sin límite de intentos de acceso al panel | `rate-limit-api@file` añadido al router |
| `del_logs()` comilla sin cerrar en `read -rp` | v9→v10 | Error de sintaxis bash en ciertos terminales | Comillas corregidas con `$'...'` |
| Dockerfile PHP sin soporte Xdebug | v5→v6 | Override de debug ignoraba ARG XDEBUG=1 | ARG XDEBUG + instalación condicional |
| Healthchecks `pdns-admin`/`portainer` faltantes | v6→v7 | Monitor no detectaba caídas reales | Healthchecks añadidos vía wget/https |
| `monitor.sh` no verificaba `State.Health` | v6→v7 | Contenedores unhealthy no se reiniciaban | Verifica estado y health |
| `chmod 777` en wp-content | v6→v7 | Permiso world-write innecesario | `find -type d 755 / -type f 644`, wp-content 775 |
| `expire_logs_days` deprecated MariaDB 11 | v6→v7 | Warning en logs de MariaDB | `binlog_expire_logs_seconds=86400` |
| PHP 8.3 JIT no configurado | v6→v7 | Rendimiento PHP subóptimo | `opcache.jit=1255 + jit_buffer_size=128M` |
| `set -euo pipefail` faltaba en 4 scripts | v6→v7 | Errores silenciosos en scripts | Añadido a `list-sites.sh`, `ssl-check.sh`, `status.sh`, `monitor.sh` |
| `webuser` sin `GRANT CREATE` en MariaDB | v6→v7 | `create-db.sh` fallaba con permisos insuficientes | `GRANT CREATE ON *.*` añadido |
| Paths SITES_DATA hardcodeados | v6→v7 | Fallback estático roto en instalaciones custom | `docker volume inspect` dinámico |
| `backup.sh` sin alerta en fallo | v6→v7 | Fallos de backup silenciosos | Alert en `error()` + trap ERR |

| `file:` provider bajo `serversTransport:` en `traefik.yml` | v9→v10 | **CRÍTICO**: `middlewares.yml` nunca se cargaba → sin auth, sin security-headers, sin rate-limit | Movido `file:` bajo `providers:` |
| `SFTPGO_DATA_PROVIDER__DRIVER=memory` | v9→v10 | Todos los usuarios SFTP se pierden al reiniciar el contenedor | Cambiado a `bolt` (SQLite persistente en volumen) |
| Logs SFTPGo sin volumen montado | v9→v10 | Fail2ban jail `sftpgo` no podía leer logs | Volumen `./logs/sftpgo` descomentado |
| MASQUERADE no cubría `dns-net` (172.21.0.0/24) | v9→v10 | Contenedor PowerDNS sin acceso a internet para actualizaciones | Añadida regla MASQUERADE para ambas subredes |
| `SFTPGO_ADMIN_PASS` vacío en `setup-env.sh` | v9→v10 | Panel WebAdmin SFTPGo sin contraseña de admin | `gen_pass()` genera contraseña automáticamente |
| `README.md` apuntaba a `hosting-v8/` | v9→v10 | Instalación fallaba: directorio inexistente | `cd hosting-oracle-arm64-v20` en instrucciones |

| `SFTPGO_LOG_FILE_PATH` no configurado en docker-compose | v10→v11 | Logs de SFTPGo a stdout únicamente → fail2ban jail nunca detectaba intentos fallidos | `SFTPGO_LOG_FILE_PATH=/var/lib/sftpgo/logs/sftpgo.log` añadido |
| Fail2ban jail `[sftpgo]` con `enabled = false` | v10→v11 | Jail siempre deshabilitado aunque logs estuvieran montados | Habilitado ahora que el volumen y la env var existen |
| `sftp-user.sh setup_sftpgo()` ignoraba `SFTPGO_ADMIN_PASS` del `.env` | v10→v11 | Admin SFTPGo creado con contraseña diferente a la de `.env` → `sftp-user.sh add` fallaba | Función usa `${SFTPGO_ADMIN_PASS}` del `.env` generado por `setup-env.sh` |
| `SITES_DATA` hardcodeado en `sftp-user.sh` | v10→v11 | Fallaba en instalaciones con Docker data-root no estándar | `docker volume inspect` dinámico |
| `fail2ban/jail.local` con `backend = systemd` global | v10→v11 | Conflicto entre backend systemd y jails con `logpath` (file-based) | `backend = auto` en `[DEFAULT]`, `systemd` solo en `[sshd]` |
| `logrotate` Traefik usaba `kill -USR1` inválido | v10→v11 | SIGUSR1 no implementado en Traefik → señal ignorada, logs no rotaban | Reemplazado por `docker compose restart traefik` |
| `oracle-firewall.sh` `ExecStart` con path `/sbin` hardcodeado | v10→v11 | Ubuntu 24.04: `/sbin/iptables-restore` puede no existir como binario real | Fallback a `/usr/sbin/iptables-restore` |
| `install.sh` no reemplazaba placeholders si se saltaba `setup-env.sh` | v10→v11 | Sesiones PHP fallaban con password `REDIS_PASS_PLACEHOLDER` literal; PowerDNS no conectaba a MariaDB | `load_env()` reemplaza todos los placeholders desde `.env` |
| Comentario incorrecto en `redis.conf` decía `allkeys-lru` | v10→v11 | Confusión al diagnosticar política de evicción activa | Corregido a `volatile-lru` |

## 🔐 Seguridad

- **SSL/TLS**: Let's Encrypt automático, TLS 1.2+ con cipher suites modernas
- **Fail2ban**: Protección SSH, rate limiting Nginx, exploits, scanners
- **Rate limiting**: 3 zonas Nginx + rate limiting en Traefik
- **Headers**: HSTS, CSP, X-Frame-Options, X-Content-Type-Options
- **PHP**: `disable_functions` para exec/shell, sesiones seguras en Redis
- **MariaDB**: Sin `local_infile`, sin enlaces simbólicos
- **Redis**: Password requerido, comandos peligrosos disponibles solo internamente
- **Backups**: `.env` cifrado con AES-256

## 💡 Consejos para Oracle Free Tier

- **4 OCPUs + 24GB RAM**: Puedes aumentar los límites en `.env` (PHP_MEM, MARIADB_MEM)
- **Boot volume 200GB**: Sobra espacio para sitios y backups
- **IP pública estática**: Oracle Free incluye 1 IP pública permanente
- **Ancho de banda**: 10TB/mes saliente incluidos — más que suficiente
- **Siempre gratis**: Las instancias Ampere A1 son genuinamente gratuitas para siempre

## ❓ Solución de problemas

```bash
# Ver logs de un servicio con error
docker compose logs --tail=50 powerdns
docker compose logs --tail=50 traefik

# Nginx no recarga
docker exec nginx nginx -t  # Ver el error exacto

# PowerDNS no inicia (DB no lista)
docker compose restart powerdns

# SSL no se emite (verificar que el dominio apunte al servidor)
dig +short TU-DOMINIO.com A
curl -I http://TU-DOMINIO.com

# PHP-FPM no responde
docker exec php-fpm php -v
docker compose restart php-fpm

# Estado completo de diagnóstico
make status
```


### Cambios v11 → v12 → v13

| Bug / Mejora | Archivo | Detalle |
|---|---|---|
| `v10` en banner de install | `install.sh` | `print_summary()` y `main()` decían v10 en proyecto v11 |
| `SFTPGO_ADMIN_PASS` vacío | `setup-env.sh` | La contraseña se generaba solo en el heredoc, no como variable bash |
| Subnet `/16` incorrecta | `nginx/nginx.conf` | `set_real_ip_from 172.21.0.0/16` → `/24` (coincide con dns-net real) |
| `limit_req off` inválido | `nginx/conf.d/00-default.conf` | Sintaxis no soportada por nginx → config test fallaba al arrancar |
| **TODOS los jails fail2ban silenciosos** | `fail2ban/jail.local` | `filter = filter-nginx-*` pero install.sh copia como `nginx-*.conf` → ningún jail cargaba |
| YAML inválido | `setup-mailcow.sh` | Sintaxis de lista `- network:` con sub-claves no válida en Compose |
| DB sin backticks | `setup-fossbilling.sh` | SQL con nombre de BD sin escapar |
| Sin chequeo inodos | `monitor.sh` | Disco lleno en inodos no se detectaba |
| Sin HTTP/3 | `traefik.yml` + `docker-compose.yml` | Añadido QUIC/HTTP3 en entrypoint websecure + puerto UDP 443 |
| Targets útiles faltantes | `Makefile` | Añadidos: `db-list`, `php-info`, `cache-stats`, `top-containers`, `inode-check` |
| DKIM placeholder | `add-domain.sh` | Añadido registro `mail._domainkey` deshabilitado como recordatorio |
| Optimización MariaDB | `hosting.cnf` | `event_scheduler=OFF`, `innodb_doublewrite=OFF` para NVMe, `secure_file_priv` |

### Cambios v13 → v14

| Bug / Mejora | Archivo | Detalle |
|---|---|---|
| `enabled = false # inline comment` en jail.local | `fail2ban/jail.local` | Comentario en misma línea que valor — algunos parsers INI lo interpretan como truthy y activaban el jail `powerdns-flood` accidentalmente. Movido a línea propia. |
| `allow 172.0.0.0/8` demasiado amplio | `nginx/conf.d/00-default.conf` | Exponía `/fpm-status` y `/fpm-ping` a todo el rango 172.x.x.x. Corregido a `172.16.0.0/12` (rango estándar Docker) + `10.0.0.0/8`. |
| `symbolic-links = 0` deprecated en MariaDB 11.x | `mariadb/conf.d/hosting.cnf` | Parámetro eliminado en MariaDB 11 — generaba deprecation warnings en logs al arrancar. |
| `security-headers@file` como middleware global en entrypoint `websecure` | `traefik/traefik.yml` | Los middlewares del entrypoint se aplican **después** de los del router — `frameDeny: true` se aplicaba a Portainer incluso con `portainer-headers@file`, rompiendo su UI. Movido a nivel de router individual. |
| Faltaba rotación de logs SFTPGo | `logrotate/hosting` | El archivo `logs/sftpgo/sftpgo.log` nunca se rotaba y podía crecer sin límite. Añadido bloque `daily, rotate 7, copytruncate`. |
| Registro CAA ausente | `scripts/add-domain.sh` | Sin CAA, cualquier CA podía emitir certificados para el dominio. Añadido `CAA 0 issue "letsencrypt.org"` automáticamente al crear zonas. |
| Targets SFTP sin ## comentario | `Makefile` | `sftp-up`, `sftp-setup`, `sftp-add`, `sftp-list` no aparecían en `make help`. Añadidos comentarios `##`. |
| Targets `sftp-passwd` y `sftp-del` faltaban | `Makefile` | No había forma de cambiar contraseña o eliminar usuario SFTP desde `make`. Añadidos ambos targets. |
| Targets `billing` y `mailcow` sin ## | `Makefile` | No aparecían en `make help`. Añadidos. |
| `db-list` y `cache-stats` con `	` literales en Makefile | `Makefile` | Comandos multilínea con `	` hardcodeados (artefacto del editor) — causaban errores de sintaxis bash. Reescritos con saltos de línea correctos. |
| `ssl-staging` no limpiaba `acme-staging.json` previo | `Makefile` | Al cambiar a staging repetidamente, el JSON viejo causaba errores de renovación. Ahora borra el JSON antes de reiniciar Traefik. |
| Trap ERR antes de `send_alert()` en backup.sh | `scripts/backup.sh` | El trap referenciaba una función aún no definida. Movido después de la definición de `send_alert()`. |
| Variables opcionales duplicadas en `.env` | `scripts/setup-env.sh` | El bloque `append` al final añadía `TELEGRAM_BOT_TOKEN`, `RCLONE_REMOTE`, `SERVER_DOMAIN` como apéndice extra cada vez que se re-ejecutaba `setup-env.sh`, generando entradas duplicadas. Movidas al heredoc principal. |
| `opcache.jit=1255` puede causar segfaults en ARM64 | `php/php.ini` | El modo 1255 (optimize all) es inestable en algunas compilaciones Alpine/aarch64. Cambiado a `1254` (tracing mode, recomendado para producción ARM64). |
| JSON con coma final en `health-check.sh --json` | `scripts/health-check.sh` | El bucle bash generaba JSON con coma tras el último elemento, causando error al parsear con herramientas externas (`jq`, APIs). Reescrito para generar JSON válido. |
| `docker compose restart sftpgo` sin `--profile sftp` | `scripts/monitor.sh` | SFTPGo usa profile `sftp` — `restart` sin el profile fallaba silenciosamente. Cambiado a `docker compose --profile sftp up -d sftpgo`. |
| Comentario incorrecto sobre `XMLRPC_REQUEST` en wp-config | `scripts/install-wordpress.sh` | Constante inexistente en WordPress dejaba a los administradores confundidos sobre cómo deshabilitar XML-RPC. Reemplazado por comentario explicativo correcto. |

### Cambios v14 → v15

| # | Bug / Mejora | Archivo(s) | Detalle |
|---|---|---|---|
| 1 | **`limit_req_status 429` ausente** | `nginx/nginx.conf` | Nginx devolvía **503** al activarse rate limit — fail2ban jail `nginx-limit-req` filtra por **429** y nunca se disparaba. Todo el brute-force pasaba sin ser baneado. |
| 2 | **pdns-admin sin rate limiting** | `docker-compose.yml` | Router `dns.DOMAIN` no tenía `rate-limit-api@file` — el panel DNS podía ser atacado por fuerza bruta sin ningún límite de velocidad. |
| 3 | **pdns-admin `depends_on service_started`** | `docker-compose.yml` | Debería ser `service_healthy` — pdns-admin arrancaba antes de que PowerDNS terminara de inicializar su base de datos, causando errores 500 al primer acceso. |
| 4 | **`net.ipv4.tcp_syncookies = 1` faltaba** | `install.sh` | Protección crítica contra SYN flood ausente del sysctl. El servidor era vulnerable a ataques de denegación de servicio TCP. |
| 5 | **`mariadb-dump --add-drop-database` sin `--databases`** | `scripts/backup.sh` | Sin `--databases`, el flag `--add-drop-database` es **silenciosamente ignorado**. El dump no incluía `CREATE DATABASE`/`USE`, imposibilitando restaurar en un servidor nuevo sin intervención manual. |
| 6 | **curl WP-CLI y Composer sin `--retry`** | `php/Dockerfile` | En Oracle Free Tier la red puede ser inestable durante el build. Los downloads sin retry causaban builds fallidos al azar. Añadido `--retry 3 --retry-delay 2`. |
| 7 | **`responseHeaderTimeout: 30s` demasiado corto** | `traefik/traefik.yml` | WordPress con WooCommerce, generación de PDFs o imports masivos puede superar 30s. Traefik devolvía **504 Gateway Timeout** prematuramente. Subido a 120s. |
| 8 | **Glob sin comillas en `del-domain.sh`** | `scripts/del-domain.sh` | `du -sk "${LOG_DIR}/${DOMAIN}"*.log*` — glob desprotegido podía fallar silenciosamente o expandir incorrectamente. Reemplazado por la lista `found_logs[@]` ya construida. |
| 9 | **Comentario ausente `notify-keyspace-events`** | `redis/redis.conf` | Sin documentación sobre cuándo activarlo. WP Redis Object Cache necesita `"Ex"` para invalidación automática por expiración. |
| 10 | **`build --pull php-fpm` sin `--no-cache`** | `scripts/update-stack.sh` | Docker reutilizaba capas Alpine cacheadas aunque la imagen base tuviera parches de seguridad nuevos. Añadido `--no-cache`. |
| 11 | **Token SFTPGo con `grep` regex frágil** | `scripts/sftp-user.sh` | `grep -o '"access_token":"[^"]*"'` fallaba si el JSON tenía espacios o el orden de campos cambiaba entre versiones de SFTPGo. Reemplazado por `python3` con `json.load()`. |
| 12 | **Script `diagnose.sh` referenciado pero ausente** | `scripts/diagnose.sh` *(nuevo)* | El script aparecía en el Makefile y en la documentación como `make diagnose` pero no existía. Creado con diagnóstico completo: sistema, red, puertos, DNS, contenedores, HTTP, SSL, MariaDB, Redis y fail2ban. |

### Cambios adicionales (segunda pasada v15)

| # | Archivo | Bug | Impacto real |
|---|---|---|---|
| 13 | `dns/pdns.conf` | `webserver-allow-from=172.0.0.0/8` — rango no RFC 1918 | Seguridad: la API PowerDNS era accesible desde 172.0.x.x–172.15.x.x (IPs públicas) |
| 14 | `.env.example` | Cabecera decía `v11` | Confusión al configurar manualmente |
| 15 | `scripts/list-sites.sh` | `subprocess.run(['curl', '-H', 'X-API-Key: ...'])` | Seguridad: la API key de PowerDNS era visible en `ps aux` en texto plano |
| 16 | `php/www.conf` | `open_basedir` sin `/usr/local/share/php` | Extensions PECL de Alpine instalaban archivos PHP allí → "open_basedir restriction" en producción |
| 17 | `fail2ban/filter-nginx-exploit.conf` | `wget\s` y `curl\s` no coincidían en logs JSON | Espacios en URLs se codifican como `%20`/`+`; el jail nunca baneaba ataques con wget/curl en params |
| 18 | `scripts/install-wordpress.sh` | `chown www-data` en ruta del host | UID 33 (Debian) ≠ UID 1000 (Alpine container); wp-config.php con propietario incorrecto |
| 19 | `scripts/setup-fossbilling.sh` | **Crítico:** `` `${DB_NAME}` `` en string de doble comilla bash | Bash ejecutaba `${DB_NAME}` como comando shell; `CREATE DATABASE` fallaba silenciosamente con error de "command not found" |
| 20 | `scripts/setup-fossbilling.sh` | `chown` en ruta del host (igual que #18) | Mismo problema de UID inconsistente entre host y contenedor Alpine |
| 21 | `scripts/setup-mailcow.sh` | `check_port()` llamaba `error()` (exit 1) pero el bucle usaba `\|\| warn` | El `warn` nunca ejecutaba; el script moría al primer puerto ocupado en lugar de continuar con advertencia |
| 22 | `scripts/setup-mailcow.sh` | `git clone` sin `--depth 1` | Descargaba ~500MB de historial git completo de Mailcow innecesariamente |
| 23 | `scripts/setup-fossbilling.sh` | `curl -L` sin `--retry` para download FOSSBilling | Falla silenciosa en redes inestables de Oracle Free Tier |
| 24 | `scripts/setup-fossbilling.sh` | `unzip -q` sin `-o` | Fallaba si `/tmp/fossbilling-extracted/` existía de un intento previo abortado |
| 25 | `install.sh` | 4 banners de versión todavía decían `v14` | Banner del instalador, cron, y mensajes de finalización mostraban versión incorrecta |

---

## 📋 Changelog v16

### 🐛 Bugfixes críticos
- **`backup.sh`** — Eliminados comentarios `#` dentro del bloque de argumentos de `mariadb-dump` (bug bash silencioso: los comentarios se pasaban como argumentos al comando)
- **`monitor.sh`** — JSON del webhook genérico ahora usa `python3 json.dumps()` en vez de `sed` (escapado correcto de caracteres especiales, apóstrofes y barras)

### ✨ Nuevas funcionalidades
- **`make wp`** — Ejecutar WP-CLI en cualquier sitio: `make wp DOMAIN=miwp.com CMD="plugin list"`
- **`make update-wp`** — Actualizar WordPress core + plugins + themes en un comando
- **`backup.sh`** — Backup automático de volúmenes `sftpgo-data` y `portainer-data`
- **`backup-verify.sh`** — Verificación de integridad de los nuevos backups de volúmenes
- **`monitor.sh`** — Monitoreo de disco en volúmenes Docker (`sites-data`, `nginx-cache`)
- **`monitor.sh`** — Verifica y recrea `hosting-net` automáticamente si desaparece

### ⚡ Optimizaciones de rendimiento
- **`nginx.conf`** — `fastcgi_cache_lock on` + `lock_timeout 5s`: evita *cache stampede* bajo carga
- **`template.conf`** — FastCGI cache activo en el bloque PHP con bypass inteligente para usuarios logueados
- **`redis.conf`** — `lazyfree-lazy-user-del/flush yes`: `DEL` y `FLUSHDB` asíncronos (no bloquean el event loop)
- **`php.ini`** — `jit_buffer_size` reducido 128M → 64M (ahorro de 64MB RAM en ARM64)

### 🔒 Seguridad y estabilidad
- **`php.ini`** — `proc_open` eliminado de `disable_functions` (rompía Composer, WP-CLI y Deployer)
- **`hosting.cnf`** — `binlog_checksum = NONE`: elimina CRC32 por evento en servidor sin replicación
- **`docker-compose.yml`** — `start_period: 15s` en healthcheck de Nginx (evita falsos *unhealthy* al arrancar)

---

## 📋 Changelog v22

### Bugs funcionales corregidos
- **`health-check.sh`** — Modo `--json` ahora retorna exit code correcto (`1` cuando hay errores). Antes siempre salía `0` aunque hubiera contenedores caídos, rompiendo cualquier integración CI/CD o cron que dependiera del código de salida.
- **`install.sh` `load_env()`** — Reemplazos de placeholders en archivos de configuración ahora usan variables de entorno en Python (`os.environ`) en lugar de interpolación de shell con triple-comilla (`'''${VAR}'''`). El método anterior fallaba silenciosamente si la contraseña generada contenía comillas simples.
- **`install.sh` `configure_firewall()`** — Añadidas reglas `ip6tables` para IPv6 (SSH 22, HTTP 80, HTTPS 443, DNS 53, SFTPGo 2022). Oracle Cloud puede asignar IPv6 y sin estas reglas el tráfico IPv6 quedaba bloqueado.

### Referencias de versión corregidas (v20 → v22)
- **`install.sh`** — Cabecera, `main()`, `setup_cron()`, `print_summary()`: todos apuntaban a v20 en el archivo v21.
- **`scripts/monitor.sh`** — Cabecera del script corregida de v20 a v22.
- **`scripts/status.sh`** — Banner del diagnóstico corregido de v20 a v22.
- **`scripts/diagnose.sh`** — Banner de salida corregido de v20 a v22.
- **`README.md`** — Comando de instalación rápida corregido al nombre de archivo v22.

### Mejoras adicionales
- **`install.sh` `print_summary()`** — Añadidos URL de SFTPGo Admin (`https://sftp.DOMINIO`) y dirección SFTP (`sftp -P 2022`) en la tabla de accesos post-instalación.
- **`README.md`** — Añadida sección Changelog v21 (faltaba por completo).

---

## 📋 Changelog v21

### Correcciones principales
- **`scripts/oracle-firewall.sh`** — Script separado para configurar iptables en Oracle Cloud (puerto 2022 SFTPGo incluido).
- **`scripts/backup-verify.sh`** — Verificación de integridad de backups con checksums.
- **`scripts/ssl-check.sh`** — Verificación semanal automática de certificados SSL.
- **`docker-compose.yml`** — Actualización de versiones de imágenes: Nginx 1.27, MariaDB 11.4, Redis 7.4.
- **`scripts/monitor.sh`** — Alertas Telegram/webhook + detección OOM killer + monitoreo de inodos y RAM.
- **`scripts/health-check.sh`** — Nuevo script ligero para CI/CD con soporte `--json`.
- **`install.sh`** — Verificaciones preflight (disco, RAM, puertos), swap automático de 2GB, IPv6 en sysctl.
- **`fail2ban/`** — Filtros personalizados para Nginx (exploit, forbidden, rate-limit), SFTPGo y Traefik auth.

---

## 📋 Changelog v20

### Bug Fixes
- **`README.md`** — Versión seguía marcada como v17 en título y en el comando de instalación
- **`nginx/sites-available/template.conf`** — FastCGI cache cacheaba respuestas POST (formularios, login, checkout se corrompían). Fix: variable `$skip_cache_post` via `map` en nginx.conf
- **`scripts/add-vhost.sh`** — Mismo bug en el vhost WordPress generado (POST bypass faltante)
- **`nginx/nginx.conf`** — Añadido bloque `map` para `$skip_cache_post` (necesario para el fix del cache POST)
- **`docker-compose.yml`** — Cabecera de comentario actualizada de v19 → v20

### Mejoras
- **`php/www.conf`** — Añadido `clear_env = no` para que env vars del contenedor sean accesibles vía `getenv()` en PHP (no solo las listadas en `env[]`)
- **`nginx/snippets/wordpress.conf`** — Nuevo archivo con reglas de seguridad WordPress reutilizables (`include` desde vhosts)
- **`nginx/snippets/security.conf`** — Nuevo archivo con reglas de seguridad general reutilizables
- **`nginx/sites-available/template.conf`** — Añadidos `$http_authorization` y `$cookie_PHPSESSID` al bypass del FastCGI cache
- **`install.sh`** — Banner de finalización actualizado a v20
- **`Makefile`** — Sección de diagnóstico actualizada a v20

## 📋 Changelog v17

### 🔴 Bugfixes críticos

- **`scripts/monitor.sh`** — **`fi` huérfano** dentro de `send_alert()` causaba syntax error en bash → el monitor de cron **nunca se ejecutaba** en v16. Eliminado el `fi` duplicado.
- **`traefik/traefik.yml`** — Bloque `tls: options: default:` a nivel raíz es **inválido en Traefik v3** static config (solo válido en dynamic config). Generaba warnings en `traefik.log` y las opciones eran ignoradas. Eliminado del static config; la configuración correcta ya estaba en `traefik/dynamic/middlewares.yml`.
- **`scripts/restore.sh`** — **Asimetría backup/restore**: `backup.sh` v16 respalda los volúmenes `sftpgo-data` y `portainer-data`, pero `restore.sh` no los restauraba. Añadida restauración automática de ambos volúmenes si existen en el backup.

### 🟡 Correcciones menores

- **`scripts/diagnose.sh`** — Banner mostraba "v15" → corregido a "v17"
- **`.env.example`** — Cabecera decía "v15" → corregida a "v17"
- **`scripts/status.sh`** — Banner mostraba "v6" → corregido a "v17"
- **`.gitignore`** — Añadido `.env.restored` (archivo generado por `restore.sh --config` que no debe subirse al repo)
- **`php/Dockerfile`** — Eliminado bloque `RUN echo opcache.*` redundante. Los archivos `conf.d/` se cargan **después** de `php.ini` y sobreescriben sus valores — tener los mismos settings en ambos lados era confuso y sin efecto útil. `php.ini` contiene todos los settings necesarios, incluido JIT.

### ✨ Nuevos comandos `make`

| Comando | Descripción |
|---------|-------------|
| `make build` | Reconstruye imagen `php-fpm` aplicando cambios en Dockerfile/php.ini |
| `make wp-cache-flush` | Vacía caché WP-CLI + Redis + Nginx FastCGI para todos los sitios |
| `make redis-flush` | `FLUSHALL` en Redis (limpieza total) |
| `make logs-size` | Muestra tamaño de log de cada contenedor Docker |
| `make disk-full` | Limpieza agresiva: `docker system prune -af --volumes` + build cache + logs >50MB |

### 🔍 Monitoreo mejorado

- **`scripts/monitor.sh`** — Detección de **OOM Killer**: alerta vía Telegram/webhook cuando el kernel mata procesos por falta de RAM, incluyendo nombre del proceso víctima
