#!/usr/bin/env bash
# One-time ingress-nginx install onto a local kind cluster. kind-only: unlike
# the aws-load-balancer-controller, ingress-nginx has no IRSA/cloud
# dependency, so it's installed as a plain static manifest here rather than
# an Argo CD Application -- same reasoning as install-argocd.sh bootstrapping
# Argo CD itself before anything can reconcile. Run this once per kind
# cluster, after `kind create cluster --config bootstrap/kind-config.yaml`
# and before applying root-application-local.yaml.
set -euo pipefail

# Pinned, not `main` or `stable`, matching every other image in this repo.
# Override with INGRESS_NGINX_VERSION=<tag> to install a different release.
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.11.3}"

CURRENT_CONTEXT="$(kubectl config current-context)"
echo "This will install ingress-nginx (kind provider) onto kubectl context: $CURRENT_CONTEXT"
read -r -p "Continue? [y/N] " REPLY
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi

kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"

echo "Waiting for the ingress-nginx admission webhook..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

echo "ingress-nginx installed in namespace 'ingress-nginx'."
