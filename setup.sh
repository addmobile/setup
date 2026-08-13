#!/usr/bin/env bash

set -euo pipefail

POD_NAME="mobile-pod"

REGISTRY="${REGISTRY:-https://hub.addsys.com:33443}"
REGISTRY_HOST="${REGISTRY#https://}"
PORTAL_REPO="add-mobileportal"
MOBILESERVICES_REPO="mobileservices"
UNINSTALL_CMD='bash -c "$(curl -fsSL https://raw.githubusercontent.com/addmobile/setup/refs/heads/main/clear.sh)"'

# ---- Images (override via env vars if you have your own) -----------------
KAFKA_IMAGE="${KAFKA_IMAGE:-docker.io/apache/kafka:4.3.1}"
MONGO_IMAGE="${MONGO_IMAGE:-docker.io/library/mongo:8.2.3-noble}"
MOBILESERVICES_IMAGE="${MOBILESERVICES_IMAGE:-}"
ADDMOBILEPORTAL_IMAGE="${SERVICE2_IMAGE:-}"
NGINX_IMAGE="${NGINX_IMAGE:-docker.io/library/nginx:alpine}"

# ---- Ports (in-pod, nginx ports) -----------------------------------------
KAFKA_PORT="${KAFKA_PORT:-9092}"
MOBILEAPI_PORT="${MOBILEAPI_PORT:-}"   # prompted below when unset; default 8080
MOBILEAPI_BIND_HOST="${MOBILEAPI_BIND_HOST:-}"   # empty = all interfaces (see above)
KAFKA_BROKERS="${KAFKA_BROKERS:-}"
MOBILESERVICES_PORT="${MOBILESERVICES_PORT:-8081}"
ADDMOBILEPORTAL_PORT="${ADDMOBILEPORTAL_PORT:-${SERVICE2_PORT:-8082}}"
MONGO_PORT_INTERNAL="27017"
MOBILESERVICES_IMAGE_PORT="8081"

# ---- Local config/data dirs -------------------------------------------------
BASE_DIR="${HOME}/ADD_MOBILE"
CONF_DIR="${BASE_DIR}/conf"
DATA_DIR="${BASE_DIR}/data"
KAFKA_DIR="${DATA_DIR}/kafka"
MONGODB_DIR="${DATA_DIR}/mongo"
GATEWAY_URL="${GATEWAY_URL:-}"

# ---- Icons ------------------------
ICON_THUMBSUP="👍"
ICON_THUMBSDOWN="👎"
ICON_WARN="⚠️"
ICON_TIP="😎"

# ---- Colors -----------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

echo -e "\033[38;5;33m █████╗ ██████╗ ██████╗    ███╗   ███╗ ██████╗ ██████╗ ██╗██╗     ███████╗\033[0m"
echo -e "\033[38;5;33m██╔══██╗██╔══██╗██╔══██╗   ████╗ ████║██╔═══██╗██╔══██╗██║██║     ██╔════╝\033[0m"
echo -e "\033[38;5;39m███████║██║  ██║██║  ██║   ██╔████╔██║██║   ██║██████╔╝██║██║     █████╗  \033[0m"
echo -e "\033[38;5;39m██╔══██║██║  ██║██║  ██║   ██║╚██╔╝██║██║   ██║██╔══██╗██║██║     ██╔══╝  \033[0m"
echo -e "\033[38;5;45m██║  ██║██████╔╝██████╔╝   ██║ ╚═╝ ██║╚██████╔╝██████╔╝██║███████╗███████╗\033[0m"
echo -e "\033[38;5;45m╚═╝  ╚═╝╚═════╝ ╚═════╝    ╚═╝     ╚═╝ ╚═════╝ ╚═════╝ ╚═╝╚══════╝╚══════╝\033[0m"

echo -e "${BLUE}ADD Systems, Inc.${NC}"

teardown() {
  if podman pod exists "${POD_NAME}"; then
    echo -e "${RED}Removing pod ${GREEN}'${POD_NAME}'${NC}"
    podman pod rm -f "${POD_NAME}" 2>/dev/null || true
    echo ""
  fi
}

if [[ "${1:-}" == "down" ]]; then
  teardown
  exit 0
