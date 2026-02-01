#!/bin/bash
# ============================================================================
# Fix Script untuk Staging VPS - Version 2
# Jalankan script ini setelah git pull
# ============================================================================

set +e  # Don't exit on error

echo "=================================================="
echo "  Fix Script - Staging VPS (v2)"
echo "=================================================="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# =============================================================================
# Step 1: Clean up old resources
# =============================================================================
echo -e "${GREEN}[1/6] Cleaning up old resources...${NC}"

# Delete webhook yang bermasalah
kubectl delete validatingwebhookconfiguration ingress-nginx-admission 2>/dev/null && echo "Deleted ingress-nginx-admission webhook" || true

# Delete old ingresses
kubectl delete ingress argocd-ingress -n argocd 2>/dev/null && echo "Deleted old argocd-ingress" || true
kubectl delete ingress minio-ingress -n minio 2>/dev/null && echo "Deleted old minio-ingress" || true

echo -e "${GREEN}Cleanup done!${NC}"

# =============================================================================
# Step 2: Fix MinIO service (if needed)
# =============================================================================
echo -e "${GREEN}[2/6] Fixing MinIO service...${NC}"

# Delete and recreate service to fix selector
kubectl delete svc minio -n minio 2>/dev/null || true
sleep 2

# Apply MinIO resources
kubectl apply -f base/backup/minio/deployment.yaml

# Verify endpoints
echo "MinIO Endpoints:"
kubectl get endpoints minio -n minio

echo -e "${GREEN}MinIO service fixed!${NC}"

# =============================================================================
# Step 3: Copy TLS secrets
# =============================================================================
echo -e "${GREEN}[3/6] Copying TLS secrets...${NC}"

# Copy to minio namespace
kubectl delete secret goapps-tls -n minio 2>/dev/null || true
kubectl get secret goapps-tls -n monitoring -o yaml | \
  sed 's/namespace: monitoring/namespace: minio/' | \
  sed '/resourceVersion/d' | sed '/uid/d' | sed '/creationTimestamp/d' | \
  kubectl apply -f -

# Copy to argocd namespace
kubectl delete secret goapps-tls -n argocd 2>/dev/null || true
kubectl get secret goapps-tls -n monitoring -o yaml | \
  sed 's/namespace: monitoring/namespace: argocd/' | \
  sed '/resourceVersion/d' | sed '/uid/d' | sed '/creationTimestamp/d' | \
  kubectl apply -f -

echo -e "${GREEN}TLS secrets copied!${NC}"

# =============================================================================
# Step 4: Apply new ingress configuration
# =============================================================================
echo -e "${GREEN}[4/6] Applying new ingress configuration...${NC}"
kubectl apply -f overlays/staging/ingress.yaml

echo -e "${GREEN}Ingress applied!${NC}"

# =============================================================================
# Step 5: Restart deployments
# =============================================================================
echo -e "${GREEN}[5/6] Restarting MinIO deployment...${NC}"
kubectl rollout restart deployment minio -n minio 2>/dev/null || true
sleep 5

echo -e "${GREEN}Deployments restarted!${NC}"

# =============================================================================
# Step 6: Verify
# =============================================================================
echo -e "${GREEN}[6/6] Verifying...${NC}"
echo ""

echo "=== Ingress Status ==="
kubectl get ingress -A

echo ""
echo "=== MinIO Endpoints ==="
kubectl get endpoints minio -n minio

echo ""
echo "=== Pods Status ==="
kubectl get pods -n minio
kubectl get pods -n argocd | grep server

echo ""
echo "=================================================="
echo -e "${GREEN}  Fix Complete!${NC}"
echo "=================================================="
echo ""
echo "URLs (semua HTTPS dengan sub-path):"
echo "  Grafana:    https://staging-goapps.mutugading.com/grafana"
echo "  Prometheus: https://staging-goapps.mutugading.com/prometheus"
echo "  MinIO:      https://staging-goapps.mutugading.com/minio/"
echo "  ArgoCD:     https://staging-goapps.mutugading.com/argocd/"
echo ""
echo "Tunggu 1-2 menit untuk ingress controller update."
echo ""
echo "Jika masih ada masalah, cek logs:"
echo "  kubectl logs -n minio deploy/minio"
echo "  kubectl logs -n ingress-nginx deploy/ingress-nginx-controller"
