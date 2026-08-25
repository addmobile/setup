#!/usr/bin/env bash
#
# Renders and optionally installs host nginx

set -euo pipefail

SERVER_NAME=""
PORT=""
UPSTREAM_HOST="127.0.0.1"
CERT=""
KEY=""
MAX_BODY="10m"
OUT_DIR=""
RENDER_ONLY=0
NO_REDIRECT=0
PRINT_ONLY=0
NGINX_DIR="${NGINX_DIR:-/etc/nginx}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# The map lives in its own file rather than inside the vhost, and its variable is prefixed.
UPGRADE_FILE="raven-upgrade.conf"

usage() {
  cat <<EOF
Usage: host-nginx.sh --server-name <fqdn> --port <mobileapi-port> [options]

Required:
  --server-name <fqdn>     hostname the clients connect to
  --port <port>            MOBILEAPI_PORT the pod publishes (host side)

Certificate (required unless --print / --render):
  --cert <path>            fullchain PEM
  --key <path>             private key PEM

Options:
  --upstream <host>        where the pod is published        (default 127.0.0.1)
  --max-body <size>        client_max_body_size              (default 10m)
  --no-redirect            skip the port 80 -> 443 redirect server
  --out-dir <dir>          write the files here instead of into ${NGINX_DIR}
  --render                 write the files, but do not enable, test or reload
  --print                  write the files to stdout and stop
  -h, --help               show this message

Installing (neither --print nor --render) needs root: it writes into ${NGINX_DIR}, runs
"nginx -t", and reloads. If nginx refuses the config, every file this script touched is
put back the way it was and nothing is reloaded.
EOF
}

die() {
  echo -e "${RED}${*}${NC}" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --server-name)  SERVER_NAME="${2:-}"; shift 2 ;;
    --server-name=*) SERVER_NAME="${1#*=}"; shift ;;
    --port)         PORT="${2:-}"; shift 2 ;;
    --port=*)       PORT="${1#*=}"; shift ;;
    --upstream)     UPSTREAM_HOST="${2:-}"; shift 2 ;;
    --upstream=*)   UPSTREAM_HOST="${1#*=}"; shift ;;
    --cert)         CERT="${2:-}"; shift 2 ;;
    --cert=*)       CERT="${1#*=}"; shift ;;
    --key)          KEY="${2:-}"; shift 2 ;;
    --key=*)        KEY="${1#*=}"; shift ;;
    --max-body)     MAX_BODY="${2:-}"; shift 2 ;;
    --max-body=*)   MAX_BODY="${1#*=}"; shift ;;
    --out-dir)      OUT_DIR="${2:-}"; shift 2 ;;
    --out-dir=*)    OUT_DIR="${1#*=}"; shift ;;
    --no-redirect)  NO_REDIRECT=1; shift ;;
    --render)       RENDER_ONLY=1; shift ;;
    --print)        PRINT_ONLY=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    --)             shift ;;
    *)              echo "Unknown argument: $1" >&2; echo "" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "${SERVER_NAME}" ] || die "--server-name is required."
[ -n "${PORT}" ]        || die "--port is required (the MOBILEAPI_PORT the pod publishes)."
case "${PORT}" in
  ''|*[!0-9]*) die "--port must be a number, got '${PORT}'." ;;
esac
case "${SERVER_NAME}" in
  *[!a-zA-Z0-9.-]*|-*|.*) die "--server-name does not look like a hostname: '${SERVER_NAME}'." ;;
esac

INSTALLING=1
if [ "${RENDER_ONLY}" -eq 1 ] || [ "${PRINT_ONLY}" -eq 1 ]; then
  INSTALLING=0
fi

if [ "${INSTALLING}" -eq 1 ]; then
  [ "$(id -u)" -eq 0 ] || die "Installing writes to ${NGINX_DIR} and reloads nginx -- run this with sudo, or use --render to just write the files."
  [ -n "${CERT}" ] || die "--cert is required when installing. Use --render to write the files without one."
  [ -n "${KEY}" ]  || die "--key is required when installing. Use --render to write the files without one."
  [ -r "${CERT}" ] || die "Certificate not readable: ${CERT}"
  [ -r "${KEY}" ]  || die "Private key not readable: ${KEY}"
  command -v nginx >/dev/null 2>&1 || die "nginx is not installed on this host."
fi

# Rendered even when no certificate was named, so --print produces a complete file with an
# obvious placeholder rather than a hole.
CERT_PATH="${CERT:-/etc/nginx/ssl/${SERVER_NAME}/fullchain.pem}"
KEY_PATH="${KEY:-/etc/nginx/ssl/${SERVER_NAME}/privkey.pem}"

