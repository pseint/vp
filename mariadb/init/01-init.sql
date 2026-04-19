-- =============================================================
-- INICIALIZACIÓN DE BASE DE DATOS
-- Archivo: /opt/hosting/mariadb/init/01-init.sql
-- NOTA: Docker Compose ya crea `powerdns` DB y usuario `pdns`
-- via MARIADB_DATABASE y MARIADB_USER. Este script crea lo demás.
-- =============================================================

-- ── Base de datos PowerDNS Admin (la de PowerDNS ya la crea Docker) ──
CREATE DATABASE IF NOT EXISTS `pdnsadmin` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- ── Aseguramos permisos del usuario pdns (Docker lo crea pero sin GRANT ALL) ──
GRANT ALL PRIVILEGES ON `powerdns`.* TO 'pdns'@'%';

-- ── Usuario PowerDNS Admin ────────────────────────────────────
CREATE USER IF NOT EXISTS 'pdnsadmin'@'%' IDENTIFIED BY 'dFTwnqMKvLybGDMG9Ia7NkhHdKm7ZOt5';
GRANT ALL PRIVILEGES ON `pdnsadmin`.* TO 'pdnsadmin'@'%';

-- ── Usuario general para sitios web ──────────────────────────
-- webuser se conecta a BDs individuales — create-db.sh usa root para crear BDs
-- FIX: NO dar GRANT CREATE ON *.* — permite crear/leer cualquier BD del sistema
-- Los permisos por BD se otorgan en create-db.sh: GRANT ALL ON site_db.* TO webuser
CREATE USER IF NOT EXISTS 'webuser'@'%' IDENTIFIED BY 'FINhgIFjhiT1QsjXZy7fceJUVIvkkV3c';

FLUSH PRIVILEGES;

-- ── Esquema PowerDNS (tablas del servidor DNS) ────────────────
USE `powerdns`;

CREATE TABLE IF NOT EXISTS domains (
  id                    INT AUTO_INCREMENT,
  name                  VARCHAR(255) NOT NULL,
  master                VARCHAR(128) DEFAULT NULL,
  last_check            INT DEFAULT NULL,
  type                  VARCHAR(8) NOT NULL,
  notified_serial       INT UNSIGNED DEFAULT NULL,
  account               VARCHAR(40) CHARACTER SET 'utf8' DEFAULT NULL,
  options               VARCHAR(65535) DEFAULT NULL,
  catalog               VARCHAR(255) DEFAULT NULL,
  PRIMARY KEY (id)
) Engine=InnoDB CHARACTER SET 'latin1';

CREATE UNIQUE INDEX name_index ON domains(name);

CREATE TABLE IF NOT EXISTS records (
  id                    BIGINT AUTO_INCREMENT,
  domain_id             INT DEFAULT NULL,
  name                  VARCHAR(255) DEFAULT NULL,
  type                  VARCHAR(10) DEFAULT NULL,
  content               VARCHAR(64000) DEFAULT NULL,
  ttl                   INT DEFAULT NULL,
  prio                  INT DEFAULT NULL,
  disabled              TINYINT(1) DEFAULT 0,
  ordername             VARCHAR(255) BINARY DEFAULT NULL,
  auth                  TINYINT(1) DEFAULT 1,
  PRIMARY KEY (id)
) Engine=InnoDB CHARACTER SET 'latin1';

CREATE INDEX nametype_index ON records(name,type);
CREATE INDEX domain_id ON records(domain_id);
CREATE INDEX ordername ON records (ordername);

CREATE TABLE IF NOT EXISTS supermasters (
  ip                    VARCHAR(64) NOT NULL,
  nameserver            VARCHAR(255) NOT NULL,
  account               VARCHAR(40) CHARACTER SET 'utf8' NOT NULL,
  PRIMARY KEY (ip, nameserver)
) Engine=InnoDB CHARACTER SET 'latin1';

CREATE TABLE IF NOT EXISTS comments (
  id                    INT AUTO_INCREMENT,
  domain_id             INT NOT NULL,
  name                  VARCHAR(255) NOT NULL,
  type                  VARCHAR(10) NOT NULL,
  modified_at           INT NOT NULL,
  account               VARCHAR(40) CHARACTER SET 'utf8' DEFAULT NULL,
  comment               TEXT CHARACTER SET 'utf8' NOT NULL,
  PRIMARY KEY (id)
) Engine=InnoDB CHARACTER SET 'latin1';

CREATE INDEX comments_name_type_idx ON comments (name, type);
CREATE INDEX comments_order_idx ON comments (domain_id, modified_at);

CREATE TABLE IF NOT EXISTS domainmetadata (
  id                    INT AUTO_INCREMENT,
  domain_id             INT NOT NULL,
  kind                  VARCHAR(32),
  content               TEXT,
  PRIMARY KEY (id)
) Engine=InnoDB CHARACTER SET 'latin1';

CREATE INDEX domainmetadata_idx ON domainmetadata (domain_id, kind);

CREATE TABLE IF NOT EXISTS cryptokeys (
  id                    INT AUTO_INCREMENT,
  domain_id             INT NOT NULL,
  flags                 INT NOT NULL,
  active                BOOL,
  published             BOOL DEFAULT 1,
  content               TEXT,
  PRIMARY KEY (id)
) Engine=InnoDB CHARACTER SET 'latin1';

CREATE INDEX domainidindex ON cryptokeys(domain_id);

CREATE TABLE IF NOT EXISTS tsigkeys (
  id                    INT AUTO_INCREMENT,
  name                  VARCHAR(255),
  algorithm             VARCHAR(50),
  secret                VARCHAR(255),
  PRIMARY KEY (id)
) Engine=InnoDB CHARACTER SET 'latin1';

CREATE UNIQUE INDEX namealgoindex ON tsigkeys(name, algorithm);
