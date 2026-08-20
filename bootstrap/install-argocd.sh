#!/usr/bin/env bash
# One-time Argo CD install onto whatever cluster the current kubectl context
# points at. Run this once per cluster, before applying project.yaml /
# root-application.yaml.
set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
# Pinned, not the `stable` branch alias -- matches every other image in this
# repo (Prometheus, Grafana, ClickHouse, Kafka are all pinned too). Override
# with ARGOCD_VERSION=<tag> to install a different release.
ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.0}"

CURRENT_CONTEXT="$(kubectl config current-context)"
echo "This will install Argo CD onto kubectl context: $CURRENT_CONTEXT"
read -r -p "Continue? [y/N] " REPLY
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi

kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --server-side (not a plain `apply`): Argo CD's CRDs -- applicationsets.
# argoproj.io especially -- have OpenAPI schemas large enough that a regular
# apply's last-applied-configuration annotation exceeds the API server's
# 256KiB annotation limit. Server-side apply tracks changes via managed
# fields instead of that annotation, so it doesn't hit the limit.
kubectl apply --server-side --force-conflicts -n "$ARGOCD_NAMESPACE" \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "Waiting for argocd-server to be ready..."
kubectl wait --for=condition=available --timeout=300s \
  deployment/argocd-server -n "$ARGOCD_NAMESPACE"

echo "Argo CD installed in namespace '$ARGOCD_NAMESPACE'."
echo "Initial admin password:"
kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo
echo "Port-forward to reach the UI: kubectl -n $ARGOCD_NAMESPACE port-forward svc/argocd-server 8080:443"