fi

# ---- Host prerequisites ------------------------------------------------------
for tool in podman curl loginctl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo -e "${ICON_THUMBSDOWN} ${RED} ${tool} is not installed.${NC}" >&2
    echo -e "${BLUE} On Ubuntu/Debian: ${GREEN}sudo apt-get install -y ${tool}${NC}" >&2
    exit 1
  fi
done

if ! podman info >/dev/null 2>&1; then
  echo -e "${ICON_THUMBSDOWN} ${RED} podman is installed but not working for ${USER} (rootless setup incomplete?).${NC}" >&2
  echo -e "${BLUE} Diagnose with: ${GREEN}podman info${NC}" >&2
  exit 1
fi

echo -e "${BLUE}Login to ${REGISTRY}${NC}"

read -r -p "Username: " USERNAME < /dev/tty
read -r -s -p "Password: " PASSWORD < /dev/tty
echo ""

# Pass the password via stdin so it never appears in process listings
# (e.g. `ps aux`) or shell history.
if printf '%s' "${PASSWORD}" | podman login "${REGISTRY}" --username "${USERNAME}" --password-stdin; then
  echo -e "${ICON_THUMBSUP} ${GREEN} Successfully logged in to ${REGISTRY} as ${USERNAME}.${NC}"
else
  echo -e "${ICON_THUMBSDOWN} ${RED} Login to ${REGISTRY} failed.${NC}" >&2
  exit 1
fi

# ---- Resolve image tags from the registry (latest v-prefixed tag wins) -------
latest_tag() {
  curl -fsS -u "${USERNAME}:${PASSWORD}" "${REGISTRY}/v2/$1/tags/list" 2>/dev/null \
    | tr ',' '\n' \
    | grep -oE '"v[0-9][^"]*"' \
    | tr -d '"' \
    | sort -t. -k1,1V -k2,2n -k3,3n -k4,4n \
    | tail -1
}

# An explicit override wins untouched; otherwise ask the registry.
resolve_image() {
  local repo="$1" override="$2" tag
  if [ -n "$override" ]; then
    printf '%s' "$override"
    return 0
  fi
  tag="$(latest_tag "$repo" || true)"
  [ -n "$tag" ] || return 1
  printf '%s' "${REGISTRY_HOST}/${repo}:${tag}"
}

resolve_or_die() {
  local repo="$1" override="$2" override_name="$3" resolved
  if ! resolved="$(resolve_image "$repo" "$override")"; then
    echo -e "${ICON_THUMBSDOWN} ${RED} Could not resolve a tag for ${repo} from ${REGISTRY}.${NC}" >&2
    echo -e "${BLUE} Check the registry is reachable and your account can read ${repo},${NC}" >&2
    echo -e "${BLUE} or pin a release explicitly: ${GREEN}export ${override_name}=${REGISTRY_HOST}/${repo}:<tag>${NC}" >&2
    exit 1
  fi
  printf '%s' "$resolved"
}

echo -e "${BLUE}Resolving image versions...${NC}"
ADDMOBILEPORTAL_IMAGE="$(resolve_or_die "$PORTAL_REPO" "$ADDMOBILEPORTAL_IMAGE" SERVICE2_IMAGE)"
MOBILESERVICES_IMAGE="$(resolve_or_die "$MOBILESERVICES_REPO" "$MOBILESERVICES_IMAGE" MOBILESERVICES_IMAGE)"
echo -e "${ICON_THUMBSUP} ${GREEN} ${ADDMOBILEPORTAL_IMAGE}${NC}"
echo -e "${ICON_THUMBSUP} ${GREEN} ${MOBILESERVICES_IMAGE}${NC}"

if [ -z "${MOBILEAPI_PORT}" ]; then
  echo -e "${ICON_TIP} ${BLUE} \nTip: Set the environment variable MOBILEAPI_PORT during login ${GREEN}(e.g. ~/.bashrc, ~/.cshrc, ~/.zshrc)${BLUE} so you don't have to enter it here.${NC}"
  echo ""
  read -r -p "PORT (default: 8080): " MOBILEAPI_PORT < /dev/tty
  MOBILEAPI_PORT="${MOBILEAPI_PORT:-8080}"
  echo ""
