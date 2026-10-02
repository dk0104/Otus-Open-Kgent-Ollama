#!/usr/bin/env bash
# Build a kindest/node image with the ZFS userspace tooling added.
#
# Why: on hosts whose Docker data directory lives on ZFS (for example a ZFS
# root such as CachyOS/Arch/NixOS on ZFS), the kind node's /var volume and the
# /etc/{hostname,hosts,resolv.conf} + /lib/modules bind mounts are fstype=zfs.
#
# cadvisor (vendored by the kubelet) has a zfs plugin that shells out to
# `zfs list`; in the released cadvisor used by Kubernetes <= 1.37 there is no
# fallback when the binary is missing, so kubelet crashes with:
#
#   "failed to get rootfs info: cannot find filesystem info for device ..."
#
# Installing zfsutils-linux in the node image makes cadvisor's zfs plugin work.
#
# Usage:
#   ./scripts/build-node-image.sh
#   KIND_NODE_IMAGE=kindest/node:v1.37.0-zfs make up

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd docker

# Derive the patched tag from the pinned KIND_NODE_IMAGE, e.g.
#   kindest/node:v1.37.0  ->  kindest/node:v1.37.0-zfs
patched="${KIND_NODE_IMAGE}-zfs"

if docker image inspect "$patched" >/dev/null 2>&1; then
  ok "image '${patched}' already exists; skipping build"
  info "run: KIND_NODE_IMAGE=${patched} make up"
  exit 0
fi

info "building ZFS-patched node image '${patched}' from '${KIND_NODE_IMAGE}'"
docker build -t "$patched" - <<EOF
FROM ${KIND_NODE_IMAGE}
RUN sed -i 's/Components: main/Components: main contrib/' /etc/apt/sources.list.d/debian.sources && apt-get update && apt-get install -y --no-install-recommends zfsutils-linux && rm -rf /var/lib/apt/lists/*
EOF

ok "built '${patched}'"
info "run: KIND_NODE_IMAGE=${patched} make up"
