#!/bin/bash
# Install ArgoCD Image Updater for automated image updates
# This enables automatic detection and update of container images in GitOps

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"

echo "=================================================="
echo "  ArgoCD Image Updater Installation"
echo "=================================================="

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# =============================================================================
# Pre-flight Checks
# =============================================================================
echo -e "${GREEN}[1/4] Pre-flight checks...${NC}"

# Check if ArgoCD is installed
if ! kubectl get namespace argocd &>/dev/null; then
    echo -e "${RED}Error: ArgoCD namespace not found. Install ArgoCD first.${NC}"
    exit 1
fi

# Check if secrets exist
if ! kubectl get secret ghcr-creds -n argocd &>/dev/null; then
    echo -e "${YELLOW}Warning: ghcr-creds secret not found in argocd namespace.${NC}"
    echo "Create it with:"
    echo "  kubectl create secret docker-registry ghcr-creds \\"
    echo "    --namespace argocd \\"
    echo "    --docker-server=ghcr.io \\"
    echo "    --docker-username=<username> \\"
    echo "    --docker-password=<PAT>"
fi

if ! kubectl get secret git-creds -n argocd &>/dev/null; then
    echo -e "${YELLOW}Warning: git-creds secret not found in argocd namespace.${NC}"
    echo "Create it with:"
    echo "  kubectl create secret generic git-creds \\"
    echo "    --namespace argocd \\"
    echo "    --from-literal=username=<username> \\"
    echo "    --from-literal=password=<PAT>"
fi

# =============================================================================
# Step 2: Apply Image Updater Kustomization
# =============================================================================
echo -e "${GREEN}[2/4] Applying ArgoCD Image Updater...${NC}"

kubectl apply -k "${INFRA_DIR}/base/argocd-image-updater/"

# =============================================================================
# Step 3: Wait for Deployment
# =============================================================================
echo -e "${GREEN}[3/4] Waiting for deployment to be ready...${NC}"

kubectl rollout status deployment/argocd-image-updater -n argocd --timeout=300s

# =============================================================================
# Step 4: Verify Installation  
# =============================================================================
echo -e "${GREEN}[4/4] Verifying installation...${NC}"

# Check pod status
POD_STATUS=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-image-updater -o jsonpath='{.items[0].status.phase}')
if [ "$POD_STATUS" != "Running" ]; then
    echo -e "${RED}Error: Image Updater pod is not running (status: $POD_STATUS)${NC}"
    kubectl logs -n argocd -l app.kubernetes.io/name=argocd-image-updater --tail=20
    exit 1
fi

echo ""
echo "=================================================="
echo -e "${GREEN}  ArgoCD Image Updater Installed!${NC}"
echo "=================================================="
echo ""
echo "Check logs with:"
echo "  kubectl logs -n argocd deployment/argocd-image-updater -f"
echo ""
echo "Verify configuration:"
echo "  kubectl get configmap argocd-image-updater-config -n argocd -o yaml"
echo ""
echo "Next steps:"
echo "  1. Ensure ghcr-creds and git-creds secrets exist"
echo "  2. Add Image Updater annotations to ArgoCD Applications"
echo "  3. Push a change to trigger auto-update"
