#!/bin/bash
set -euo pipefail

###########################################
# Nextcloud + Nginx + PHP-FPM + MariaDB
# Ubuntu 24.04 (Oracle VM)
###########################################

# --- CONFIG (editează DOAR astea două!) ---
DOMAIN="exemplu.ateliermozaic.go.ro"   # <- domeniul tău
EMAIL="contact@exemplu.ro"             # <- email pt Let's Encrypt
# ------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "Te rog rulează scriptul ca root (sudo)."
  exit 1
fi

echo "=== Instalare Nextcloud pe Ubuntu 24.04 (Nginx) pentru domeniul: $DOMAIN ==="

# Funcție mică pentru random string
rand_str() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"
}

# Credenziale random
DB_NAME="nextcloud"
DB_USER="ncdb_$(rand_str 6)"
DB_PASS="$(rand_str 16)"

NC_ADMIN_USER="ncadmin_$(rand_str 4)"
NC_ADMIN_PASS="$(rand_str 12)"

echo ">> Utilizator DB:  $DB_USER (parola va fi afișată la final)"
echo ">> Utilizator admin Nextcloud: $NC_ADMIN_USER (parola va fi afișată la final)"
sleep 3

###########################################
# 1. Update & pachete
###########################################
echo ">> Update sistem și instalare pachete..."
apt-get update -y
apt-get upgrade -y

apt-get install -y \
  nginx \
  mariadb-server \
  redis-server \
  php-fpm php-mysql php-gd php-curl php-xml php-mbstring php-zip php-intl php-bcmath php-gmp php-imagick \
  php-apcu php-redis \
  unzip wget certbot python3-certbot-nginx

###########################################
# 2. Configurare MariaDB
###########################################
echo ">> Configurez MariaDB..."
systemctl enable --now mariadb

mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

###########################################
# 3. Descărcare și instalare Nextcloud
###########################################
echo ">> Descarc Nextcloud..."
cd /tmp
wget -q https://download.nextcloud.com/server/releases/latest.zip -O nextcloud.zip
unzip -q nextcloud.zip
mv nextcloud /var/www/nextcloud

# Director data în afara rădăcinii web
mkdir -p /var/nextcloud-data
chown -R www-data:www-data /var/www/nextcloud /var/nextcloud-data
find /var/www/nextcloud/ -type f -print0 | xargs -0 chmod 640
find /var/www/nextcloud/ -type d -print0 | xargs -0 chmod 750

###########################################
# 4. Configurare PHP-FPM
###########################################
echo ">> Configurez PHP-FPM pentru Nextcloud..."
PHPVER=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")

cat > /etc/php/$PHPVER/fpm/conf.d/90-nextcloud.ini <<EOF
memory_limit = 512M
upload_max_filesize = 2048M
post_max_size = 2050M
max_execution_time = 360
output_buffering = 0

opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.save_comments=1
opcache.revalidate_freq=1

apc.enable_cli=1
apc.shm_size=128M
EOF

systemctl reload php$PHPVER-fpm

###########################################
# 5. Configurare Nginx (HTTP inițial)
###########################################
echo ">> Configurez Nginx pentru Nextcloud (HTTP inițial)..."

rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/nextcloud <<'EOF'
upstream php-handler {
    server unix:/run/php/php-fpm.sock;
}

server {
    listen 80;
    listen [::]:80;
    server_name DOMAIN_PLACEHOLDER;

    root /var/www/nextcloud;
    index index.php index.html /index.php$request_uri;

    client_max_body_size 2048M;
    fastcgi_buffers 64 4K;

    add_header Referrer-Policy "no-referrer" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Robots-Tag "none" always;
    add_header X-Download-Options "noopen" always;
    add_header X-Permitted-Cross-Domain-Policies "none" always;

    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }

    location = /.well-known/carddav { return 301 /remote.php/dav/; }
    location = /.well-known/caldav  { return 301 /remote.php/dav/; }

    location ^~ /.well-known {
        location = /.well-known/carddav { return 301 /remote.php/dav/; }
        location = /.well-known/caldav  { return 301 /remote.php/dav/; }
        try_files $uri $uri/ =404;
    }

    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)/ {
        deny all;
    }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console) {
        deny all;
    }

    location / {
        rewrite ^ /index.php$request_uri;
    }

    location ~ \.php(?:$|/) {
        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        set $path_info $fastcgi_path_info;

        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $path_info;

        fastcgi_param HTTPS off;

        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;
    }

    location ~ \.(?:css|js|woff2?|svg|gif|map)$ {
        try_files $uri /index.php$request_uri;
        access_log off;
        expires 1y;
    }

    location ~ \.(?:png|html|ttf|ico|jpg|jpeg)$ {
        try_files $uri /index.php$request_uri;
        access_log off;
        expires 1M;
    }
}
EOF

# Înlocuiește placeholder-ul cu domeniul real și sock PHP corect
sed -i "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" /etc/nginx/sites-available/nextcloud
sed -i "s#/run/php/php-fpm.sock#/run/php/php$PHPVER-fpm.sock#g" /etc/nginx/sites-available/nextcloud

ln -sf /etc/nginx/sites-available/nextcloud /etc/nginx/sites-enabled/nextcloud
nginx -t
systemctl restart nginx

###########################################
# 6. Certificat SSL Let's Encrypt (Nginx)
###########################################
echo ">> Obțin certificat Let's Encrypt pentru $DOMAIN..."
certbot --nginx --non-interactive --agree-tos --email "$EMAIL" -d "$DOMAIN" --redirect --hsts --staple-ocsp

###########################################
# 7. Instalare Nextcloud prin occ
###########################################
echo ">> Instalez Nextcloud (occ, non-interactiv)..."

sudo -u www-data php /var/www/nextcloud/occ maintenance:install \
  --database "mysql" \
  --database-name "$DB_NAME" \
  --database-user "$DB_USER" \
  --database-pass "$DB_PASS" \
  --admin-user "$NC_ADMIN_USER" \
  --admin-pass "$NC_ADMIN_PASS" \
  --data-dir "/var/nextcloud-data"

###########################################
# 8. Config memcache APCu + Redis
###########################################
echo ">> Activez memcache APCu + Redis în config.php..."
CONFIG_FILE="/var/www/nextcloud/config/config.php"

# Scoatem ultima linie ');'
sed -i '$d' "$CONFIG_FILE"

cat >> "$CONFIG_FILE" <<EOF
  'memcache.local' => '\\OC\\Memcache\\APCu',
  'memcache.locking' => '\\OC\\Memcache\\Redis',
  'redis' => [
    'host' => '127.0.0.1',
    'port' => 6379,
    'timeout' => 1.5,
  ],
);
EOF

chown www-data:www-data "$CONFIG_FILE"

###########################################
# 9. Swap egal cu RAM
###########################################
echo ">> Creez swap egal cu RAM..."
MEM_MB=$(free -m | awk '/Mem:/ {print $2}')
if ! grep -q '/swapfile ' /etc/fstab; then
  fallocate -l ${MEM_MB}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$MEM_MB
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

###########################################
# 10. Final
###########################################
echo "=================================================="
echo "INSTALARE NEXTCLOUD TERMINATĂ!"
echo "URL:     https://$DOMAIN"
echo
echo "Utilizator admin Nextcloud: $NC_ADMIN_USER"
echo "Parolă admin Nextcloud:     $NC_ADMIN_PASS"
echo
echo "Utilizator MariaDB:         $DB_USER"
echo "Parolă MariaDB:             $DB_PASS"
echo "Bază de date:               $DB_NAME"
echo "=================================================="
