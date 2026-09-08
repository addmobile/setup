#!/usr/bin/env bash

set -euo pipefail

POD_NAME="mobile-pod"

REGISTRY="${REGISTRY:-hub.addsys.com:33443}"
REGISTRY_HOST="${REGISTRY#*://}"
REGISTRY_HOST="${REGISTRY_HOST%/}"
case "${REGISTRY}" in
  http://*) REGISTRY_URL="http://${REGISTRY_HOST}" ;;
  *)        REGISTRY_URL="https://${REGISTRY_HOST}" ;;
esac
PORTAL_REPO="add-mobileportal"
MOBILESERVICES_REPO="mobileservices"
SETUP_REF="${SETUP_REF:-main}"
if ! [[ "${SETUP_REF}" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  echo "SETUP_REF contains unsupported characters: ${SETUP_REF}" >&2
  exit 2
fi
SETUP_RAW_BASE="https://raw.githubusercontent.com/addmobile/setup/${SETUP_REF}"
SETUP_URL="${SETUP_RAW_BASE}/setup.sh"
HOST_NGINX_URL="${SETUP_RAW_BASE}/host-nginx.sh"
UNINSTALL_CMD="bash -c \"\$(curl -fsSL ${SETUP_RAW_BASE}/clear.sh)\""
PORTAL_MIN_VERSION="v1.0.0.32"

# Container uids the bind-mounted data directories have to be writable by. mongod is handed
# to uid 999 by the image entrypoint; the kafka image runs as appuser.
MONGO_UID="999"
KAFKA_UID="1000"

# ---- Images (override via env vars if you have your own) -----------------
KAFKA_IMAGE="${KAFKA_IMAGE:-docker.io/apache/kafka:4.3.1}"
MONGO_IMAGE="${MONGO_IMAGE:-docker.io/library/mongo:8.2.3-noble}"
MOBILESERVICES_IMAGE="${MOBILESERVICES_IMAGE:-}"
ADDMOBILEPORTAL_IMAGE="${ADDMOBILEPORTAL_IMAGE:-${SERVICE2_IMAGE:-}}"
NGINX_IMAGE="${NGINX_IMAGE:-docker.io/library/nginx:alpine}"

# ---- Ports -------------------------------------------------------------------
# Only MOBILEAPI_PORT is published. Every other port here is pod loopback, so those
# numbers are internal and never have to be free on the host.
MOBILEAPI_PORT="${MOBILEAPI_PORT:-}"   # prompted below when unset; default 8080
MOBILEAPI_BIND_HOST="${MOBILEAPI_BIND_HOST:-127.0.0.1}"

KAFKA_PORT="${KAFKA_PORT:-}"           # pod-internal; setting it is the on/off switch
KAFKA_BROKERS=""
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
SERVER_NAME="${SERVER_NAME:-}"   # public hostname, used to render the host nginx vhost

# ---- Status prefixes --------------------------------------------------------
ICON_THUMBSUP="[OK]"
ICON_THUMBSDOWN="[ERROR]"
ICON_WARN="[WARN]"
ICON_TIP="[TIP]"

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

prepare_conf_dir() {
  local dir="$1"
  mkdir -p "$dir"
  if [ -O "$dir" ]; then
    chmod 755 "$dir"
  else
    echo "   ${dir} already belongs to uid $(stat -c %u "$dir" 2>/dev/null) from an earlier install; leaving its permissions alone."
  fi
}

prepare_data_dir() {
  local dir="$1" uid="$2"
  mkdir -p "$dir"

  if [ ! -O "$dir" ]; then
    echo "   ${dir} already belongs to uid $(stat -c %u "$dir" 2>/dev/null) from an earlier install; leaving its ownership alone."
    return 0
  fi

  chmod 700 "$dir"
  if ! podman unshare chown "${uid}:${uid}" "$dir" 2>/dev/null; then
    echo -e "${ICON_WARN} ${YELLOW} Could not map ${dir} into the container user namespace; falling back to 0777.${NC}"
    chmod 777 "$dir"
  fi
}

teardown() {
  if podman pod exists "${POD_NAME}"; then
    echo -e "${RED}Removing pod ${GREEN}'${POD_NAME}'${NC}"
    podman pod rm -f "${POD_NAME}" 2>/dev/null || true
    echo ""
  fi
}

POD_TOUCHED=0
on_failure() {
  local code=$?
  [ "$code" -eq 0 ] && return 0
  echo "" >&2
  if [ "${POD_TOUCHED}" -eq 0 ]; then
    echo -e "${ICON_THUMBSDOWN} ${RED} Install failed. The running pod, if there was one, is untouched.${NC}" >&2
  else
    echo -e "${ICON_THUMBSDOWN} ${RED} Install failed partway through building the pod -- '${POD_NAME}' is incomplete.${NC}" >&2
    echo -e "${BLUE} Inspect it with ${GREEN}podman ps --pod${BLUE}, or clear it with:${NC}" >&2
    echo -e "${GREEN}  ${UNINSTALL_CMD}${NC}" >&2
  fi
  return "$code"
}

wait_for_http() {
  local _ code
  for _ in $(seq 1 "${2:-30}"); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$1")" || code="000"
    case "${code}" in
      2??) return 0 ;;
    esac
    sleep 1
  done
  return 1
}

gate_state() {
  local url="$1" method="${2:-GET}" response code body
  response="$(curl -s -X "${method}" -w '\n%{http_code}' --max-time 5 "${url}" 2>/dev/null)" || response=$'\n000'
  code="${response##*$'\n'}"
  body="${response%$'\n'*}"

  case "${code}" in
    401)
      case "${body}" in
        ADD_GATEWAY_UNAUTHORIZED) echo "closed" ;;
        *)                          echo "closed-unmarked" ;;
      esac
      ;;
    503) echo "unavailable" ;;
    2??) echo "open" ;;
    500)
      case "${body}" in
        *GATE_NOT_CONFIGURED*) echo "ungated" ;;
        *)                     echo "inconclusive:${code}" ;;
      esac
      ;;
    *)   echo "inconclusive:${code}" ;;
  esac
}

