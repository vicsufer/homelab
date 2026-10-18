#!/bin/sh
# Render one machine config per node into _out/ (gitignored).
# Layers: talosctl defaults <- patches/common <- patches/<role> <- nodes/<role>/<node>.yaml
set -eu
cd "$(dirname "$0")"

CLUSTER=homelab
ENDPOINT=https://192.168.1.40:6443
# Keep in sync with the running cluster (`talosctl version`, `kubectl version`)
TALOS_VERSION=v1.10.2
K8S_VERSION=1.33.0

[ -f secrets.yaml ] || { echo "secrets.yaml missing (kept out of git, see README)" >&2; exit 1; }

# --config-patch<flag>=@file for every patch in a directory
patch_args() { for f in "$1"/*.yaml; do printf -- '--config-patch%s=@%s ' "$2" "$f"; done; }

rm -rf _out
talosctl gen config "$CLUSTER" "$ENDPOINT" \
  --with-secrets secrets.yaml \
  --talos-version "$TALOS_VERSION" \
  --kubernetes-version "$K8S_VERSION" \
  --with-docs=false --with-examples=false \
  $(patch_args patches/common "") \
  $(patch_args patches/controlplane -control-plane) \
  $(patch_args patches/worker -worker) \
  --output _out

for role in controlplane worker; do
  for node in nodes/$role/*.yaml; do
    name=$(basename "$node" .yaml)
    talosctl machineconfig patch "_out/$role.yaml" --patch @"$node" --output "_out/$name.yaml"
    echo "rendered _out/$name.yaml ($role)"
  done
done
