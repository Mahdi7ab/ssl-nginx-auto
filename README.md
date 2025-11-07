# Let's Encrypt SSL Auto-Setup for Dockerized Nginx  
**Production-Ready | Dynamic Proxy | Multi-Domain | Auto-Renew**

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)  
![Bash](https://img.shields.io/badge/bash-%3E%3D4.0-green)  
![Docker](https://img.shields.io/badge/docker-%3E%3D20.10-blue)

---

## Overview

این پروژه یک اسکریپت **کاملاً خودکار و حرفه‌ای** برای:

- صدور گواهی SSL از **Let's Encrypt**  
- تنظیم **Nginx داکری** با HTTPS  
- پشتیبانی از **چند دامنه در یک گواهی**  
- مدیریت **نام‌های `-0001`, `-0002`**  
- **پروکسی تارگت داینامیک**  
- **تمدید خودکار با cron**  
- **بکاپ و تست**

> بدون نیاز به اجرای دوباره بعد از ریبوت  
> بدون downtime (فقط `nginx -s reload`)  
> کاملاً قابل استفاده در **تولید**

---

## Features

| ویژگی | وضعیت |
|------|-------|
| چند دامنه در یک گواهی | Supported |
| `hamiransteel.com-0001` و ... | Supported (آخرین گواهی پیدا میشه) |
| `proxy_pass` داینامیک | Supported |
| بدون downtime | Supported (`reload`) |
| بکاپ خودکار | Supported |
| تست HTTPS | Supported |
| Cron تمدید خودکار | Supported |
| DNS propagation check | Supported |
| Retry در صورت خطا | Supported |
| Staging / Production | Supported |

---

## Requirements

- Docker + Docker Compose
- Nginx داخل داکر با نام سرویس: `infra-nginx`
- دسترسی به پورت 80 و 443
- DNS دامنه به IP سرور اشاره کند

---

## Directory Structure

```bash
/srv/infra/
├── nginx/
│   ├── conf.d/          # ← فایل‌های کانفیگ Nginx (volume)
│   └── ssl/             # ← گواهی‌های Let's Encrypt (volume)
├── certbot/
│   └── www/             # ← چالش ACME (volume)
└── backup/
    └── ssl/             # ← بکاپ‌های خودکار
```

---

## Usage

### 1. دانلود و آماده‌سازی

```bash
git clone https://github.com/Mahdi7ab/ssl-nginx-auto.git
cd ssl-nginx-auto
chmod +x setup-ssl.sh
```

### 2. اجرای مستقیم

```bash
./setup-ssl.sh mahdi7ab@gmail.com hamiransteel.com www.hamiransteel.com hamiransteel-app:3000
```

### 3. اجرای با فایل

#### `domains.txt`

```txt
mahdi7ab@gmail.com hamiransteel.com www.hamiransteel.com hamiransteel-app:3000
admin@site2.com api.site2.ir site2-backend:8080
blog@example.com blog.example.com blog-node:4000
```

```bash
./setup-ssl.sh -f domains.txt
```

---

## Docker Compose Example

```yaml
version: '3.8'

services:
  infra-nginx:
    image: nginx:alpine
    container_name: infra-nginx
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /srv/infra/nginx/conf.d:/etc/nginx/conf.d
      - /srv/infra/nginx/ssl:/etc/letsencrypt
      - /srv/infra/certbot/www:/var/www/certbot
    restart: unless-stopped
    depends_on:
      - hamiransteel-app
      - site2-backend

  hamiransteel-app:
    image: node:18
    # ...
```

---

## Cron Auto-Renew (نصب خودکار)

اسکریپت خودش این فایل رو می‌سازه:

```bash
/etc/cron.d/certbot-renew
```

```cron
15 3 * * * root \
  docker run --rm \
    -v "/srv/infra/certbot/www:/var/www/certbot" \
    -v "/srv/infra/nginx/ssl:/etc/letsencrypt" \
    certbot/certbot renew --quiet && \
  docker exec infra-nginx nginx -s reload
```

---

## Production Tips

1. **حذف `--staging`** از `issue_cert()` در اسکریپت
2. **بکاپ دوره‌ای**:
   ```bash
   tar -czf /backup/ssl_$(date +%F).tar.gz /srv/infra/nginx/ssl
   ```
3. **Firewall**:
   ```bash
   ufw allow 80,443/tcp
   ```

---

## Testing

### تست تمدید (خشک)

```bash
docker run --rm \
  -v "/srv/infra/nginx/ssl:/etc/letsencrypt" \
  certbot/certbot renew --dry-run
```

### تست HTTPS

```bash
curl -I https://hamiransteel.com
```

---

## Troubleshooting

| مشکل | راه‌حل |
|------|--------|
| `No such file` در Nginx | `nginx -s reload` بزنید |
| گواهی `-0001` ساخته شد | اسکریپت خودش آخرین رو پیدا می‌کنه |
| DNS resolve نمیشه | صبر کنید یا `--staging` بزنید |
| Cron کار نمی‌کنه | `crontab -l` و `docker ps` چک کنید |

---

## Contributing

1. Fork کنید
2. Branch بسازید: `git checkout -b feature/amazing`
3. Commit کنید: `git commit -m "Add amazing feature"`
4. Push کنید: `git push origin feature/amazing`
5. Pull Request باز کنید

---

## License

```
MIT License
```

---

## Author

**Mahdi** — DevOps Engineer  
[mahdi7ab@gmail.com](mailto:mahdi7ab@gmail.com)

---

> **"SSL رو فراموش نکن — امنیت رو خودکار کن!"**

---

**Star این ریپو اگر برات مفید بود!**  
[https://github.com/yourname/ssl-nginx-auto](https://github.com/yourname/ssl-nginx-auto)

---

## فایل‌های پروژه

```
.
├── setup-ssl.sh
├── domains.txt.example
├── docker-compose.yml
├── README.md
└── LICENSE
```

---

اگر خواستی، این ریپو رو توی GitHub برات بسازم و لینک بدم. فقط بگو!