report_gate() {
  local label="$1" url="$2" what="$3" method="${4:-GET}" state
  state="$(gate_state "${url}" "${method}")"
  case "${state}" in
    closed)
      echo -e "${ICON_THUMBSUP} ${GREEN} ${label} closed (unauthenticated requests refused)${NC}"
      ;;
    closed-unmarked)
      echo -e "${ICON_WARN} ${YELLOW} ${label} refused the request, but not with the gate's own 401.${NC}"
      echo -e "${BLUE} Something in front of nginx may be answering first. Requests are still refused.${NC}"
      DEGRADED=1
      ;;
    open)
      echo -e "${ICON_THUMBSDOWN} ${RED} THE ${label} IS OPEN -- an unauthenticated request was answered, not refused.${NC}"
      echo -e "${BLUE} ${what}${NC}"
      echo -e "${BLUE} Check: podman logs nginx, and ${CONF_DIR}/nginx.conf${NC}"
      DEGRADED=1
      ;;
    ungated)
      echo -e "${ICON_THUMBSDOWN} ${RED} ${label} is not wired up -- nginx is not stamping the caller's identity.${NC}"
      echo -e "${BLUE} The API is refusing every request rather than serving them, so nothing is exposed,${NC}"
      echo -e "${BLUE} but nothing works either. The fault is in the proxy, not the application.${NC}"
      echo -e "${BLUE} Check: ${CONF_DIR}/nginx.conf, and podman logs nginx${NC}"
      DEGRADED=1
      ;;
    unavailable)
      echo -e "${ICON_WARN} ${YELLOW} ${label} is enforcing but could not reach ADD Security (503).${NC}"
      echo -e "${BLUE} Requests are being refused, so nothing is exposed -- but nothing works either.${NC}"
      echo -e "${BLUE} Check GATEWAY_URL and: podman logs mobileservices${NC}"
      DEGRADED=1
      ;;
    *)
      echo -e "${ICON_WARN} ${YELLOW} ${label} answered ${state#inconclusive:}; could not confirm it is closed.${NC}"
      DEGRADED=1
      ;;
  esac
}

# Shared by the post-install checks and the `status` subcommand so the two can never drift.
# Sets DEGRADED when anything is wrong.
DEGRADED=0
check_endpoints() {
  local host="$1" port="$2" tries="${3:-1}"
  local base="http://${host}:${port}"

  if wait_for_http "${base}/health" "${tries}"; then
    echo -e "${ICON_THUMBSUP} ${GREEN} nginx up${NC}"
  else
    echo -e "${ICON_THUMBSDOWN} ${RED} nginx is not answering on ${port}. Check: podman logs nginx${NC}"
    DEGRADED=1
  fi
  if wait_for_http "${base}/ms/health" "${tries}"; then
    echo -e "${ICON_THUMBSUP} ${GREEN} auth verify up${NC}"
  else
    echo -e "${ICON_THUMBSDOWN} ${RED} auth verify is not answering; every authenticated request would fail. Check: podman logs mobileservices${NC}"
    DEGRADED=1
  fi
  if wait_for_http "${base}/amp/health" "${tries}"; then
    echo -e "${ICON_THUMBSUP} ${GREEN} add-mobileportal up${NC}"
  else
    echo -e "${ICON_THUMBSDOWN} ${RED} add-mobileportal is not answering. Check: podman logs add-mobileportal${NC}"
    DEGRADED=1
  fi

  report_gate "gate" "${base}/user" \
    "The API performs no authentication of its own, so everything behind nginx is open."
  report_gate "socket gate" "${base}/socket.io/?EIO=4&transport=polling" \
    "Live driver positions would be readable without a credential."
  local update
  for update in snapshot location window_state; do
    report_gate "${update} gate" "${base}/devices/gate-probe/${update}" \
      "Producer updates require an authenticated caller." POST
  done
}

status_report() {
  if ! podman pod exists "${POD_NAME}"; then
    echo "Pod '${POD_NAME}' does not exist."
    return 1
  fi

  echo -e "${YELLOW}---------------------------------- CONTAINERS ------------------------------${NC}"
  podman ps --pod --filter "pod=${POD_NAME}" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'

  local published=""
  published="$(podman pod inspect "${POD_NAME}" \
    --format '{{range (index . 0).InfraConfig.PortBindings}}{{range .}}{{.HostIP}}:{{.HostPort}}{{end}}{{end}}' 2>/dev/null)" \
    || published=""
  if [ -z "${published}" ]; then
    published="$(podman pod inspect "${POD_NAME}" \
      --format '{{range .InfraConfig.PortBindings}}{{range .}}{{.HostIP}}:{{.HostPort}}{{end}}{{end}}' 2>/dev/null)" \
      || published=""
  fi
  published="${published:-unknown}"
  echo ""
  echo -e "${YELLOW} published    ${NC}${published} -> nginx:80"
  echo -e "${YELLOW} data         ${NC}${DATA_DIR}"
  echo -e "${YELLOW} config       ${NC}${CONF_DIR}"

  local host="${published%:*}" port="${published##*:}"
  case "${host}" in ''|unknown|0.0.0.0|'[::]') host="127.0.0.1" ;; esac
  case "${port}" in ''|unknown) return 0 ;; esac

  echo ""
  echo -e "${YELLOW}------------------------------------ HEALTH --------------------------------${NC}"
  check_endpoints "${host}" "${port}"
}

