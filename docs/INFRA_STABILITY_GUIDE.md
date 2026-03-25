# Infrastructure Stability Guide

> Panduan lengkap setelah merge PR infra ke main.
> Jalankan setiap step secara berurutan. Jangan skip.

---

## Summary Perubahan yang Di-Push

| Perubahan | File | Dampak |
|-----------|------|--------|
| Loki retention 7 hari | `base/monitoring/helm-values/loki-stack.yaml` | Logs auto-delete setelah 7 hari |
| Prometheus retention 15d + 15GB cap | `base/monitoring/helm-values/prometheus-stack.yaml` | Metrics auto-delete setelah 15 hari |
| Rolling update `maxUnavailable: 0` | 3x `services/*/base/deployment.yaml` | Zero-downtime deploy |
| Startup probe | 3x `services/*/base/deployment.yaml` | Pod tidak dibunuh saat startup |
| ArgoCD retry policy | 11x `argocd/apps/**/*.yaml` | Auto-retry sync 5x dengan backoff |
| Sync timeout 300s → 600s | `.github/workflows/sync-argocd.yml` | Cukup waktu untuk IAM startup |
| Tambah IAM+FE di production sync | `.github/workflows/sync-argocd.yml` | Semua service di-sync |
| Fix backup env label | 2x `base/backup/cronjobs/*.yaml` | Base env "base", overlay override |

---

## Step 1: SSH ke Staging VPS

```bash
ssh deploy@staging-goapps
sudo -i
```

### 1.1 K3s Config — Image GC + Log Rotation

```bash
# Buat/edit config file
cat >> /etc/rancher/k3s/config.yaml << 'EOF'
kubelet-arg:
  - "image-gc-high-threshold=85"
  - "image-gc-low-threshold=80"
  - "container-log-max-size=50Mi"
  - "container-log-max-files=3"
EOF

# Restart K3s untuk apply config
systemctl restart k3s

# Tunggu semua pod kembali running (~1-2 menit)
watch kubectl get pods -A
# Ctrl+C setelah semua Running/Completed
```

### 1.2 Prune Old Container Images

```bash
crictl rmi --prune
```

### 1.3 Update Loki (Tambah Retention)

```bash
# Clone/pull repo terbaru
cd /tmp && git clone https://github.com/mutugading/goapps-infra.git
# atau jika sudah ada:
# cd /path/to/goapps-infra && git pull origin main

# Apply Loki upgrade
helm upgrade loki grafana/loki-stack \
  -n monitoring \
  -f /tmp/goapps-infra/base/monitoring/helm-values/loki-stack.yaml \
  --wait --timeout 5m

# Verifikasi Loki running
kubectl get pods -n monitoring -l app=loki
```

### 1.4 Update Prometheus Retention (TIDAK reset Grafana)

```bash
# Pastikan pakai password Grafana yang SAMA dengan yang sudah ada
# Ganti YOUR_GRAFANA_PASSWORD dengan password Grafana yang sedang digunakan

helm upgrade prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f /tmp/goapps-infra/base/monitoring/helm-values/prometheus-stack.yaml \
  --set grafana.adminPassword="YOUR_GRAFANA_PASSWORD" \
  --set grafana.assertNoLeakedSecrets=false \
  --wait --timeout 10m

# PENTING: Jika lupa password Grafana, cek dulu:
# kubectl get secret -n monitoring prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d

# Verifikasi semua monitoring pods running
kubectl get pods -n monitoring
```

### 1.5 Apply ArgoCD App Manifests (Retry Policy)

```bash
# Apply updated ArgoCD applications
kubectl apply -f /tmp/goapps-infra/argocd/apps/staging/
kubectl apply -f /tmp/goapps-infra/argocd/apps/shared/

# Verifikasi
kubectl get applications -n argocd
```

### 1.6 Verifikasi Deployment Changes Ter-Apply

ArgoCD auto-sync akan mendeteksi perubahan deployment (rolling update, startup probe) setelah push ke main. Cek status:

```bash
# Cek ArgoCD sync status
kubectl get applications -n argocd

# Cek deployment strategy sudah ter-update
kubectl get deployment finance-service -n goapps-staging -o jsonpath='{.spec.strategy}' | python3 -m json.tool
kubectl get deployment iam-service -n goapps-staging -o jsonpath='{.spec.strategy}' | python3 -m json.tool
kubectl get deployment frontend -n goapps-staging -o jsonpath='{.spec.strategy}' | python3 -m json.tool

# Expected output: {"type":"RollingUpdate","rollingUpdate":{"maxSurge":1,"maxUnavailable":0}}
```

### 1.7 Cleanup

```bash
rm -rf /tmp/goapps-infra
```

---

## Step 2: SSH ke Production VPS

```bash
ssh deploy@goapps
sudo -i
```

### 2.1 K3s Config — Image GC + Log Rotation

```bash
cat >> /etc/rancher/k3s/config.yaml << 'EOF'
kubelet-arg:
  - "image-gc-high-threshold=85"
  - "image-gc-low-threshold=80"
  - "container-log-max-size=50Mi"
  - "container-log-max-files=3"
EOF

systemctl restart k3s
watch kubectl get pods -A
# Ctrl+C setelah semua Running/Completed
```

### 2.2 Prune Old Container Images

```bash
crictl rmi --prune
```

### 2.3 Update Loki

```bash
cd /tmp && git clone https://github.com/mutugading/goapps-infra.git

helm upgrade loki grafana/loki-stack \
  -n monitoring \
  -f /tmp/goapps-infra/base/monitoring/helm-values/loki-stack.yaml \
  --wait --timeout 5m

kubectl get pods -n monitoring -l app=loki
```

### 2.4 Update Prometheus Retention

