#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ $# -lt 3 ]; then
  echo -e "${RED}[x] استفاده: $0 email domain1 [domain2 ...] container:port${NC}"
  exit 1
fi

EMAIL="$1"
shift
PROXY_TARGET="${!#}"
DOMAINS="${@:1:$#-1}"
DOMAINS_LIST=$(echo "$DOMAINS" | tr ' ' ',')
MAIN_DOMAIN=$(echo "$DOMAINS" | awk '{print $1}')
WEBROOT="/srv/infra/certbot/www"
TEMP_CONFIG="/srv/infra/nginx/conf.d/letsencrypt-challenge.conf"
FINAL_CONFIG="/srv/infra/nginx/conf.d/${MAIN_DOMAIN//./_}.conf"

echo -e "${YELLOW}[+] دامنه(ها): $DOMAINS_LIST${NC}"
echo -e "${YELLOW}[+] Proxy: $PROXY_TARGET${NC}"

# 1. config موقت
cat > "$TEMP_CONFIG" << EOF
server {
    listen 80;
    server_name $(echo "$DOMAINS_LIST" | sed 's/,/ /g');

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files \$uri =404;
    }

    location / { return 502; }
}
EOF

docker exec infra-nginx nginx -t && docker exec infra-nginx nginx -s reload

# 2. دریافت گواهی
docker exec infra-certbot certbot certonly \
  --webroot -w /var/www/certbot \
  -d $(echo "$DOMAINS_LIST" | sed 's/,/ -d /g') \
  --email "$EMAIL" --agree-tos --non-interactive --force-renewal || {
    echo -e "${RED}[x] خطا در دریافت گواهی${NC}"
    rm -f "$TEMP_CONFIG"
    docker exec infra-nginx nginx -s reload 2>/dev/null || true
    exit 1
}

# 3. حذف config موقت
rm -f "$TEMP_CONFIG"

UPSTREAM_NAME="${MAIN_DOMAIN//./_}"

cat > "$FINAL_CONFIG" << EOF
upstream $UPSTREAM_NAME { server $PROXY_TARGET; }

server {
    listen 80;
    server_name $(echo "$DOMAINS_LIST" | sed 's/,/ /g');
    location /.well-known/acme-challenge/ { root /var/www/certbot; try_files \$uri =404; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name $(echo "$DOMAINS_LIST" | sed 's/,/ /g');
    ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;

    location /.well-known/acme-challenge/ { root /var/www/certbot; try_files \$uri =404; }
    location / {
        proxy_pass http://$UPSTREAM_NAME;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
}
EOF

# 5. ری‌لود نهایی
if docker exec infra-nginx nginx -t && docker exec infra-nginx nginx -s reload; then
    echo -e "${GREEN}[Success] SSL تنظیم شد: https://$MAIN_DOMAIN${NC}"
else
    echo -e "${RED}[x] خطا در Nginx${NC}"
    exit 1
fi