# ---- Arguments ---------------------------------------------------------------
ADDMOBILEPORTAL_VERSION=""
MOBILESERVICES_VERSION=""

usage() {
  cat <<EOF
Usage: setup.sh [--add-mobileportal <version>] [--mobileservices <version>] [--latest]
       setup.sh status
       setup.sh down

Packages:
  add-mobileportal   the API server
  mobileservices     the auth verify service every gated request is checked against

Options:
  --add-mobileportal <version>   install this version of add-mobileportal
  --mobileservices <version>     install this version of mobileservices
  --latest                       install the newest published version of both (the default)
  status                         report what is running, and whether the gate is closed
  down                           remove the pod and exit
  -h, --help                     show this message

Environment (set these in your shell profile to skip the prompts):
  MOBILEAPI_PORT        host port nginx is published on          (default 8080)
  MOBILEAPI_BIND_HOST   address that port binds to               (default 127.0.0.1)
  GATEWAY_URL           ADD Security gateway, used for auth
  SERVER_NAME           public hostname; setting it renders the host nginx vhost
                        for that name without asking
  KAFKA_PORT            pod-internal port; setting it enables the broker

Running straight from the installer URL, arguments go after a "--":
  curl -fsSL ${SETUP_URL} | bash -s -- --add-mobileportal v1.0.0.32
EOF
}

require_version_value() {
  local flag="$1" value="${2:-}"
  case "$value" in
    ''|-*)
      echo -e "${ICON_THUMBSDOWN} ${RED} ${flag} needs a version -- ${flag} <version>, or ${flag} latest for the newest published.${NC}" >&2
      exit 2
      ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    down)
      teardown
      exit 0
      ;;
    status)
      status_report || exit 1
      [ "${DEGRADED}" -eq 0 ] || exit 1
      exit 0
      ;;
    --latest)
      shift
      ;;
    --add-mobileportal)
      require_version_value "$1" "${2:-}"
      ADDMOBILEPORTAL_VERSION="$2"; ADDMOBILEPORTAL_IMAGE=""
      shift 2
      ;;
    --add-mobileportal=*)
      ADDMOBILEPORTAL_VERSION="${1#*=}"; ADDMOBILEPORTAL_IMAGE=""
      require_version_value "--add-mobileportal" "${ADDMOBILEPORTAL_VERSION}"
      shift
      ;;
    --mobileservices)
      require_version_value "$1" "${2:-}"
      MOBILESERVICES_VERSION="$2"; MOBILESERVICES_IMAGE=""
      shift 2
      ;;
    --mobileservices=*)
      MOBILESERVICES_VERSION="${1#*=}"; MOBILESERVICES_IMAGE=""
      require_version_value "--mobileservices" "${MOBILESERVICES_VERSION}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo -e "${ICON_THUMBSDOWN} ${RED} Unknown argument: ${1}${NC}" >&2
      echo "" >&2
      usage >&2
      exit 2
      ;;
  esac
done

trap on_failure EXIT

# ---- Host prerequisites ------------------------------------------------------
for tool in podman curl loginctl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo -e "${ICON_THUMBSDOWN} ${RED} ${tool} is not installed.${NC}" >&2
    echo -e "${BLUE} On Ubuntu/Debian: ${GREEN}sudo apt-get install -y ${tool}${NC}" >&2
    exit 1
  fi
done

MAX_MAP_COUNT="$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)"
if [ "${MAX_MAP_COUNT}" -lt 262144 ] 2>/dev/null; then
  echo -e "${BLUE}Note: vm.max_map_count is ${MAX_MAP_COUNT}. The API accumulates memory mappings over long${NC}"
  echo -e "${BLUE}uptimes and stalls on reaching that ceiling; raising it avoids the restart:${NC}"
  echo -e "${GREEN}  echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-addmobile.conf && sudo sysctl --system${NC}"
  echo ""
fi

if ! podman info >/dev/null 2>&1; then
  echo -e "${ICON_THUMBSDOWN} ${RED} podman is installed but not working for ${USER} (rootless setup incomplete?).${NC}" >&2
  echo -e "${BLUE} Diagnose with: ${GREEN}podman info${NC}" >&2
  exit 1
fi

# Running out mid-pull leaves a partial layer and an error that reads like a network fault.
GRAPH_ROOT="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || echo "${HOME}")"
FREE_MB="$(df -Pm "${GRAPH_ROOT}" 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "${FREE_MB}" ] && [ "${FREE_MB}" -lt 2048 ] 2>/dev/null; then
  echo -e "${ICON_WARN} ${YELLOW} Only ${FREE_MB} MB free on ${GRAPH_ROOT}. More than 2 GB is recommended.${NC}"
  echo ""
fi

# ---- Everything the install needs from the operator ---------------------------
if [ -z "${MOBILEAPI_PORT}" ]; then
  echo -e "${ICON_TIP} ${BLUE} \nTip: Set the environment variable MOBILEAPI_PORT during login ${GREEN}(e.g. ~/.bashrc, ~/.cshrc, ~/.zshrc)${BLUE} so you don't have to enter it here.${NC}"
  echo ""
  read -r -p "PORT (default: 8080): " MOBILEAPI_PORT < /dev/tty
  MOBILEAPI_PORT="${MOBILEAPI_PORT:-8080}"
  echo ""
fi

case "${MOBILEAPI_PORT}" in
  ''|*[!0-9]*)
    echo -e "${ICON_THUMBSDOWN} ${RED} MOBILEAPI_PORT must be a number, got '${MOBILEAPI_PORT}'.${NC}" >&2
    exit 2
    ;;
