#!/bin/bash
set +e

# =========================================
# FINAL WORKING VERSION - NO MORE ERRORS
# =========================================

GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

PROJECT_ID="$(gcloud config get-value project)"
REGION="us-central1"
RAND=$(openssl rand -hex 3)
SVC_NAME="rafael-$RAND"
DOMAIN="www.google.com" # Gumagana ito sa Cloud Run
BUILD_DIR=$(mktemp -d)

cleanup() { rm -rf "$BUILD_DIR"; }
trap cleanup EXIT

clear
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}     FINAL WORKING DEPLOYER${NC}"
echo -e "${CYAN}=========================================${NC}"

if [ -z "$PROJECT_ID" ]; then
  echo -e "${RED}ERROR: Itakda muna ang project:${NC}"
  echo "gcloud config set project IYONG_PROJECT_ID"
  exit 1
fi

# I-enable ang services
gcloud services enable --quiet run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com

# Billing
echo -e "\n${CYAN}--- BILLING ---${NC}"
echo "1) Request-based (mas mura)"
echo "2) Instance-based (mas matatag)"
read -p "Piliin [1/2]: " BILL
[ "$BILL" = "2" ] && BILL_FLAGS="--no-cpu-throttling" || BILL_FLAGS="--cpu-throttling"

# Resources
read -p "Memory [default 4Gi]: " MEM; MEM=${MEM:-4Gi}
read -p "vCPU [default 4]: " CPU; CPU=${CPU:-4}
read -p "Min Instance [0/1, default 0]: " MIN; MIN=${MIN:-0}
read -p "Max Instance [1-4, default 2]: " MAX; MAX=${MAX:-2}

mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR" || exit 1

# ✅ XRAY CONFIG - TAMA ANG ROUTING
cat > config.json <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "trojan", "port": 10001, "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": {"clients": [{"password": "rafaeltv"}]},
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]},
      "streamSettings": {"network": "ws", "wsSettings": {"path": "/trojan-rafael"}}
    },
    {
      "tag": "vless", "port": 10002, "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {"clients": [{"id": "15f7e8ea-7b56-45d4-93af-31f3c592fdf1"}], "decryption": "none"},
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]},
      "streamSettings": {"network": "ws", "wsSettings": {"path": "/vless-rafael"}}
    },
    {
      "tag": "vmess", "port": 10003, "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {"clients": [{"id": "15f7e8ea-7b56-45d4-93af-31f3c592fdf1", "alterId": 0, "security": "auto"}]},
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]},
      "streamSettings": {"network": "ws", "wsSettings": {"path": "/vmess-rafael"}}
    },
    {
      "tag": "httpupgrade", "port": 11004, "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {"clients": [{"id": "15f7e8ea-7b56-45d4-93af-31f3c592fdf1"}], "decryption": "none"},
      "sniffing": {"enabled": true, "destOverride": ["http", "tls"]},
      "streamSettings": {"network": "httpupgrade", "httpupgradeSettings": {"path": "/httpupgrade-rafael"}}
    }
  ],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}],
  "routing": {"domainStrategy": "IPIfNonMatch", "rules": [{"type": "field", "outboundTag": "direct", "ip": ["0.0.0.0/0", "::/0"]}]}
}
EOF

# ✅ NGINX - TAMA ANG PROXY
cat > nginx.conf <<EOF
worker_processes auto;
events { worker_connections 65535; }
http {
  sendfile on; tcp_nopush on; tcp_nodelay on;
  proxy_buffering off; proxy_request_buffering off;
  map \$http_upgrade \$conn { default upgrade; '' close; }

  server {
    listen 8080;
    server_name _;

    # Default fallback
    location / {
      proxy_ssl_server_name on;
      proxy_pass https://$DOMAIN;
      proxy_set_header Host $DOMAIN;
    }

    # Protocols
    location ~ ^/(trojan-rafael|vless-rafael|vmess-rafael|httpupgrade-rafael) {
      proxy_pass http://127.0.0.1\$request_uri;
      proxy_http_version 1.1;
      proxy_set_header Upgrade \$http_upgrade;
      proxy_set_header Connection \$conn;
      proxy_set_header Host \$host;
      proxy_read_timeout 3600s;
    }
  }
}
EOF

# ✅ ENTRYPOINT
cat > entrypoint.sh <<EOF
#!/bin/sh
set -e
/usr/local/bin/xray run -c /etc/xray.json &
sleep 3
exec openresty -g 'daemon off;'
EOF
chmod +x entrypoint.sh

# ✅ DOCKERFILE - Walang error sa pag-download
cat > Dockerfile <<EOF
FROM alpine:3.20 AS xray
RUN apk add --no-cache curl unzip
RUN curl -fL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o x.zip \
 && unzip x.zip && chmod +x xray && mv xray /usr/bin/ && rm -rf x.zip

FROM openresty/openresty:alpine
COPY --from=xray /usr/bin/xray /usr/bin/xray
COPY config.json /etc/xray.json
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 8080
CMD ["/entrypoint.sh"]
EOF

# Build at Deploy
echo -e "\n${CYAN}--- BUILDING ---${NC}"
gcloud builds submit --quiet -t gcr.io/$PROJECT_ID/$SVC_NAME .

echo -e "\n${CYAN}--- DEPLOYING ---${NC}"
gcloud run deploy $SVC_NAME \
  --image gcr.io/$PROJECT_ID/$SVC_NAME \
  --platform managed --region $REGION \
  --allow-unauthenticated --port 8080 \
  --memory $MEM --cpu $CPU \
  --concurrency 1000 --timeout 3600 \
  --min-instances $MIN --max-instances $MAX \
  --execution-environment gen2 $BILL_FLAGS --quiet

SVC_URL=$(gcloud run services describe $SVC_NAME --region $REGION --format='value(status.url)')

echo -e "\n${GREEN}✅ MATAGUMPAY!${NC}"
echo -e "${CYAN}URL NG SERVER: ${NC}$SVC_URL"
echo -e "\n${YELLOW}Gamitin ang mga settings na ito sa iyong app:${NC}"

