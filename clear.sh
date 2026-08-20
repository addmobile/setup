#! /bin/bash

POD_NAME="mobile-pod"

if ! podman pod exists "${POD_NAME}"; then
  echo "Pod '${POD_NAME}' does not exist; nothing to remove."
  exit 0
fi

POD_ANON_VOLUMES=()
for container in kafka mongodb mobileservices add-mobileportal nginx; do
  if podman container exists "${container}"; then
    while read -r volume; do
      [ -n "${volume}" ] && POD_ANON_VOLUMES+=("${volume}")
    done < <(podman inspect "${container}" \
      --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null)
  fi
done

podman pod stop "${POD_NAME}" 2>/dev/null
podman pod rm -f "${POD_NAME}"

for volume in "${POD_ANON_VOLUMES[@]}"; do
  if [[ "${volume}" =~ ^[0-9a-f]{64}$ ]]; then
    podman volume rm "${volume}" >/dev/null 2>&1 || true
  fi
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