esac
if [ "${MOBILEAPI_PORT}" -lt 1 ] || [ "${MOBILEAPI_PORT}" -gt 65535 ]; then
  echo -e "${ICON_THUMBSDOWN} ${RED} MOBILEAPI_PORT must be between 1 and 65535, got ${MOBILEAPI_PORT}.${NC}" >&2
  exit 2
fi
if [ "${MOBILEAPI_PORT}" -lt 1024 ]; then
  echo -e "${ICON_WARN} ${YELLOW} Ports below 1024 need net.ipv4.ip_unprivileged_port_start lowered before rootless podman can bind them.${NC}" >&2
fi

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    [ -n "$(ss -Hltn "sport = :${port}" 2>/dev/null)" ] && return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END{exit !found}' && return 0
  fi
  return 1
}
if ! podman pod exists "${POD_NAME}" && port_in_use "${MOBILEAPI_PORT}"; then
  echo -e "${ICON_THUMBSDOWN} ${RED} Port ${MOBILEAPI_PORT} is already in use by something else on this host.${NC}" >&2
  echo -e "${BLUE} Free it, or pick another with ${GREEN}MOBILEAPI_PORT=<port>${BLUE}. Listening now:${NC}" >&2
  (ss -ltnp "sport = :${MOBILEAPI_PORT}" 2>/dev/null || netstat -ltnp 2>/dev/null) | sed 's/^/   /' >&2
  exit 2
fi

if [ -z "${GATEWAY_URL}" ]; then
  echo ""
  echo -e "${ICON_WARN} ${YELLOW} GATEWAY_URL is not set.${NC}"
  echo ""
  echo -e "${ICON_TIP} ${BLUE} Tip: Set the environment variable GATEWAY_URL during login ${GREEN}(e.g. ~/.bashrc, ~/.cshrc, ~/.zshrc)${BLUE} so you don't have to enter it here.${NC}"
  echo ""
  read -r -p "Enter GATEWAY_URL (i.e. https://<gateway>.<yourdomain>:39079): " GATEWAY_URL < /dev/tty
fi

case "${GATEWAY_URL}" in
  http://*|https://*) ;;
  '')
    echo -e "${ICON_THUMBSDOWN} ${RED} GATEWAY_URL is required.${NC}" >&2
    exit 2
    ;;
  *)
    echo -e "${ICON_THUMBSDOWN} ${RED} GATEWAY_URL needs a scheme, got '${GATEWAY_URL}'.${NC}" >&2
    echo -e "${BLUE} For example: ${GREEN}https://${GATEWAY_URL}${NC}" >&2
    exit 2
    ;;
esac

if [ -n "${KAFKA_PORT}" ]; then
  case "${KAFKA_PORT}" in
    *[!0-9]*)
      echo -e "${ICON_THUMBSDOWN} ${RED} KAFKA_PORT must be a number, got '${KAFKA_PORT}'.${NC}" >&2
      echo -e "${BLUE} Leave it unset to run without Kafka, or give it a port, e.g. ${GREEN}KAFKA_PORT=9092${NC}" >&2
      exit 2
      ;;
  esac
  if [ "${KAFKA_PORT}" -lt 1 ] || [ "${KAFKA_PORT}" -gt 65535 ]; then
    echo -e "${ICON_THUMBSDOWN} ${RED} KAFKA_PORT must be between 1 and 65535, got ${KAFKA_PORT}.${NC}" >&2
    exit 2
  fi
  if [ "${KAFKA_PORT}" = "9093" ]; then
    echo -e "${ICON_THUMBSDOWN} ${RED} KAFKA_PORT 9093 is reserved: the broker keeps it for its own controller listener.${NC}" >&2
    echo -e "${BLUE} Pick another, e.g. ${GREEN}KAFKA_PORT=9092${NC}" >&2
    exit 2
  fi

  KAFKA_BROKERS="127.0.0.1:${KAFKA_PORT}"
fi

# ---- Host nginx vhost: offered, never assumed --------------------------------
# The pod cannot terminate TLS, so a host nginx in front of it is required either way, and
# everything needed to write that vhost is already known here
HOST_NGINX_WANTED=""

if [ -n "${SERVER_NAME}" ]; then
  HOST_NGINX_WANTED=1
elif [ -e /dev/tty ]; then
  SERVER_NAME_DEFAULT="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo '')"
  SERVER_NAME_DEFAULT="${SERVER_NAME_DEFAULT:-raven.example.com}"

  echo ""
  echo -e "${BLUE}The pod speaks plain HTTP. RavenLive and the driver devices are HTTPS-only, so an${NC}"
  echo -e "${BLUE}nginx on this host terminating TLS is required in front of it.${NC}"
  echo ""

  if [ -f "${CONF_DIR}/${SERVER_NAME_DEFAULT}.conf" ]; then
    echo -e "${ICON_TIP} ${BLUE} A vhost for ${GREEN}${SERVER_NAME_DEFAULT}${BLUE} already exists in ${CONF_DIR}.${NC}"
    echo -e "${BLUE} Regenerating replaces it, keeping the current one as a .bak file.${NC}"
    read -r -p "Regenerate it? [y/N]: " HOST_NGINX_ANSWER < /dev/tty
    case "${HOST_NGINX_ANSWER}" in [Yy]*) HOST_NGINX_WANTED=1 ;; esac
  else
    read -r -p "Write one for this host? [Y/n]: " HOST_NGINX_ANSWER < /dev/tty
    case "${HOST_NGINX_ANSWER}" in [Nn]*) ;; *) HOST_NGINX_WANTED=1 ;; esac
  fi

  if [ -n "${HOST_NGINX_WANTED}" ]; then
    read -r -p "Public hostname [${SERVER_NAME_DEFAULT}]: " SERVER_NAME < /dev/tty
    SERVER_NAME="${SERVER_NAME:-${SERVER_NAME_DEFAULT}}"
  fi
  echo ""