render_upgrade_map() {
  cat <<EOF
# Managed by ADD Mobile host-nginx.sh -- shared by every ADD Mobile vhost on this host.
#
# \`map\` is http-context, so this declares a variable for the whole server. nginx accepts
# the same variable being mapped more than once without complaint and simply lets the last
# declaration win, which makes a duplicate with a different body a silent, host-wide change
# that "nginx -t" will not catch. Hence one file, and a prefixed name that will not collide
# with the \$connection_upgrade another application on this host may already have.
map \$http_upgrade \$raven_connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
}

render_vhost() {
  if [ "${NO_REDIRECT}" -eq 0 ]; then
    cat <<EOF
# Managed by ADD Mobile host-nginx.sh

server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAME};

    # 308 rather than 301/302: those turn a device's snapshot POST into a bodyless GET, and
    # the payload is then lost behind a 2xx nobody looks at twice.
    return 308 https://\$host\$request_uri;
}

EOF
  else
    echo "# Managed by ADD Mobile host-nginx.sh"
    echo ""
  fi

  cat <<EOF
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${SERVER_NAME};

    ssl_certificate     ${CERT_PATH};
    ssl_certificate_key ${KEY_PATH};

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;

    ssl_prefer_server_ciphers off;

    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    client_max_body_size ${MAX_BODY};

    location / {
        proxy_pass         http://${UPSTREAM_HOST}:${PORT};
        proxy_http_version 1.1;

        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;

        # WebSocket. Without these the app looks healthy and the live map never updates.
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection \$raven_connection_upgrade;

        # Sockets are long-lived; the 60s defaults would drop them.
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        proxy_buffering    off;

        proxy_set_header   RAVEN-USER      "";
        proxy_set_header   RAVEN-DATABASES "";
    }
}
EOF
}

if [ "${PRINT_ONLY}" -eq 1 ]; then
  echo "# ======== ${UPGRADE_FILE}  (goes in conf.d, one per host) ========"
  render_upgrade_map
  echo ""
  echo "# ======== ${SERVER_NAME}.conf  (goes in sites-available, or conf.d on RHEL) ========"
  render_vhost
  exit 0
fi

# ---- Where the files go ------------------------------------------------------
# Debian and RHEL disagree about this and both layouts are in the field, so detect rather
# than assume. --out-dir short-circuits the whole question for the render-only case.
if [ -n "${OUT_DIR}" ]; then
  LAYOUT="flat"
  VHOST_DIR="${OUT_DIR}"
  MAP_DIR="${OUT_DIR}"
  ENABLED_DIR=""
elif [ -d "${NGINX_DIR}/sites-available" ]; then
  LAYOUT="debian"
  VHOST_DIR="${NGINX_DIR}/sites-available"
  MAP_DIR="${NGINX_DIR}/conf.d"
  ENABLED_DIR="${NGINX_DIR}/sites-enabled"
elif [ -d "${NGINX_DIR}/conf.d" ]; then
  LAYOUT="rhel"
  VHOST_DIR="${NGINX_DIR}/conf.d"
  MAP_DIR="${NGINX_DIR}/conf.d"
  ENABLED_DIR=""
else
  die "Could not find ${NGINX_DIR}/sites-available or ${NGINX_DIR}/conf.d -- is nginx installed here? Point at it with NGINX_DIR=/path, or render only with --print --out-dir <dir>."
fi

mkdir -p "${VHOST_DIR}" "${MAP_DIR}"
VHOST_PATH="${VHOST_DIR}/${SERVER_NAME}.conf"
MAP_PATH="${MAP_DIR}/${UPGRADE_FILE}"

# ---- Back up anything we are about to replace --------------------------------
STAMP="$(date +%Y%m%d%H%M%S)"
BACKUPS=()
TOUCHED=()

backup_and_write() {
  local path="$1" content="$2"
  if [ -f "${path}" ]; then
    if [ "$(cat "${path}")" = "${content}" ]; then
      echo -e "${BLUE}   unchanged  ${NC}${path}"
      return 0
    fi
    cp -p "${path}" "${path}.bak.${STAMP}"
    BACKUPS+=("${path}")
    echo -e "${YELLOW}   replaced   ${NC}${path} ${BLUE}(previous kept as ${path}.bak.${STAMP})${NC}"
  else
    TOUCHED+=("${path}")
    echo -e "${GREEN}   wrote      ${NC}${path}"
  fi
  printf '%s\n' "${content}" > "${path}"
  chmod 644 "${path}"
}

