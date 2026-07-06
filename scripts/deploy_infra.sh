#!/bin/bash
# scripts/deploy_infra.sh
# This script manages the core infrastructure services independently of the application logic.

set -e

KUBECONFIG_PATH=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
export KUBECONFIG=$KUBECONFIG_PATH

echo "Using KUBECONFIG: $KUBECONFIG"

# 1. Add Helm Repositories
echo "Updating Helm repositories..."
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# 2. Create Common Namespace
echo "Ensuring 'common' namespace exists..."
kubectl create namespace common --dry-run=client -o yaml | kubectl apply -f -

# 3. Apply GHCR Auth
# Note: The manifest is an Ansible Jinja2 template. We render it using sed.
if [ -f "kubernetes/common/ghcr-auth.yaml" ]; then
    echo "Rendering and applying GHCR Auth to common namespace..."
    sed -e 's/{{ namespace }}/common/g' \
        -e "s/{{ '{{' }}/{{/g" \
        -e "s/{{ '}}' }}/}}/g" \
        kubernetes/common/ghcr-auth.yaml | kubectl apply -f -
else
    echo "Warning: kubernetes/common/ghcr-auth.yaml not found. Skipping."
fi

# 4. Deploy Infrastructure via Helm
echo "Deploying Vault..."
# Persistent (file-backed) storage — dev mode wipes all secrets/policies on every
# pod restart since it's in-memory only. Vault comes up sealed/uninitialized after
# a fresh install; see docs/vault_kubernetes_guide.md for the init/unseal steps.
helm upgrade --install vault hashicorp/vault \
    --namespace common \
    --set server.dev.enabled=false \
    --set server.dataStorage.enabled=true \
    --set server.dataStorage.size=1Gi \
    --set server.dataStorage.storageClass=local-path

echo "Deploying Loki..."
helm upgrade --install loki grafana/loki \
    --namespace common \
    -f kubernetes/common/loki-values.yml

echo "Deploying Promtail..."
helm upgrade --install promtail grafana/promtail \
    --namespace common \
    --set config.clients[0].url=http://loki-gateway.common.svc.cluster.local/loki/api/v1/push

echo "Deploying Grafana..."
helm upgrade --install grafana grafana/grafana \
    --namespace common \
    -f kubernetes/common/grafana-values.yml

# 5. Apply Ingresses & Backend
echo "Applying Ingresses and Vault Backend..."
kubectl apply -f kubernetes/common/vault-backend.yaml
kubectl apply -f kubernetes/common/vault-ingress.yaml
kubectl apply -f kubernetes/common/grafana-ingress.yml

echo "Infrastructure deployment complete."
