#!/usr/bin/env bash

set -euo pipefail

POD_NAME="mobile-pod"

case "${1:-}" in
  "") ;;
  -h|--help)
    echo "Usage: clear.sh"
    echo "Removes the mobile-pod and its transient volumes; host data and config are kept."
    exit 0
    ;;
  *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac

command -v podman >/dev/null 2>&1 || { echo "podman is required" >&2; exit 1; }

if ! podman pod exists "${POD_NAME}"; then
  echo "Pod '${POD_NAME}' does not exist; nothing to remove."
  exit 0
fi

POD_ANON_VOLUMES=()
while IFS= read -r container; do
  [ -n "${container}" ] || continue
  while IFS= read -r volume; do
    [[ "${volume}" =~ ^[0-9a-f]{64}$ ]] && POD_ANON_VOLUMES+=("${volume}")
  done < <(podman inspect "${container}" \
    --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null)
done < <(podman ps -aq --filter "pod=${POD_NAME}")

podman pod rm --force "${POD_NAME}"

for volume in "${POD_ANON_VOLUMES[@]}"; do
  podman volume rm "${volume}" >/dev/null 2>&1 || true
done

podman volume rm mongo-configdb 2>/dev/null || true

echo "Removed '${POD_NAME}'."
echo ""
echo "Data is kept in ~/ADD_MOBILE/data (mongo, and kafka when it was enabled) and the rendered"
echo "config in ~/ADD_MOBILE/conf. To reclaim the space:"
echo ""
echo "  podman unshare rm -rf ~/ADD_MOBILE/data"
echo "  rm -rf ~/ADD_MOBILE/conf"
echo ""
echo "The data directories are owned by a container uid rather than by you, so they need the"
echo "'podman unshare' form -- a plain rm -rf reports permission denied on them."