fi

if [ -z "${GATEWAY_URL}" ]; then
  echo ""
  echo -e "${ICON_WARN} ${YELLOW} GATEWAY_URL is not set.${NC}"
  echo ""
  echo -e "${ICON_TIP} ${BLUE} Tip: Set the environment variable GATEWAY_URL during login ${GREEN}(e.g. ~/.bashrc, ~/.cshrc, ~/.zshrc)${BLUE} so you don't have to enter it here.${NC}"
  echo ""
  read -r -p "Enter GATEWAY_URL (i.e. https://<gateway>.<yourdomain>:39079): " GATEWAY_URL < /dev/tty
fi

echo -e "${YELLOW}------------------------------------ ENV -----------------------------------${NC}"
echo -e "${YELLOW} MOBILEAPI_PORT ${NC}${MOBILEAPI_PORT}"
echo -e "${YELLOW} GATEWAY_URL    ${NC}${GATEWAY_URL}"
echo -e "${YELLOW}------------------------------------ ENV -----------------------------------${NC}"

DISCOVERY_URL="${GATEWAY_URL%/}/.well-known/openid-configuration"
STATUS_CODE="$(curl -s -o /dev/null -w "%{http_code}" "${DISCOVERY_URL}" || echo "000")"

if [ "$STATUS_CODE" = "200" ]; then
    echo -e "${ICON_THUMBSUP} ${GREEN} Success:${DISCOVERY_URL} returned HTTP 200 ${NC}"
else
    echo -e "${ICON_THUMBSDOWN} ${RED} Failed:${DISCOVERY_URL} returned HTTP ${STATUS_CODE} ${NC}"
    exit 1
fi

mkdir -p "${CONF_DIR}" "${MONGODB_DIR}"
chmod 777 "${CONF_DIR}" "${MONGODB_DIR}"
if [ -n "${KAFKA_BROKERS}" ]; then
  mkdir -p "${KAFKA_DIR}"
  chmod 777 "${KAFKA_DIR}"
fi

# ---- Pull every image before touching the running pod ------------------------
PULL_IMAGES=("${ADDMOBILEPORTAL_IMAGE}" "${MOBILESERVICES_IMAGE}" "${MONGO_IMAGE}" "${NGINX_IMAGE}")
[ -n "${KAFKA_BROKERS}" ] && PULL_IMAGES+=("${KAFKA_IMAGE}")

echo ""
echo -e "${BLUE}Pulling images...${NC}"
for image in "${PULL_IMAGES[@]}"; do
  if podman image exists "${image}"; then
    echo "Present: ${image}"
    continue
  fi
  echo "Pulling: ${image}"
  if ! podman pull "${image}"; then
    echo -e "${ICON_THUMBSDOWN} ${RED} Could not pull ${image}. Nothing was changed.${NC}" >&2
    exit 1
  fi
done

# ---- nginx config ------------------------------------------------------------
echo ""
echo -e "${BLUE}Rendering nginx config (${CONF_DIR}/nginx.conf)...${NC}"
if ! NGINX_TEMPLATE="$(podman run --rm --entrypoint cat "${ADDMOBILEPORTAL_IMAGE}" /app/deploy/nginx.conf.template 2>/dev/null)" \
   || [ -z "${NGINX_TEMPLATE}" ]; then
  echo -e "${ICON_THUMBSDOWN} ${RED} ${ADDMOBILEPORTAL_IMAGE} does not ship /app/deploy/nginx.conf.template.${NC}" >&2
  echo -e "${BLUE} Pull an add-mobileportal release built after the nginx template was added.${NC}" >&2
  exit 1
fi

printf '%s\n' "${NGINX_TEMPLATE}" \
  | sed -e "s|__ADDMOBILEPORTAL_PORT__|${ADDMOBILEPORTAL_PORT}|g" \
        -e "s|__MOBILESERVICES_PORT__|${MOBILESERVICES_PORT}|g" \
  > "${CONF_DIR}/nginx.conf"

teardown

