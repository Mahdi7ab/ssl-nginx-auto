#!/usr/bin/env bash
# ==============================================================
#  Production-Ready Let's Encrypt SSL + Dynamic Proxy Target
#  Usage:
#     ./setup-ssl.sh <email> <domain1> [domain2 ...] <proxy_target>
#     ./setup-ssl.sh -f domains.txt
#  File format:
#     email domain1 domain2 ... proxy_target
# ==============================================================

set -euo pipefail

# --------------------- Config ---------------------
HOST_CONF_DIR="/srv/infra/nginx/conf.d"
CERTBOT_WWW="/srv/infra/certbot/www"
LETSENCRYPT_VOL="/srv/infra/nginx/ssl"
BACKUP_DIR="/srv/infra/backup/ssl"
CERTBOT_IMAGE="certbot/certbot:latest"
NGINX_SERVICE="infra-nginx"
DNS_TIMEOUT=300
RETRY_COUNT=3

# --------------------- Colors ---------------------
RED='\e[31m'; GREEN='\e[32m'; YELLOW='\e[33m'; BLUE='\e[34m'; NC='\e[0m'
log()   { echo -e "${GREEN}[+] $1${NC}"; }
warn()  { echo -e "${YELLOW}[!] $1${NC}"; }
err()   { echo -e "${RED}[✗] $1${NC}" >&2; }
die()   { err "$1"; exit 1; }

# --------------------- Helpers ---------------------
check_nginx() {
    docker ps --format "table {{.Names}}" | grep -q "^${NGINX_SERVICE}\$" || die "Nginx container not running"
}

nginx_reload() {
    log "Reloading Nginx..."
    docker exec "$NGINX_SERVICE" nginx -s reload > /dev/null 2>&1 || {
        warn "Reload failed → restarting container"
        docker restart "$NGINX_SERVICE" > /dev/null
        sleep 3
    }
}

backup_file() {
    local file=$1
    [[ -f "$file" ]] || return 0
    local b="$BACKUP_DIR/$(basename "$file").$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp "$file" "$b"
    log "Backup: $file → $b"
}

wait_for_dns() {
    local domain=$1
    local t=0
    log "Waiting for DNS: $domain (max ${DNS_TIMEOUT}s)"
    while (( t < DNS_TIMEOUT )); do
        if host "$domain" >/dev/null 2>&1; then
            log "DNS OK: $domain"
            return 0
        fi
        sleep 5
        ((t += 5))
    done
    warn "DNS timeout: $domain"
}

find_latest_cert() {
    local domain=$1
    local latest=$(ls -d "$LETSENCRYPT_VOL/live/${domain}"* 2>/dev/null | sort -V | tail -n1)
    [[ -n "$latest" ]] || return 1
    basename "$latest"
}

create_http01_conf() {
    local domain=$1 file=$2
    cat > "$file" <<EOF
server {
    listen 80;
    server_name $domain;
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files \$uri =404;
    }
    location / { return 301 https://$domain\$request_uri; }
}
EOF
    log "Challenge config: $file"
}

