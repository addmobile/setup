#!/usr/bin/env bash

set -euo pipefail

POD_NAME="mobile-pod"

REGISTRY="https://registry.mobile-developer.com"

# ---- Images (override via env vars if you have your own) -----------------
KAFKA_IMAGE="${KAFKA_IMAGE:-docker.io/apache/kafka:4.3.1}"
MONGO_IMAGE="${MONGO_IMAGE:-docker.io/library/mongo:8.2.3-noble}"
MOBILESERVICES_IMAGE="${MOBILESERVICES_IMAGE:-registry.mobile-developer.com/mobileservices:v0.0.4}"
ADDMOBILEPORTAL_IMAGE="${SERVICE2_IMAGE:-registry.mobile-developer.com/add-mobileportal:v1.0.0.30}"
NGINX_IMAGE="${NGINX_IMAGE:-docker.io/library/nginx:alpine}"

# ---- Ports (host-published ports on the pod) -------------------------------
HTTP_PORT="${HTTP_PORT:-4444}"          # nginx entrypoint
KAFKA_PORT="${KAFKA_PORT:-9092}"
MONGO_PORT="${MONGO_PORT:-27017}"
MOBILESERVICES_PORT="${MOBILESERVICES_PORT:-8081}"
ADDMOBILEPORTAL_PORT="${SERVICE2_PORT:-8082}"

# ---- Local config/data dirs -------------------------------------------------
BASE_DIR="${HOME}/mobile-pod"
CONF_DIR="${BASE_DIR}/conf"
DATA_DIR="${BASE_DIR}/data"
KAFKA_DIR="${DATA_DIR}/kafka"
MONGODB_DIR="${DATA_DIR}/mongo"

teardown() {
  echo ">> Removing pod '${POD_NAME}' (if it exists)..."
  podman pod rm -f "${POD_NAME}" 2>/dev/null || true
  echo ">> Done."
}

if [[ "${1:-}" == "down" ]]; then
  teardown
  exit 0
fi

# Clean up any previous run so this script is idempotent
teardown

read -r -p "Username: " USERNAME < /dev/tty
read -r -s -p "Password: " PASSWORD < /dev/tty
echo

# Pass the password via stdin so it never appears in process listings
# (e.g. `ps aux`) or shell history.
if printf '%s' "${PASSWORD}" | podman login "${REGISTRY}" --username "${USERNAME}" --password-stdin; then
  echo ">> Successfully logged in to ${REGISTRY} as ${USERNAME}."
else
  echo ">> Login to ${REGISTRY} failed." >&2
  exit 1
fi

if [ -z "${AUTH_URL}" ]; then
  read -p "Enter ADD-Gateway URL: " AUTH_URL
fi

STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${AUTH_URL}")

if [ "$STATUS_CODE" -eq 200 ]; then
    echo "✅  Success: {AUTH_URL} returned HTTP 200"
else
    echo "❌  Failed: {AUTH_URL} returned HTTP $STATUS_CODE"
    exit 1
fi

mkdir -m 777 -p "${CONF_DIR}" "${DATA_DIR}/mongo" "${DATA_DIR}/kafka"

# ---- 1. Create the pod ------------------------------------------------------
echo ">> Creating pod '${POD_NAME}'..."
podman pod create \
  --name "${POD_NAME}" \
  -p "${HTTP_PORT}:80" \
  -p "${MOBILESERVICES_PORT}:${MOBILESERVICES_PORT}"


if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
      VOLUME_SUFFIX=":Z"
    else
      VOLUME_SUFFIX=""
fi

echo "Using volume suffix '$VOLUME_SUFFIX'"

# ---- 2. Kafka (KRaft single-node mode, no ZooKeeper required) --------------
echo ">> Starting kafka..."