# ---- 1. Create the pod ------------------------------------------------------
echo -e "${YELLOW}>> Creating pod '${POD_NAME}' (host ${MOBILEAPI_BIND_HOST:-0.0.0.0}:${MOBILEAPI_PORT} -> nginx:80)...${NC}"
podman pod create \
  --name "${POD_NAME}" \
  -p "${MOBILEAPI_BIND_HOST:+${MOBILEAPI_BIND_HOST}:}${MOBILEAPI_PORT}:80"

if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
  VOLUME_SUFFIX=":Z"
else
  VOLUME_SUFFIX=""
fi

echo "Using volume suffix '$VOLUME_SUFFIX'"

# ---- 2. Kafka (KRaft single-node mode, no ZooKeeper required; OFF by default) ----
if [ -z "${KAFKA_BROKERS}" ]; then
  echo ">> Kafka disabled (KAFKA_BROKERS empty) -- skipping the broker container."
else
echo ">> Starting kafka..."

podman run -d \
  --pod "${POD_NAME}" \
  --name kafka \
  --restart always \
  --memory 1g --memory-swap 1g \
  --volume "${KAFKA_DIR}:/var/lib/kafka/data${VOLUME_SUFFIX}" \
  --env KAFKA_LOG_DIRS=/var/lib/kafka/data \
  --env KAFKA_NODE_ID=1 \
  --env KAFKA_PROCESS_ROLES=broker,controller \
  --env KAFKA_LISTENERS=PLAINTEXT://127.0.0.1:${KAFKA_PORT},CONTROLLER://127.0.0.1:9093 \
  --env KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://kafka:${KAFKA_PORT} \
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
fi

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

# Wait for the first successful ping.
echo ">> Waiting for MongoDB..."
MONGO_READY=0
for _ in $(seq 1 45); do
  if [ "$(podman exec mongodb mongosh --quiet --eval 'try{db.runCommand({ping:1}).ok}catch(e){0}' 2>/dev/null)" = "1" ]; then
    MONGO_READY=1
    break
  fi
  sleep 1
done

if [ "$MONGO_READY" -ne 1 ]; then
  echo -e "${ICON_THUMBSDOWN} ${RED} MongoDB never became ready. Check: podman logs mongodb${NC}" >&2
  exit 1
fi
echo -e "${ICON_THUMBSUP} ${GREEN} MongoDB ready${NC}"

# ---- 4. MobileServices (auth verify, pod-internal) --------------------------
echo ">> Starting MobileServices..."
MOBILESERVICES_ENV_FLAGS=(--env "AUTH_URL=${GATEWAY_URL}")
if [ "${MOBILESERVICES_PORT}" != "${MOBILESERVICES_IMAGE_PORT}" ]; then
  MOBILESERVICES_ENV_FLAGS+=(--env "Kestrel__Endpoints__Http__Url=http://0.0.0.0:${MOBILESERVICES_PORT}")
fi

podman run -d \
  --pod "${POD_NAME}" \
  --name mobileservices \
  --restart always \
  --memory 512m --memory-swap 512m \
  "${MOBILESERVICES_ENV_FLAGS[@]}" \
  "${MOBILESERVICES_IMAGE}"

# ---- 5. ADD-MOBILEPORTAL (API, pod-internal) --------------------------------
echo ">> Starting ADD-MOBILEPORTAL..."
podman run -d \
  --pod "${POD_NAME}" \
  --name add-mobileportal \
  --restart always \
  --health-on-failure=kill \
  --memory 1g --memory-swap 1g \
  -e API_PORT="${ADDMOBILEPORTAL_PORT}" \
  -e MONGO_URL="mongodb://127.0.0.1:${MONGO_PORT_INTERNAL}" \
  -e KAFKA_BROKERS="${KAFKA_BROKERS}" \
  ${LOG_LEVEL:+-e "LOG_LEVEL=${LOG_LEVEL}"} \
  ${DISABLE_USER_DATABASE_RESTRICTION:+-e "DISABLE_USER_DATABASE_RESTRICTION=${DISABLE_USER_DATABASE_RESTRICTION}"} \
  ${DEVICELOCATION_EXPIRES_SECONDS:+-e "DEVICELOCATION_EXPIRES_SECONDS=${DEVICELOCATION_EXPIRES_SECONDS}"} \
  ${DEVICESTATE_EXPIRES_SECONDS:+-e "DEVICESTATE_EXPIRES_SECONDS=${DEVICESTATE_EXPIRES_SECONDS}"} \
  "${ADDMOBILEPORTAL_IMAGE}"