fi

echo -e "${YELLOW}------------------------------------ ENV -----------------------------------${NC}"
echo -e "${YELLOW} MOBILEAPI_PORT ${NC}${MOBILEAPI_BIND_HOST}:${MOBILEAPI_PORT}"
echo -e "${YELLOW} GATEWAY_URL    ${NC}${GATEWAY_URL}"
if [ -n "${HOST_NGINX_WANTED}" ]; then
  echo -e "${YELLOW} HOST NGINX     ${NC}vhost for ${SERVER_NAME}"
else
  echo -e "${YELLOW} HOST NGINX     ${NC}not generated"
fi
echo -e "${YELLOW}------------------------------------ ENV -----------------------------------${NC}"

DISCOVERY_URL="${GATEWAY_URL%/}/.well-known/openid-configuration"
STATUS_CODE="$(curl -s --connect-timeout 10 --max-time 20 \
  -o /dev/null -w "%{http_code}" "${DISCOVERY_URL}")" || STATUS_CODE="000"

if [ "$STATUS_CODE" = "200" ]; then
    echo -e "${ICON_THUMBSUP} ${GREEN} Success:${DISCOVERY_URL} returned HTTP 200 ${NC}"
else
    echo -e "${ICON_THUMBSDOWN} ${RED} Failed:${DISCOVERY_URL} returned HTTP ${STATUS_CODE} ${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}Login to ${REGISTRY_HOST}${NC}"

read -r -p "Username: " USERNAME < /dev/tty
read -r -s -p "Password: " PASSWORD < /dev/tty
echo ""

# Pass the password via stdin so it never appears in process listings
# (e.g. `ps aux`) or shell history.
if printf '%s' "${PASSWORD}" | podman login "${REGISTRY_HOST}" --username "${USERNAME}" --password-stdin; then
  echo -e "${ICON_THUMBSUP} ${GREEN} Successfully logged in to ${REGISTRY_HOST} as ${USERNAME}.${NC}"
else
  echo -e "${ICON_THUMBSDOWN} ${RED} Login to ${REGISTRY_HOST} failed.${NC}" >&2
  exit 1
fi

# ---- Resolve image tags from the registry ------------------------------------
# Credentials go in through --config on stdin, never on the command line.
registry_tags() {
  local escaped="${USERNAME}:${PASSWORD}" body
  escaped="${escaped//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"

  body="$(printf 'user = "%s"\n' "${escaped}" \
    | curl -fsS --connect-timeout 10 --max-time 30 --config - "${REGISTRY_URL}/v2/$1/tags/list" 2>/dev/null)" || return 1

  printf '%s' "${body}" \
    | tr ',' '\n' \
    | grep -oE '"v[0-9][^"]*"' \
    | tr -d '"' \
    | sort -t. -k1,1V -k2,2n -k3,3n -k4,4n

  # Normalises the trailing grep: no matching tags is an answer, not a failure.
  return 0
}

release_tags() {
  printf '%s\n' "$1" | grep -xE 'v[0-9]+(\.[0-9]+){1,3}'
}

version_below() {
  [ "$1" != "$2" ] \
    && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1V -k2,2n -k3,3n -k4,4n | head -1)" = "$1" ]
}

RESOLVED_IMAGE=""
RESOLVED_ORIGIN=""
resolve_or_die() {
  local package="$1" requested="$2" override="$3" env_name="$4" flag="$5"
  local tags releases tag

  if [ -n "$override" ]; then
    RESOLVED_IMAGE="$override"
    RESOLVED_ORIGIN="pinned in the environment"
    return 0
  fi

  if ! tags="$(registry_tags "$package")"; then
    echo -e "${ICON_THUMBSDOWN} ${RED} ${REGISTRY_HOST} did not answer for ${package}.${NC}" >&2
    echo -e "${BLUE} Check the registry is reachable and your account can read ${package},${NC}" >&2
    echo -e "${BLUE} or name a full image explicitly: ${GREEN}export ${env_name}=${REGISTRY_HOST}/${package}:<tag>${NC}" >&2
    exit 1
  fi
  if [ -z "$tags" ]; then
    echo -e "${ICON_THUMBSDOWN} ${RED} ${REGISTRY_HOST} holds no published versions of ${package}.${NC}" >&2
    echo -e "${BLUE} The registry answered, so this is an empty or unfamiliar repository rather than${NC}" >&2
    echo -e "${BLUE} a connection problem. Check the name, or name a full image explicitly:${NC}" >&2
    echo -e "${BLUE} ${GREEN}export ${env_name}=${REGISTRY_HOST}/${package}:<tag>${NC}" >&2
    exit 1
  fi

  if [ -z "$requested" ] || [ "$requested" = "latest" ]; then
    releases="$(release_tags "$tags" || true)"
    if [ -z "$releases" ]; then
      echo -e "${ICON_THUMBSDOWN} ${RED} ${package} has no plain release version published.${NC}" >&2
      echo -e "${BLUE} Every published tag is a pre-release or variant, and one of those is never${NC}" >&2
      echo -e "${BLUE} installed by default. Ask for one by name if that is what you want:${NC}" >&2
      printf '%s\n' "$tags" | tail -5 | sed 's/^/   /' >&2
      exit 1
    fi
    tag="$(printf '%s\n' "$releases" | tail -1)"
    RESOLVED_ORIGIN="latest published"
  else
    tag="v${requested#[vV]}"
    if ! printf '%s\n' "$tags" | grep -qxF "$tag"; then
      echo -e "${ICON_THUMBSDOWN} ${RED} ${package} has no published version ${tag}.${NC}" >&2
      echo -e "${BLUE} Newest published versions of ${package}:${NC}" >&2
      printf '%s\n' "$tags" | tail -5 | sed 's/^/   /' >&2
      echo -e "${BLUE} Name one with ${GREEN}${flag} <version>${BLUE}, or take the newest with ${GREEN}${flag} latest${BLUE}.${NC}" >&2
      exit 1
    fi
    RESOLVED_ORIGIN="requested"
  fi

  RESOLVED_IMAGE="${REGISTRY_HOST}/${package}:${tag}"
}