create_https_conf() {
    local domain=$1 file=$2 target=$3 cert=$4
    cat > "$file" <<EOF
# HTTP → HTTPS
server {
    listen 80;
    server_name $domain;
    return 301 https://\$host\$request_uri;
}

# HTTPS
server {
    listen 443 ssl http2;
    server_name $domain;

    ssl_certificate     /etc/letsencrypt/live/$cert/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$cert/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    location / {
        proxy_pass http://$target;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
    log "HTTPS config: $file → proxy_pass http://$target"
}

issue_cert() {
    local email=$1; shift; local domains=( "$@" )
    local d_opt=""
    for d in "${domains[@]}"; do d_opt+=" -d $d"; done

    log "Issuing cert for: ${domains[*]}"
    for ((i=1; i<=RETRY_COUNT; i++)); do
        if docker run --rm \
            --dns=8.8.8.8 \
            -v "$CERTBOT_WWW:/var/www/certbot" \
            -v "$LETSENCRYPT_VOL:/etc/letsencrypt" \
            "$CERTBOT_IMAGE" certonly \
            --webroot --webroot-path=/var/www/certbot \
            $d_opt \
            --email "$email" --agree-tos --no-eff-email \
            --non-interactive --keep-until-expiring; then
            return 0
        fi
        warn "Attempt $i failed. Retrying..."
        sleep 10
    done
    die "Cert issuance failed"
}

test_https() {
    local domain=$1
    log "Testing HTTPS: $domain"
    sleep 3
    if curl -fIsS --max-time 10 "https://$domain" >/dev/null 2>&1; then
        log "HTTPS OK"
    else
        warn "HTTPS failed"
    fi
}

install_cron() {
    local f="/etc/cron.d/certbot-renew"
    cat > "$f" <<EOF
15 3 * * * root \
  docker run --rm \
    -v "$CERTBOT_WWW:/var/www/certbot" \
    -v "$LETSENCRYPT_VOL:/etc/letsencrypt" \
    $CERTBOT_IMAGE renew --quiet && \
  docker exec $NGINX_SERVICE nginx -s reload >/dev/null 2>&1 || \
  docker restart $NGINX_SERVICE
EOF
    chmod 644 "$f"
    log "Cron installed: $f"
}

# --------------------- Process Group ---------------------
process_group() {
    local email=$1; shift
    local domains=()
    local proxy_target=""

    # آخرین آرگومان = proxy_target
    while (( $# > 0 )); do
        if [[ $1 =~ ^[a-zA-Z0-9.-]+:[0-9]+$ ]]; then
            proxy_target="$1"
            shift
            break
        else
            domains+=("$1")
            shift
        fi
    done

    [[ ${#domains[@]} -gt 0 ]] || die "No domains provided"
    [[ -n "$proxy_target" ]] || die "Proxy target missing (e.g. app:3000)"

    local primary="${domains[0]}"
    local conf_file="$HOST_CONF_DIR/${primary}.conf"

    backup_file "$conf_file"
    wait_for_dns "$primary" || true
    create_http01_conf "$primary" "$conf_file"
    nginx_reload

    issue_cert "$email" "${domains[@]}"

    local cert_name=$(find_latest_cert "$primary") || die "Cert not found"
    log "Using cert: $cert_name"

    create_https_conf "$primary" "$conf_file" "$proxy_target" "$cert_name"
    nginx_reload
    test_https "$primary"
}

# --------------------- Main ---------------------
main() {
    check_nginx
    mkdir -p "$CERTBOT_WWW" "$LETSENCRYPT_VOL" "$BACKUP_DIR"

    if [[ $1 == "-f" ]]; then
        [[ -f $2 ]] || die "File not found: $2"
        while IFS= read -r line || [[ -n $line ]]; do
            line=$(echo "$line" | xargs | sed 's/#.*//')
            [[ -z "$line" ]] && continue
            read -ra parts <<< "$line"
            local email="${parts[0]}"
            local proxy_target=""
            local domains=()

            # آخرین مقدار = proxy_target
            for ((i=${#parts[@]}-1; i>=1; i--)); do
                if [[ ${parts[i]} =~ ^[a-zA-Z0-9.-]+:[0-9]+$ ]]; then
                    proxy_target="${parts[i]}"
                    break
                fi
            done

            # جمع‌آوری دامنه‌ها
            for ((i=1; i<${#parts[@]}; i++)); do
                if [[ ${parts[i]} != "$proxy_target" ]]; then
                    domains+=("${parts[i]}")
                fi
            done

            process_group "$email" "${domains[@]}" "$proxy_target"
        done < "$2"
    else
        process_group "$@"
    fi

    install_cron
    log "SSL + Dynamic Proxy Setup Complete!"
}

# --------------------- Run ---------------------
if [[ $# -lt 3 ]]; then
    cat <<EOF
Usage:
  $0 <email> <domain1> [domain2 ...] <proxy_target>
  $0 -f <file.txt>

File example (domains.txt):
  mahdi7ab@gmail.com hamiransteel.com www.hamiransteel.com hamiransteel-app:3000
  admin@site2.com api.site2.ir site2-backend:8080
EOF
    exit 1
fi

main "$@"