restore() {
  local path
  for path in "${BACKUPS[@]:-}"; do
    [ -n "${path}" ] && mv -f "${path}.bak.${STAMP}" "${path}"
  done
  for path in "${TOUCHED[@]:-}"; do
    [ -n "${path}" ] && rm -f "${path}"
  done
}

echo -e "${BLUE}Rendering for ${GREEN}${SERVER_NAME}${BLUE} -> ${UPSTREAM_HOST}:${PORT} (${LAYOUT} layout)${NC}"

if [ "${LAYOUT}" != "flat" ] \
   && grep -rlF 'raven_connection_upgrade' "${NGINX_DIR}" 2>/dev/null \
      | grep -qvF "${MAP_PATH}"; then
  echo -e "${YELLOW}   note       ${NC}\$raven_connection_upgrade is already declared elsewhere under ${NGINX_DIR};"
  echo -e "${BLUE}              leaving ${MAP_PATH} alone rather than declaring it twice.${NC}"
else
  backup_and_write "${MAP_PATH}" "$(render_upgrade_map)"
fi

backup_and_write "${VHOST_PATH}" "$(render_vhost)"

if [ "${RENDER_ONLY}" -eq 1 ]; then
  echo ""
  echo -e "${GREEN}Rendered, nothing installed.${NC}"
  echo -e "${BLUE}Point the vhost at your certificate, then install both files and reload nginx.${NC}"
  exit 0
fi

# ---- Enable, test, reload ----------------------------------------------------
if [ -n "${ENABLED_DIR}" ]; then
  mkdir -p "${ENABLED_DIR}"
  if [ ! -e "${ENABLED_DIR}/${SERVER_NAME}.conf" ]; then
    ln -s "${VHOST_PATH}" "${ENABLED_DIR}/${SERVER_NAME}.conf"
    TOUCHED+=("${ENABLED_DIR}/${SERVER_NAME}.conf")
    echo -e "${GREEN}   enabled    ${NC}${ENABLED_DIR}/${SERVER_NAME}.conf"
  fi
fi

echo ""
echo -e "${BLUE}Testing the config...${NC}"
if ! NGINX_TEST_OUTPUT="$(nginx -t 2>&1)"; then
  echo -e "${RED}nginx rejected the configuration. Nothing has been reloaded and every file this${NC}" >&2
  echo -e "${RED}script touched has been put back.${NC}" >&2
  echo "" >&2
  printf '%s\n' "${NGINX_TEST_OUTPUT}" | sed 's/^/   /' >&2
  restore
  exit 1
fi
echo -e "${GREEN}   config OK${NC}"

echo -e "${BLUE}Reloading nginx...${NC}"
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
  systemctl reload nginx
elif ! nginx -s reload 2>/dev/null; then
  echo -e "${YELLOW}   nginx does not appear to be running; start it with: systemctl start nginx${NC}"
fi

# ---- Prove it works ----------------------------------------------------------
echo ""
echo -e "${BLUE}Checking ${SERVER_NAME}...${NC}"

# curl already prints 000 through -w when it cannot connect, so a "|| echo 000" fallback
# would append a second one and report "000000". Default the empty case instead.
probe() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "$@" 2>/dev/null)" || true
  printf '%s' "${code:-000}"
}

check() {
  local label="$1" expect="$2" got="$3"
  if [ "${got}" = "${expect}" ]; then
    echo -e "${GREEN}   ok         ${NC}${label} (${got})"
  elif [ "${got}" = "000" ]; then
    echo -e "${YELLOW}   check      ${NC}${label}: no answer (expected ${expect})"
  else
    echo -e "${YELLOW}   check      ${NC}${label}: expected ${expect}, got ${got}"
  fi
}

check "pod answers behind the proxy" "200" \
  "$(probe --max-time 5 "http://${UPSTREAM_HOST}:${PORT}/health")"

check "TLS terminates and /version is reachable" "200" \
  "$(probe --max-time 10 "https://${SERVER_NAME}/version")"

# 401 is the pass: it means the request reached the pod's gate and the gate refused it.
check "unauthenticated requests are refused" "401" \
  "$(probe --max-time 10 -X POST -H 'Content-Type: application/json' \
       -d '{"query":"{__typename}"}' "https://${SERVER_NAME}/api/graphql")"

# 400 or 426 here means the upgrade headers are not being proxied; 401 means they are and
# the gate did its job.
check "WebSocket upgrade is proxied" "401" \
  "$(probe --max-time 10 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
       -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
       "https://${SERVER_NAME}/socket.io/?EIO=4&transport=websocket")"

echo ""
echo -e "${GREEN}Done.${NC}"
echo -e "${BLUE}  vhost  ${NC}${VHOST_PATH}"
echo -e "${BLUE}  map    ${NC}${MAP_PATH}"