```bash
# Cek password Grafana yang ada:
kubectl get secret -n monitoring prometheus-grafana -o jsonpath='{.data.admin-password}' | base64 -d
echo ""

# Apply dengan password yang SAMA:
helm upgrade prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f /tmp/goapps-infra/base/monitoring/helm-values/prometheus-stack.yaml \
  --set grafana.adminPassword="YOUR_GRAFANA_PASSWORD" \
  --set grafana.assertNoLeakedSecrets=false \
  --wait --timeout 10m

kubectl get pods -n monitoring
```

### 2.5 Apply ArgoCD App Manifests

```bash
kubectl apply -f /tmp/goapps-infra/argocd/apps/production/
kubectl apply -f /tmp/goapps-infra/argocd/apps/shared/

kubectl get applications -n argocd
```

### 2.6 Sync Production Deployments (Manual)

Production tidak auto-sync. Setelah ArgoCD app manifests di-update:

```bash
# Cek apakah ada OutOfSync
kubectl get applications -n argocd

# Sync deployment changes (rolling update, probes)
ARGOCD_POD=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n argocd $ARGOCD_POD -- argocd app sync finance-service-production --server localhost:8080 --plaintext
kubectl exec -n argocd $ARGOCD_POD -- argocd app sync iam-service-production --server localhost:8080 --plaintext
kubectl exec -n argocd $ARGOCD_POD -- argocd app sync frontend-production --server localhost:8080 --plaintext
```

### 2.7 Cleanup

```bash
rm -rf /tmp/goapps-infra
```

---

## Step 3: Verifikasi Final (Kedua VPS)

Jalankan di staging dan production:

```bash
# 1. Disk usage (harus < 60%)
df -h /

# 2. Semua pod Running
kubectl get pods -A | grep -v Running | grep -v Completed

# 3. Tidak ada CrashLoopBackOff
kubectl get pods -A | grep CrashLoopBackOff

# 4. PVC usage
kubectl get pvc -A

# 5. ArgoCD apps healthy
kubectl get applications -n argocd

# 6. Loki retention aktif
kubectl exec -n monitoring $(kubectl get pod -n monitoring -l app=loki -o name) -- du -sh /data/loki/

# 7. Prometheus retention
kubectl exec -n monitoring $(kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}') -- du -sh /prometheus/
```

---

## Troubleshooting

### Grafana Dashboard Hilang Setelah Helm Upgrade

Ini TIDAK seharusnya terjadi karena:
- Dashboard disimpan di PVC terpisah (10Gi)
- `helm upgrade` tidak menghapus PVC
- Sidecar provisioner otomatis re-import ConfigMap dashboards

Jika terjadi:
```bash
# Re-apply custom dashboards
for dashboard in /tmp/goapps-infra/base/monitoring/dashboards/*.json; do
    name=$(basename "$dashboard" .json | tr '_' '-')
    kubectl create configmap "grafana-dashboard-${name}" \
        --from-file="${dashboard}" -n monitoring \
        --dry-run=client -o yaml | \
        kubectl label --local -f - grafana_dashboard="1" -o yaml | \
        kubectl apply -f -
done

# JANGAN apply unified-datasources.yaml — datasource di-manage oleh helm chart
# (additionalDataSources di prometheus-stack.yaml)

# Re-apply alert rules
kubectl apply -f /tmp/goapps-infra/base/monitoring/alert-rules/ -n monitoring

# Restart Grafana to pick up changes
kubectl rollout restart deployment prometheus-grafana -n monitoring
```

### ArgoCD Masih Gagal Sync Setelah Fix

```bash
# Force refresh ArgoCD app cache
kubectl exec -n argocd $ARGOCD_POD -- argocd app get <app-name> --refresh --server localhost:8080 --plaintext

# Jika masih gagal, hard refresh
kubectl exec -n argocd $ARGOCD_POD -- argocd app get <app-name> --hard-refresh --server localhost:8080 --plaintext
```

### Pod Masih CrashLoopBackOff

```bash
# Cek logs pod yang crash
kubectl logs <pod-name> -n <namespace> --previous

# Cek events
kubectl describe pod <pod-name> -n <namespace>

# Jika disk pressure, cek node conditions
kubectl describe node | grep -A5 Conditions
```

### Image Updater Tidak Detect Image Baru

```bash
# Cek logs Image Updater
kubectl logs -n argocd $(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-image-updater -o name) --tail=50

# Force update check
kubectl rollout restart deployment argocd-image-updater -n argocd
```

---

## Catatan Penting

### Disk Budget (Kedua VPS = 80GB)

| Komponen | Alokasi PVC | Perkiraan Aktual |
|----------|-------------|-----------------|
| PostgreSQL | 20Gi | < 1Gi (DB kosong) |
| MinIO | 50Gi | < 1Gi (baru deploy) |
| Prometheus | 20Gi | ~5-10Gi (15d retention) |
| Loki | 10Gi | ~1-3Gi (7d retention) |
| Grafana | 10Gi | < 1Gi |
| RabbitMQ | 5Gi | < 1Gi |
| OS + K3s + Images | - | ~34Gi |
| **Total** | **115Gi PVC** | **~45Gi aktual** |

PVC `Capacity` adalah LIMIT, bukan alokasi aktual. K3s local-path provisioner tidak pre-allocate.

### Monitoring Auto-Cleanup Schedule

| Data | Retention | Cleanup |
|------|-----------|---------|
| Loki logs | 7 hari | Compactor auto-delete |
| Prometheus metrics | 15 hari / max 15GB | Auto-delete oldest |
| PostgreSQL backup | 7 hari | CronJob cleanup |
| MinIO backup | 7 hari | CronJob cleanup |
| Container images | 85% disk threshold | Kubelet GC |
| Container logs | 50Mi per container, max 3 files | Kubelet rotation |