podman run -d \
  --pod mobile-pod \
  --name kafka \
  --restart always \
  --memory 1g --memory-swap 1g \
  --volume "${KAFKA_DIR}:/var/lib/kafka/data${VOLUME_SUFFIX}" \
  --env KAFKA_LOG_DIRS=/var/lib/kafka/data \
  --env KAFKA_NODE_ID=1 \
  --env KAFKA_PROCESS_ROLES=broker,controller \
  --env KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093 \
  --env KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://kafka:9092 \
  --env KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
  --env KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT \
  --env KAFKA_CONTROLLER_QUORUM_VOTERS=1@kafka:9093 \
  --env KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
  --env KAFKA_OFFSETS_TOPIC_NUM_PARTITIONS=1 \
  --env KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
  --env KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 \
  --env KAFKA_LOG_RETENTION_HOURS=24 \
  --env KAFKA_LOG_RETENTION_CHECK_INTERVAL_MS=300000 \
  --env KAFKA_LOG_SEGMENT_BYTES=67108864 \
  --env KAFKA_LOG_RETENTION_BYTES=268435456 \
  --env KAFKA_HEAP_OPTS="-Xmx512m -Xms512m" \
  "${KAFKA_IMAGE}"
  

# ---- 3. MongoDB --------------------------------------------------------------
echo ">> Starting Mongodb..."

podman run -d \
  --pod "${POD_NAME}" \
  --name mongodb \
  --restart always \
  --memory 768m --memory-swap 768m \
  --volume "${MONGODB_DIR}:/data/db${VOLUME_SUFFIX}" \
  --volume mongo-configdb:/data/configdb \
  "${MONGO_IMAGE}" \
  --bind_ip_all \
  --quiet \
  --wiredTigerCacheSizeGB 0.25 \
  --setParameter diagnosticDataCollectionEnabled=false

# ---- 4. service1 --------------------------------------------------------------
echo ">> Starting MobileServices..."
podman run -d \
  --pod "${POD_NAME}" \
  --name mobileservices \
  -e ASPNETCORE_URLS="http://0.0.0.0:${MOBILESERVICES_PORT}" \
  -e AUTH_URL=${AUTH_URL} \
  "${MOBILESERVICES_IMAGE}"

# ---- 5. service2 --------------------------------------------------------------
echo ">> Starting ADD-MOBILEPORTAL..."
podman run -d \
  --pod "${POD_NAME}" \
  --name add-mobileportal \
  -e PORT="${ADDMOBILEPORTAL_PORT}" \
  -e MONGO_URL="mongodb://127.0.0.1:${MONGO_PORT}" \
  -e KAFKA_BROKERS="kafka:${KAFKA_PORT}" \
  "${ADDMOBILEPORTAL_IMAGE}"

# ---- 6. NGINX reverse proxy -> service2 --------------------------------------
echo ">> Writing nginx config..."
cat > "${CONF_DIR}/nginx.conf" <<EOF
events {}

http {
    server {
        listen 80;

        location /gateway/auth/ {
          internal; 
          proxy_set_header      Content-Length ""; 
          proxy_set_header      X-Original-URI   \$request_uri;
          proxy_pass            http://127.0.0.1:${MOBILESERVICES_PORT}/auth/verify;
        }

        location / {
            auth_request        /gateway/auth/;
            proxy_pass          http://127.0.0.1:${ADDMOBILEPORTAL_PORT};
            proxy_set_header    Host \$host;
            proxy_set_header    X-Real-IP \$remote_addr;
            proxy_set_header    X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header    X-Forwarded-Proto \$scheme;
        }

        location /health {
          return 200 "Ok!";
        }
    }
}
EOF

echo ">> Starting nginx..."
podman run -d \
  --pod "${POD_NAME}" \
  --name nginx \
  -v "${CONF_DIR}/nginx.conf:/etc/nginx/nginx.conf:ro,Z" \
  "${NGINX_IMAGE}"

echo ">> All containers started. Pod status:"
podman pod ps
podman ps --pod

unset PASSWORD