echo ""
echo -e "${BLUE}Resolving image versions...${NC}"

resolve_or_die "$PORTAL_REPO" "$ADDMOBILEPORTAL_VERSION" "$ADDMOBILEPORTAL_IMAGE" ADDMOBILEPORTAL_IMAGE --add-mobileportal
ADDMOBILEPORTAL_IMAGE="$RESOLVED_IMAGE"
ADDMOBILEPORTAL_ORIGIN="$RESOLVED_ORIGIN"

resolve_or_die "$MOBILESERVICES_REPO" "$MOBILESERVICES_VERSION" "$MOBILESERVICES_IMAGE" MOBILESERVICES_IMAGE --mobileservices
MOBILESERVICES_IMAGE="$RESOLVED_IMAGE"
MOBILESERVICES_ORIGIN="$RESOLVED_ORIGIN"

printf "${ICON_THUMBSUP} ${GREEN} %-17s %s${NC} (%s)\n" "${PORTAL_REPO}" "${ADDMOBILEPORTAL_IMAGE}" "${ADDMOBILEPORTAL_ORIGIN}"
printf "${ICON_THUMBSUP} ${GREEN} %-17s %s${NC} (%s)\n" "${MOBILESERVICES_REPO}" "${MOBILESERVICES_IMAGE}" "${MOBILESERVICES_ORIGIN}"

# The gate config is read out of the add-mobileportal image further down, so a release that
# predates that ability is refused here -- before anything is pulled or torn down -- rather
# than at the render step, where the reason would be a shrug.
PORTAL_TAG="${ADDMOBILEPORTAL_IMAGE##*:}"
case "${PORTAL_TAG}" in
  v[0-9]*)
    if version_below "${PORTAL_TAG}" "${PORTAL_MIN_VERSION}"; then
      echo -e "${ICON_THUMBSDOWN} ${RED} add-mobileportal ${PORTAL_TAG} is too old for this installer.${NC}" >&2
      echo -e "${BLUE} The nginx gate config ships inside the image and is read out of it, which${NC}" >&2
      echo -e "${BLUE} ${PORTAL_MIN_VERSION} is the first release to support.${NC}" >&2
      if [ "${ADDMOBILEPORTAL_ORIGIN}" = "latest published" ]; then
        echo -e "${BLUE} ${PORTAL_TAG} is the newest version published, so there is nothing to install${NC}" >&2
        echo -e "${BLUE} yet: ${PORTAL_MIN_VERSION} or later has to reach ${REGISTRY_HOST} first.${NC}" >&2
      else
        echo -e "${BLUE} Install ${GREEN}--add-mobileportal latest${BLUE}, or any version from ${PORTAL_MIN_VERSION} up.${NC}" >&2
      fi
      exit 1
    fi
    ;;
esac

prepare_conf_dir "${CONF_DIR}"
prepare_data_dir "${MONGODB_DIR}" "${MONGO_UID}"
if [ -n "${KAFKA_PORT}" ]; then
  prepare_data_dir "${KAFKA_DIR}" "${KAFKA_UID}"
fi

# ---- Pull every image before touching the running pod ------------------------
PULL_IMAGES=("${ADDMOBILEPORTAL_IMAGE}" "${MOBILESERVICES_IMAGE}" "${MONGO_IMAGE}" "${NGINX_IMAGE}")
[ -n "${KAFKA_PORT}" ] && PULL_IMAGES+=("${KAFKA_IMAGE}")

echo ""
echo -e "${BLUE}Pulling images...${NC}"
for image in "${PULL_IMAGES[@]}"; do
  case "${image}" in
    *@sha256:*)
      if podman image exists "${image}"; then
        echo "Present by digest: ${image}"
        continue
      fi
      ;;
    localhost/*|localhost:*)
      if podman image exists "${image}"; then
        echo "Using local override: ${image}"
        continue
      fi
      ;;
  esac
  if [[ "${image}" != */* ]] && podman image exists "${image}"; then
    echo "Using local override: ${image}"
    continue
  fi
  echo "Refreshing: ${image}"
  if ! podman pull "${image}"; then
    echo -e "${ICON_THUMBSDOWN} ${RED} Could not pull ${image}. Nothing was changed.${NC}" >&2
    exit 1
  fi
done

# ---- Which images can be restarted on a failing health check -----------------
image_has_healthcheck() {
  [ -n "$(podman image inspect "$1" \
      --format '{{if .HealthCheck}}{{range .HealthCheck.Test}}{{.}}{{end}}{{end}}' 2>/dev/null)" ]
}

PORTAL_HEALTH_KILL=""
MOBILESERVICES_HEALTH_KILL=""
image_has_healthcheck "${ADDMOBILEPORTAL_IMAGE}" && PORTAL_HEALTH_KILL=1
image_has_healthcheck "${MOBILESERVICES_IMAGE}"  && MOBILESERVICES_HEALTH_KILL=1

