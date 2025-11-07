#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ $# -lt 3 ]; then
  echo -e "${RED}[✗] استفاده: $0 email domain1 [domain2...] container:port${NC}"
  echo "مثال: $0 mahdi7ab@gmail.com api.tavadentco.ir tavadentco_api:80"
  exit 1
fi

EMAIL="$1"
shift
PROXY_TARGET="${!#}"
DOMAINS="${@:1:$#-1}"

if [ -z "$DOMAINS" ]; then
  echo -e "${RED}[✗] حداقل یک دامنه لازم است${NC}"
  exit 1
fi

if [[ ! "$PROXY_TARGET" =~ .*:.* ]]; then
  echo -e "${RED}[✗] Proxy target باید container:port باشه${NC}"
  exit 1
fi

DOMAINS_LIST=$(echo "$DOMAINS" | tr ' ' ',')
MAIN_DOMAIN=$(echo "$DOMAINS" | awk '{print $1}')

echo -e "${YELLOW}[+] ایمیل:${NC} $EMAIL"
echo -e "${YELLOW}[+] دامنه(ها):${NC} $DOMAINS_LIST"
echo -e "${YELLOW}[+] Proxy Target:${NC} $PROXY_TARGET"

# مسیرهای داخل کانتینر
NGINX_CONTAINER="infra-nginx"
WEBROOT="/var/www/certbot"
SSL_DIR="/etc/letsencrypt"
CONFIG_DIR="/etc/nginx/conf.d"

# چک کردن وجود کانتینر
if ! docker ps | grep -q "$NGINX_CONTAINER"; then
  echo -e "${RED}[✗] کانتینر $NGINX_CONTAINER اجرا نیست!${NC}"
  exit 1
fi

# ساخت وب‌روت
docker exec "$NGINX_CONTAINER" mkdir -p "$WEBROOT"

# موقت: کانفیگ چالش
TEMP_CONFIG="$CONFIG_DIR/letsencrypt-challenge.conf"
docker exec "$NGINX_CONTAINER" sh -c "cat > $TEMP_CONFIG" <<EOF
server {
    listen 80;
    server_name $(echo "$DOMAINS_LIST" | sed 's/,/ /g');

    location /.well-known/acme-challenge/ {
        root $WEBROOT;
        try_files \$uri =404;
    }

    location / {
        return 410;
    }
}
EOF

docker exec "$NGINX_CONTAINER" nginx -t && docker exec "$NGINX_CONTAINER" nginx -s reload

# اجرای Certbot داخل Docker
echo -e "${YELLOW}[+] در حال دریافت گواهی...${NC}"
docker run --rm \
  -v "$(pwd)/ssl:$SSL_DIR" \
  -v "$(pwd)/../certbot/www:$WEBROOT" \
  --network web \
  certbot/certbot \
  certonly --webroot -w "$WEBROOT" \
  -d $(echo "$DOMAINS_LIST" | sed 's/,/ -d /g') \
  --email "$EMAIL" --agree-tos --no-eff-email || {
    echo -e "${RED}[✗] خطا در دریافت گواهی${NC}"
    docker exec "$NGINX_CONTAINER" rm -f "$TEMP_CONFIG"
    docker exec "$NGINX_CONTAINER" nginx -s reload
    exit 1
}

# حذف کانفیگ موقت
docker exec "$NGINX_CONTAINER" rm -f "$TEMP_CONFIG"
docker exec "$NGINX_CONTAINER" nginx -s reload

# ساخت کانفیگ اصلی
CONFIG_FILE="$CONFIG_DIR/${MAIN_DOMAIN//./_}.conf"
SERVER_NAMES=$(echo "$DOMAINS" | sed 's/^/    server_name /; s/ /;\n    server_name /g' | sed 's/$/;/')

docker exec "$NGINX_CONTAINER" sh -c "cat > $CONFIG_FILE" <<EOF
upstream backend {
    server $PROXY_TARGET;
}

server {
    listen 80;
    server_name $(echo "$DOMAINS_LIST" | sed 's/,/ /g');
    location /.well-known/acme-challenge/ { root $WEBROOT; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
$SERVER_NAMES
    ssl_certificate $SSL_DIR/live/$MAIN_DOMAIN/fullchain.pem;
    ssl_certificate_key $SSL_DIR/live/$MAIN_DOMAIN/privkey.pem;

    location /.well-known/acme-challenge/ { root $WEBROOT; }
    location / {
        proxy_pass http://backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# ری‌لود نهایی
if docker exec "$NGINX_CONTAINER" nginx -t && docker exec "$NGINX_CONTAINER" nginx -s reload; then
    echo -e "${GREEN}[✓] SSL با موفقیت تنظیم شد: $DOMAINS_LIST${NC}"
    echo -e "${GREEN}[✓] کانفیگ: ./conf.d/$(basename $CONFIG_FILE)${NC}"
else
    echo -e "${RED}[✗] خطا در Nginx${NC}"
    exit 1
fi