# ---- 6. NGINX reverse proxy + auth_request gate ------------------------------
echo ">> Starting nginx..."
podman run -d \
  --pod "${POD_NAME}" \
  --name nginx \
  --restart always \
  -v "${CONF_DIR}/nginx.conf:/etc/nginx/nginx.conf:ro${VOLUME_SUFFIX}" \
  "${NGINX_IMAGE}"

# ---- 7. Prove the stack answers before declaring success --------------------
wait_for_http() {
  local _ code
  for _ in $(seq 1 30); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$1" || echo 000)"
    case "${code}" in
      2??) return 0 ;;
    esac
    sleep 1
  done
  return 1
}

echo ""
DEGRADED=0
if wait_for_http "http://127.0.0.1:${MOBILEAPI_PORT}/health"; then
  echo -e "${ICON_THUMBSUP} ${GREEN} nginx up${NC}"
else
  echo -e "${ICON_THUMBSDOWN} ${RED} nginx is not answering on ${MOBILEAPI_PORT}. Check: podman logs nginx${NC}"
  DEGRADED=1
fi
if wait_for_http "http://127.0.0.1:${MOBILEAPI_PORT}/ms/health"; then
  echo -e "${ICON_THUMBSUP} ${GREEN} auth verify up${NC}"
else
  echo -e "${ICON_THUMBSDOWN} ${RED} auth verify is not answering; every authenticated request would fail. Check: podman logs mobileservices${NC}"
  DEGRADED=1
fi
if wait_for_http "http://127.0.0.1:${MOBILEAPI_PORT}/amp/health"; then
  echo -e "${ICON_THUMBSUP} ${GREEN} add-mobileportal up${NC}"
else
  echo -e "${ICON_THUMBSDOWN} ${RED} add-mobileportal is not answering. Check: podman logs add-mobileportal${NC}"
  DEGRADED=1
fi

echo -e ">> Pod status:${GREEN}"
podman pod ps
podman ps --pod
echo -e "${NC}"

# Rootless --restart=always containers only survive logout and reboot with linger on
# and the podman-restart user service enabled.
LINGER="$(loginctl show-user "$USER" --property=Linger --value 2>/dev/null || echo unknown)"
if [ "$LINGER" != "yes" ]; then
  if loginctl enable-linger "$USER" 2>/dev/null; then
    echo -e "${GREEN}Linger enabled for $USER.${NC}"
  else
    echo -e "${ICON_WARN} ${YELLOW} Linger is OFF and could not be enabled -- the pod will die on logout/reboot.${NC}"
    echo -e "${BLUE} Run: ${GREEN}sudo loginctl enable-linger $USER${NC}"
  fi
fi
systemctl --user enable podman-restart.service >/dev/null 2>&1 \
  || echo -e "${ICON_WARN} ${YELLOW} Could not enable podman-restart.service; containers will not come back after a reboot.${NC}"

unset PASSWORD USERNAME

if [ "$DEGRADED" -ne 0 ]; then
  echo ""
  echo -e "${RED}The pod is running but INCOMPLETE.${NC}"
  echo -e "${BLUE}Tear it down with:${NC}"
  echo -e "${GREEN}  ${UNINSTALL_CMD}${NC}"
  echo ""
  exit 1
fi

echo -e "\n${BLUE}Listening to http://127.0.0.1:${MOBILEAPI_PORT}${NC}"

# The gate refuses any request without an X-Raven-Device header, and only checks it
# against the device ADD Security currently authorizes. A dispatcher running a client
# older than that change is answered 401 on every request -- which reads as an outage
# rather than a client that needs updating, so it is called out here.
echo ""
echo -e "${ICON_WARN} ${YELLOW} Dispatchers must be on a RavenLive build that sends its device identity.${NC}"
echo -e "${BLUE} Older clients are refused with 401 ADD_GATEWAY_UNAUTHORIZED on every request.${NC}"
echo -e "${BLUE} Roll the client out first, then this stack.${NC}"
echo ""
