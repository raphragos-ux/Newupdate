#!/bin/bash

set +e

# =========================================
# SHELL DEPLOYER BY RAFAEL R. — FINAL WORKING FIX
# =========================================

# =========================
# COLORS
# =========================
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# =========================
# VARIABLES
# =========================
PROJECT_ID="$(gcloud config get-value project)"
REGION="us-central1"
RAND=$(openssl rand -hex 3)
CLOUD_RUN_SERVICE_NAME="rafael-$RAND"
DOMAIN="www.google.com"
BUILD_DIR=$(mktemp -d)

# =========================
# CLEANUP
# =========================
cleanup() {
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

# =========================
# HEADER
# =========================
clear
echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}       SHELL DEPLOYER BY RAFAEL R.${NC}"
echo -e "${GREEN}        FINAL FIXED VERSION${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

# =========================
# CHECK PROJECT
# =========================
if [ -z "$PROJECT_ID" ]; then
    echo ""
    echo -e "${RED}ERROR: No Google Cloud project set.${NC}"
    echo ""
    echo "Run first:"
    echo "gcloud config set project YOUR_PROJECT_ID"
    echo ""
    exit 1
fi

# =========================
# ENABLE REQUIRED APIS
# =========================
echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}        ENABLING REQUIRED APIS${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""
gcloud services enable --quiet \
run.googleapis.com \
cloudbuild.googleapis.com \
artifactregistry.googleapis.com

# =========================
# BILLING SETTINGS
# =========================
echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}          BILLING MODE${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""
echo -e "${WHITE}1) REQUEST-BASED (cheaper, good for light use)${NC}"
echo -e "${WHITE}2) INSTANCE-BASED (stable, no CPU limit)${NC}"
echo ""
while true; do
    read -p "Select [1-2]: " BILLING_CHOICE
    case $BILLING_CHOICE in
        1) BILLING_MODE="request"; BILLING_FLAGS="--cpu-throttling"; break ;;
        2) BILLING_MODE="instance"; BILLING_FLAGS="--no-cpu-throttling"; break ;;
        *) echo -e "${RED}Invalid input, try again${NC}" ;;
    esac
done

# =========================
# RESOURCE SETTINGS
# =========================
echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}      RESOURCE SETTINGS${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""
echo "MEMORY OPTIONS:"
echo "1) 512Mi   2) 1Gi   3) 2Gi   4) 4Gi   5) 8Gi   6) 16Gi   7) 32Gi"
read -p "Select Memory [default 4Gi]: " MEMORY_CHOICE
MEMORY_CHOICE=${MEMORY_CHOICE:-4}
case $MEMORY_CHOICE in
    1) MEMORY="512Mi" ;;
    2) MEMORY="1Gi" ;;
    3) MEMORY="2Gi" ;;
    4) MEMORY="4Gi" ;;
    5) MEMORY="8Gi" ;;
    6) MEMORY="16Gi" ;;
    7) MEMORY="32Gi" ;;
    *) MEMORY="4Gi" ;;
esac

echo ""
echo "vCPU OPTIONS:"
echo "1) 1vCPU   2) 2vCPU   3) 4vCPU   4) 6vCPU   5) 8vCPU"
read -p "Select vCPU [default 4]: " CPU_CHOICE
CPU_CHOICE=${CPU_CHOICE:-3}
case $CPU_CHOICE in
    1) CPU="1" ;;
    2) CPU="2" ;;
    3) CPU="4" ;;
    4) CPU="6" ;;
    5) CPU="8" ;;
    *) CPU="4" ;;
esac

# =========================
# INSTANCE LIMITS
# =========================
CONCURRENCY="1000"
TIMEOUT="3600"
read -p "Min Instances [0-1, default 0]: " MIN_INST
MIN_INST=${MIN_INST:-0}
[[ ! "$MIN_INST" =~ ^[01]$ ]] && MIN_INST=0

read -p "Max Instances [1-4, default 2]: " MAX_INST
MAX_INST=${MAX_INST:-2}
[[ ! "$MAX_INST" =~ ^[1-4]$ ]] && MAX_INST=2

# =========================
# PREPARE FILES
# =========================
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR" || exit 1

# --- CONFIG.JSON (FIXED ROUTING & SNIFFING) ---
cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "trojan-ws",
      "port": 10001,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": { "clients": [{ "password": "rafaeltv" }] },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"], "metadataOnly": false },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/trojan-rafael?ed=2180", "headers": {} } }
    },
    {
      "tag": "vless-ws",
      "port": 10002,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "15f7e8ea-7b56-45d4-93af-31f3c592fdf1", "level": 0 }],
        "decryption": "none"
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"], "metadataOnly": false },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vless-rafael?ed=2180" } }
    },
    {
      "tag": "vmess-ws",
      "port": 10003,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [{ "id": "15f7e8ea-7b56-45d4-93af-31f3c592fdf1", "alterId": 0, "security": "auto" }]
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"], "metadataOnly": false },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vmess-rafael?ed=2180" } }
    },
    {
      "tag": "httpupgrade-in",
      "port": 11004,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "15f7e8ea-7b56-45d4-93af-31f3c592fdf1", "level": 0 }],
        "decryption": "none"
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"], "metadataOnly": false },
      "streamSettings": { "network": "httpupgrade", "httpupgradeSettings": { "path": "/httpupgrade-rafael?ed=2180" } }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "outboundTag": "direct", "domain": ["geosite:open", "geosite:category-anything"] },
      { "type": "field", "outboundTag": "direct", "ip": ["0.0.0.0/0", "::/0"] }
    ]
  }
}
EOF

