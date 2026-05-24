#!/bin/bash
set -euo pipefail

if command -v k3s >/dev/null 2>&1; then
  echo "k3s is already installed."
  exit 0
fi

if [[ -n "${K3S_VERSION}" ]]; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -
else
  curl -sfL https://get.k3s.io | sh -
fi

chmod 644 /etc/rancher/k3s/k3s.yaml