if [ -z "${PORTAL_HEALTH_KILL}" ] || [ -z "${MOBILESERVICES_HEALTH_KILL}" ]; then
  echo ""
  echo -e "${ICON_WARN} ${YELLOW} These images declare no health check, so a wedged process will not be restarted:${NC}"
  [ -z "${PORTAL_HEALTH_KILL}" ]         && echo -e "${BLUE}   ${ADDMOBILEPORTAL_IMAGE}${NC}"
  [ -z "${MOBILESERVICES_HEALTH_KILL}" ] && echo -e "${BLUE}   ${MOBILESERVICES_IMAGE}${NC}"
  echo -e "${BLUE} They still run, and a crash is still restarted. A newer release adds the check.${NC}"
fi

# ---- nginx config ------------------------------------------------------------
echo ""
echo -e "${BLUE}Rendering nginx config (${CONF_DIR}/nginx.conf)...${NC}"
if ! podman run --rm "${ADDMOBILEPORTAL_IMAGE}" --print-nginx-conf > "${CONF_DIR}/nginx.conf.template" 2>/dev/null \
   || [ ! -s "${CONF_DIR}/nginx.conf.template" ]; then
  rm -f "${CONF_DIR}/nginx.conf.template"
  echo -e "${ICON_THUMBSDOWN} ${RED} ${ADDMOBILEPORTAL_IMAGE} could not print its nginx template.${NC}" >&2
  echo -e "${BLUE} Every release from ${PORTAL_MIN_VERSION} answers --print-nginx-conf. An image that does not${NC}" >&2
  echo -e "${BLUE} is either older than that or not an add-mobileportal image at all -- check any${NC}" >&2
  echo -e "${BLUE} ADDMOBILEPORTAL_IMAGE set in the environment, or install ${GREEN}--add-mobileportal latest${BLUE}.${NC}" >&2
  echo -e "${BLUE} The running pod, if any, is untouched -- nothing is removed until after this step.${NC}" >&2
  exit 1
fi

sed -e "s|__ADDMOBILEPORTAL_PORT__|${ADDMOBILEPORTAL_PORT}|g" \
    -e "s|__MOBILESERVICES_PORT__|${MOBILESERVICES_PORT}|g" \
    "${CONF_DIR}/nginx.conf.template" > "${CONF_DIR}/nginx.conf.new"
mv "${CONF_DIR}/nginx.conf.new" "${CONF_DIR}/nginx.conf"
rm -f "${CONF_DIR}/nginx.conf.template"
chmod 644 "${CONF_DIR}/nginx.conf"

# Past this point a failure leaves a half-built pod rather than the previous one.
POD_TOUCHED=1
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
if [ -z "${KAFKA_PORT}" ]; then
  echo ">> Kafka disabled (KAFKA_PORT empty) -- skipping the broker container."
else
echo ">> Starting kafka on ${KAFKA_BROKERS}..."

podman run -d \
  --pod "${POD_NAME}" \
  --name kafka \
  --restart always \
  --stop-timeout 30 \
  --memory 1g --memory-swap 1g \
  --volume "${KAFKA_DIR}:/var/lib/kafka/data${VOLUME_SUFFIX}" \
  --env KAFKA_LOG_DIRS=/var/lib/kafka/data \
  --env KAFKA_NODE_ID=1 \
  --env KAFKA_PROCESS_ROLES=broker,controller \
  --env "KAFKA_LISTENERS=PLAINTEXT://127.0.0.1:${KAFKA_PORT},CONTROLLER://127.0.0.1:9093" \
  --env "KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://${KAFKA_BROKERS}" \
  --env KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
  --env KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT \
  --env KAFKA_CONTROLLER_QUORUM_VOTERS=1@127.0.0.1:9093 \
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
  --health-cmd "mongosh --quiet --eval 'db.runCommand({ping:1}).ok' || exit 1" \
  --health-interval 30s \
  --health-retries 5 \
  --health-start-period 120s \
  --health-on-failure=kill \
  --stop-timeout 60 \
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
  ${MOBILESERVICES_HEALTH_KILL:+--health-on-failure=kill} \
  --memory 512m --memory-swap 512m \
  "${MOBILESERVICES_ENV_FLAGS[@]}" \
  "${MOBILESERVICES_IMAGE}"

# ---- 5. ADD-MOBILEPORTAL (API, pod-internal) --------------------------------
echo ">> Starting ADD-MOBILEPORTAL..."
podman run -d \
  --pod "${POD_NAME}" \
  --name add-mobileportal \
  --restart always \
  ${PORTAL_HEALTH_KILL:+--health-on-failure=kill} \
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
  --health-cmd "wget -q -O /dev/null http://127.0.0.1:80/health || exit 1" \
  --health-interval 30s \
  --health-retries 3 \
  --health-start-period 10s \
  --health-on-failure=kill \
  "${NGINX_IMAGE}"

# ---- 7. Prove the stack answers before declaring success --------------------
echo ""
check_endpoints "127.0.0.1" "${MOBILEAPI_PORT}" 30

echo -e ">> Pod status:${GREEN}"
podman pod ps
podman ps --pod
echo -e "${NC}"

# ---- 8. Survive a reboot -----------------------------------------------------
enable_reboot_persistence() {
  local err linger

  linger="$(loginctl show-user "$USER" --property=Linger --value 2>/dev/null || echo unknown)"
  if [ "$linger" != "yes" ]; then
    if loginctl enable-linger "$USER" 2>/dev/null; then
      echo -e "${GREEN}Linger enabled for $USER.${NC}"
    else
      echo -e "${ICON_WARN} ${YELLOW} Linger is OFF and could not be enabled -- the pod will die on logout/reboot.${NC}"
      echo -e "${BLUE} Run: ${GREEN}sudo loginctl enable-linger $USER${NC}"
    fi
  fi

  systemctl --user is-system-running >/dev/null 2>&1 || sleep 2

  if err="$(systemctl --user enable podman-restart.service 2>&1)" \
     && systemctl --user is-enabled podman-restart.service >/dev/null 2>&1; then
    echo -e "${ICON_THUMBSUP} ${GREEN} podman-restart enabled -- the pod comes back after a reboot.${NC}"
    return 0
  fi

  echo -e "${ICON_WARN} ${YELLOW} Could not enable podman-restart.service; containers will not come back after a reboot.${NC}"
  if [ -n "${err}" ]; then
    echo -e "${BLUE} systemd said:${NC}"
    printf '%s\n' "${err}" | sed 's/^/   /'
  fi
  echo -e "${BLUE} Fix it from a login shell on this host with:${NC}"
  echo -e "${GREEN}  systemctl --user enable --now podman-restart.service${NC}"
  return 1
}
enable_reboot_persistence || true

