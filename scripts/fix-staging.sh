#!/bin/bash
# ============================================================================
# Fix Script untuk Staging VPS
# Jalankan script ini setelah git pull
# ============================================================================

# Don't exit on error, we'll handle errors manually
set +e

echo "=================================================="
echo "  Fix Script - Staging VPS"
echo "=================================================="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# =============================================================================
# Step 1: Delete problematic resources
# =============================================================================
echo -e "${GREEN}[1/7] Cleaning up problematic resources...${NC}"

# Delete webhook yang bermasalah
kubectl delete validatingwebhookconfiguration ingress-nginx-admission 2>/dev/null && echo "Deleted ingress-nginx-admission webhook" || true

# Delete ArgoCD ingress yang lama (kita pakai NodePort sekarang)
kubectl delete ingress argocd-ingress -n argocd 2>/dev/null && echo "Deleted argocd-ingress" || true

# Delete MinIO ingress yang lama
kubectl delete ingress minio-ingress -n minio 2>/dev/null && echo "Deleted minio-ingress" || true

# Delete old ArgoCD nodeport service
kubectl delete svc argocd-server-nodeport -n argocd 2>/dev/null && echo "Deleted argocd-server-nodeport" || true

echo -e "${GREEN}Cleanup done!${NC}"

# =============================================================================
# Step 2: Delete existing MinIO deployment completely (immutable selector issue)
# =============================================================================
echo -e "${GREEN}[2/7] Handling MinIO deployment...${NC}"

echo "Deleting MinIO deployment completely (data preserved in PVC)..."
kubectl delete deployment minio -n minio --force --grace-period=0 2>/dev/null || true

echo "Waiting for deployment to be fully deleted..."
sleep 10

# Verify deletion
if kubectl get deployment minio -n minio 2>/dev/null; then
    echo -e "${RED}Warning: MinIO deployment still exists, waiting more...${NC}"
    sleep 10
    kubectl delete deployment minio -n minio --force --grace-period=0 2>/dev/null || true
fi

# Apply MinIO fresh - using base directly to avoid selector issues
echo "Applying MinIO deployment..."
kubectl apply -f base/backup/minio/deployment.yaml

if [ $? -ne 0 ]; then
    echo -e "${RED}Error applying MinIO. Trying alternative method...${NC}"
    # Alternative: apply directly without kustomize
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
  labels:
    app: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
        - name: minio
          image: minio/minio:latest
          args:
            - server
            - /data
            - --console-address
            - ":9001"
          ports:
            - containerPort: 9000
              name: api
            - containerPort: 9001
              name: console
          env:
            - name: MINIO_BROWSER_REDIRECT_URL
              value: "https://staging-goapps.mutugading.com/minio/"
            - name: MINIO_CONSOLE_SUBPATH
              value: "/minio"
          envFrom:
            - secretRef:
                name: minio-secret
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          volumeMounts:
            - name: minio-data
              mountPath: /data
          livenessProbe:
            httpGet:
              path: /minio/health/live
              port: 9000
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /minio/health/ready
              port: 9000
            initialDelaySeconds: 10
            periodSeconds: 5
      volumes:
        - name: minio-data
          persistentVolumeClaim:
            claimName: minio-data
EOF
fi

echo -e "${GREEN}MinIO deployed!${NC}"

# =============================================================================
# Step 3: Apply ArgoCD NodePort Service
# =============================================================================
echo -e "${GREEN}[3/7] Applying ArgoCD NodePort Service...${NC}"
kubectl apply -k base/argocd/
echo -e "${GREEN}ArgoCD NodePort applied!${NC}"

# =============================================================================
# Step 4: Copy TLS secret to minio namespace
# =============================================================================
echo -e "${GREEN}[4/7] Copying TLS secret to minio namespace...${NC}"

# Delete existing and recreate
kubectl delete secret goapps-tls -n minio 2>/dev/null || true
kubectl get secret goapps-tls -n monitoring -o yaml | \
  sed 's/namespace: monitoring/namespace: minio/' | \
  sed '/resourceVersion/d' | \
  sed '/uid/d' | \
  sed '/creationTimestamp/d' | \
  kubectl apply -f -

echo -e "${GREEN}TLS secret copied!${NC}"

# =============================================================================
# Step 5: Apply Ingress
# =============================================================================
echo -e "${GREEN}[5/7] Applying Ingress...${NC}"
kubectl apply -f overlays/staging/ingress.yaml
echo -e "${GREEN}Ingress applied!${NC}"

# =============================================================================
# Step 6: Restart deployments to apply new configs
# =============================================================================
echo -e "${GREEN}[6/7] Restarting Grafana deployment...${NC}"
kubectl rollout restart deployment prometheus-grafana -n monitoring
echo -e "${GREEN}Grafana restarted!${NC}"

# =============================================================================
# Step 7: Verify
# =============================================================================
echo -e "${GREEN}[7/7] Verifying...${NC}"
echo ""

echo "=== ArgoCD NodePort Service ==="
kubectl get svc argocd-server-nodeport -n argocd 2>/dev/null || echo "Not found"

echo ""
echo "=== Ingress ==="
kubectl get ingress -A

echo ""
echo "=== Pods Status ==="
echo "Grafana:"
kubectl get pods -n monitoring | grep grafana || echo "None"
echo "MinIO:"
kubectl get pods -n minio || echo "None"

echo ""
echo "=================================================="
echo -e "${GREEN}  Fix Complete!${NC}"
echo "=================================================="
echo ""
echo "URLs (tunggu 1-2 menit untuk pods ready):"
echo "  Grafana:    https://staging-goapps.mutugading.com/grafana"
echo "  Prometheus: https://staging-goapps.mutugading.com/prometheus"
echo "  MinIO:      https://staging-goapps.mutugading.com/minio"
echo "  ArgoCD:     http://staging-goapps.mutugading.com:30080"
echo ""
echo "Untuk monitor pods:"
echo "  kubectl get pods -A -w"
echo ""
echo "Jika masih ada masalah, cek logs:"
echo "  kubectl logs -n minio deploy/minio"
echo "  kubectl logs -n monitoring deploy/prometheus-grafana -c grafana"
