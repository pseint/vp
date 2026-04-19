FROM php:8.3-fpm-alpine

ARG PHP_VERSION=8.3
ARG XDEBUG=0

# 1. Instalar dependencias del sistema (Añadido linux-headers)
RUN apk add --no-cache \
    bash curl wget git unzip fcgi shadow \
    freetype-dev libjpeg-turbo-dev libpng-dev libwebp-dev \
    libzip-dev oniguruma-dev libxml2-dev icu-dev \
    pcre-dev openssl-dev libsodium-dev imagemagick-dev imagemagick \
    linux-headers \
    g++ make autoconf

# 2. Configurar e instalar extensiones core de PHP
RUN docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
  && docker-php-ext-install -j$(nproc) \
       gd pdo pdo_mysql mysqli mbstring xml dom simplexml \
       zip intl exif bcmath opcache pcntl sockets sodium

# 3. Instalar extensiones PECL (Redis, Imagick)
RUN pecl install redis imagick \
  && docker-php-ext-enable redis imagick

# 4. Condicional para Xdebug (Ahora funcionará porque g++ y make siguen presentes)
RUN if [ "$XDEBUG" = "1" ]; then \
       pecl install xdebug && \
       docker-php-ext-enable xdebug && \
       echo "xdebug.mode=debug" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini && \
       echo "xdebug.client_host=host.docker.internal" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini; \
     fi

# 5. Instalar Composer y WP-CLI
RUN curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \
  && curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp \
  && chmod +x /usr/local/bin/wp

# 6. LIMPIEZA FINAL: Eliminar herramientas de compilación y temporales
RUN apk del g++ make autoconf \
  && rm -rf /tmp/* /var/cache/apk/*

# Configuración de usuario y directorios
RUN usermod -u 1000 www-data 2>/dev/null || true \
 && groupmod -g 1000 www-data 2>/dev/null || true \
 && mkdir -p /tmp/php-uploads && chown www-data:www-data /tmp/php-uploads

WORKDIR /var/www/html
EXPOSE 9000

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD SCRIPT_NAME=/fpm-ping SCRIPT_FILENAME=/fpm-ping REQUEST_METHOD=GET \
      cgi-fcgi -bind -connect 127.0.0.1:9000 2>/dev/null | grep -q "pong" || exit 1

CMD ["php-fpm", "--nodaemonize"]