# --- NGINX.CONF (FIXED PATH MATCHING) ---
cat > nginx.conf <<EOF
worker_processes auto;
worker_rlimit_nofile 200000;
events { worker_connections 65535; multi_accept on; }
http {
    sendfile on; tcp_nopush on; tcp_nodelay on;
    keepalive_timeout 65; keepalive_requests 100000;
    client_max_body_size 0;
    proxy_connect_timeout 300; proxy_send_timeout 86400; proxy_read_timeout 86400;
    proxy_buffering off; proxy_request_buffering off;
    server_tokens off;

    map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }

    server {
        listen 8080;
        server_name _;

        location / {
            proxy_ssl_server_name on;
            proxy_ssl_protocols TLSv1.2 TLSv1.3;
            proxy_pass https://$DOMAIN;
            proxy_set_header Host $DOMAIN;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location ~ ^/trojan-rafael {
            proxy_pass http://127.0.0.1:10001;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_read_timeout 86400;
        }

        location ~ ^/vless-rafael {
            proxy_pass http://127.0.0.1:10002;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_read_timeout 86400;
        }

        location ~ ^/vmess-rafael {
            proxy_pass http://127.0.0.1:10003;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_read_timeout 86400;
        }

        location ~ ^/httpupgrade-rafael {
            proxy_pass http://127.0.0.1:11004;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_read_timeout 86400;
        }
    }
}
EOF

# --- ENTRYPOINT ---
cat > entrypoint.sh <<EOF
#!/bin/sh
set -e
/usr/local/bin/xray run -c /etc/xray.json &
sleep 5
exec /usr/local/openresty/bin/openresty -g 'daemon off;'
EOF
chmod +x entrypoint.sh

# --- DOCKERFILE (FIXED XRAY DOWNLOAD) ---
cat > Dockerfile <<EOF
FROM alpine:3.20 AS xray-bin
RUN apk add --no-cache curl unzip ca-certificates
WORKDIR /app
RUN curl -fL --retry 3 https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o xray.zip \
    && unzip -q xray.zip \
    && chmod +x xray \
    && mv xray /usr/local/bin/xray \
    && rm -f xray.zip

FROM openresty/openresty:alpine-fat
RUN apk add --no-cache ca-certificates tzdata
COPY --from=xray-bin /usr/local/bin/xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
EOF

# =========================
# BUILD & DEPLOY
# =========================
echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}          BUILDING IMAGE${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""
gcloud builds submit --quiet \
  --tag gcr.io/$PROJECT_ID/$CLOUD_RUN_SERVICE_NAME \
  .

echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}         DEPLOYING TO CLOUD RUN${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""
gcloud run deploy $CLOUD_RUN_SERVICE_NAME \
  --image gcr.io/$PROJECT_ID/$CLOUD_RUN_SERVICE_NAME \
  --platform managed \
  --region $REGION \
  --allow-unauthenticated \
  --port 8080 \
  --memory $MEMORY \
  --cpu $CPU \
  --concurrency $CONCURRENCY \
  --timeout $TIMEOUT \
  --min-instances $MIN_INST \
  --max-instances $MAX_INST \
  --execution-environment gen2 \
  --cpu-boost \
  $BILLING_FLAGS \
  --quiet

CLOUD_RUN_URL=$(gcloud run services describe $CLOUD_RUN_SERVICE_NAME \
  --region=$REGION --format='value(status.url)' 2>/dev/null || echo "CHECK LOGS FOR ERROR")

# =========================
# FINAL OUTPUT
# =========================
echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}✅ DEPLOYMENT FINISHED${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""
echo -e "${GREEN}YOUR SERVICE URL:${NC}"
echo "$CLOUD_RUN_URL"
echo ""

echo -e "${CYAN}--- TROJAN WS ---${NC}"
echo "Password: rafaeltv | Path: /trojan-rafael?ed=2180 | SNI: www.google.com"

echo -e "${CYAN}--- VLESS WS ---${NC}"
echo "UUID: 15f7e8ea-7b56-45d4-93af-31f3c592fdf1 | Encryption: none | Path: /vless-rafael?ed=2180 | SNI: www.google.com"

echo -e "${CYAN}--- VMess WS ---${NC}"
echo "UUID: 15f7e8ea-7b56-45d4-93af-31f3c592fdf1 | AlterId: 0 | Security: auto | Path: /vmess-rafael?ed=2180 | SNI: www.google.com"

echo -e "${CYAN}--- HTTPUpgrade ---${NC}"
echo "UUID: 15f7e8ea-7b56-45d4-93af-31f3c592fdf1 | Encryption: none | Path: /httpupgrade-rafael?ed=2180 | SNI: www.google.com"

echo ""
echo -e "${GREEN}Copy the URL above and replace YOUR_CLOUD_RUN_URL in the config links I gave you earlier!${NC}"
echo -e "${CYAN}=========================================${NC}"