podman logout "${REGISTRY_HOST}" >/dev/null 2>&1 || true
unset PASSWORD USERNAME

if [ "$DEGRADED" -ne 0 ]; then
  echo ""
  echo -e "${RED}The pod is running but INCOMPLETE.${NC}"
  echo -e "${BLUE}Tear it down with:${NC}"
  echo -e "${GREEN}  ${UNINSTALL_CMD}${NC}"
  echo ""
  exit 1
fi

# ---- 9. Render the host nginx vhost -----------------------------------------
HOST_NGINX_READY=0
if [ -n "${HOST_NGINX_WANTED}" ]; then
  if curl -fsSL --connect-timeout 10 --max-time 60 \
       "${HOST_NGINX_URL}" -o "${CONF_DIR}/host-nginx.sh" 2>/dev/null \
     && [ -s "${CONF_DIR}/host-nginx.sh" ]; then
    chmod 755 "${CONF_DIR}/host-nginx.sh"
    if bash "${CONF_DIR}/host-nginx.sh" --render \
         --server-name "${SERVER_NAME}" \
         --port "${MOBILEAPI_PORT}" \
         --out-dir "${CONF_DIR}" >/dev/null 2>&1; then
      HOST_NGINX_READY=1
    fi
  fi
fi

echo ""
echo -e "${YELLOW}---------------------------------- INSTALLED -------------------------------${NC}"
printf "${YELLOW} %-16s${NC}%s\n" "add-mobileportal" "${ADDMOBILEPORTAL_IMAGE}"
printf "${YELLOW} %-16s${NC}%s\n" "mobileservices"   "${MOBILESERVICES_IMAGE}"
printf "${YELLOW} %-16s${NC}%s\n" "kafka"            "${KAFKA_PORT:+enabled on ${KAFKA_BROKERS}}${KAFKA_PORT:-disabled}"
printf "${YELLOW} %-16s${NC}%s\n" "listening"        "http://${MOBILEAPI_BIND_HOST}:${MOBILEAPI_PORT}"
printf "${YELLOW} %-16s${NC}%s\n" "data"             "${DATA_DIR}"
printf "${YELLOW} %-16s${NC}%s\n" "config"           "${CONF_DIR}"
echo -e "${YELLOW}----------------------------------------------------------------------------${NC}"

echo ""
echo -e "${BLUE}Useful from here:${NC}"
echo -e "${GREEN}  curl -fsSL ${SETUP_URL} | bash -s -- status${NC}   what is running, and is the gate closed"
echo -e "${GREEN}  podman logs -f add-mobileportal${NC}"
echo -e "${GREEN}  ${UNINSTALL_CMD}${NC}"

# ---- Next steps -------------------------------------------------------------
echo ""
echo -e "${YELLOW}--------------------------------- NEXT STEPS -------------------------------${NC}"
echo ""
echo -e "${BLUE}1. Put nginx in front of this. The pod speaks plain HTTP on ${MOBILEAPI_BIND_HOST} only;${NC}"
echo -e "${BLUE}   RavenLive and the driver devices are HTTPS-only and cannot reach it as it stands.${NC}"
if [ "${HOST_NGINX_READY}" -eq 1 ]; then
  echo ""
  echo -e "${BLUE}   A vhost for ${GREEN}${SERVER_NAME}${BLUE} on port ${GREEN}${MOBILEAPI_PORT}${BLUE} has been written for you:${NC}"
  echo -e "${GREEN}     ${CONF_DIR}/${SERVER_NAME}.conf${NC}"
  echo -e "${GREEN}     ${CONF_DIR}/raven-upgrade.conf${NC}"
  echo ""
  echo -e "${BLUE}   Point it at your certificate and install both, or let the script do it:${NC}"
  echo -e "${GREEN}     sudo ${CONF_DIR}/host-nginx.sh --server-name ${SERVER_NAME} --port ${MOBILEAPI_PORT} \\${NC}"
  echo -e "${GREEN}          --cert /etc/nginx/ssl/${SERVER_NAME}/fullchain.pem \\${NC}"
  echo -e "${GREEN}          --key  /etc/nginx/ssl/${SERVER_NAME}/privkey.pem${NC}"
  echo ""
  echo -e "${BLUE}   It tests the config before reloading and rolls back if nginx refuses it.${NC}"
else
  echo ""
  echo -e "${BLUE}   Get the generator and run it on the host whenever you want one:${NC}"
  echo -e "${GREEN}     curl -fsSL ${HOST_NGINX_URL} | sudo bash -s -- \\${NC}"
  echo -e "${GREEN}          --server-name ${SERVER_NAME:-<your-hostname>} --port ${MOBILEAPI_PORT} \\${NC}"
  echo -e "${GREEN}          --cert <fullchain.pem> --key <privkey.pem>${NC}"
  echo ""
  echo -e "${BLUE}   Add ${GREEN}--print${BLUE} to see the files without writing anything, or write your own${NC}"
  echo -e "${BLUE}   from the reference vhost in host-nginx.md.${NC}"
fi
