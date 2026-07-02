# Runbook — Aktivasi Perbaikan Monitoring/Alerting + Pemulihan Grafana Staging (2026-07)

> **Konteks**: Merge `fix/costing-product-calculation` ke `main` membawa perbaikan
> alert rules (label pod/namespace di email, stop spam OOM, hapus duplikat),
> rantai metric HPA cost-worker (RabbitMQ → Prometheus → prometheus-adapter),
> right-sizing HPA/resources, identitas email Grafana per environment, dan
> `deploymentStrategy: Recreate` untuk Grafana.
>
> **Insiden saat aktivasi pertama di staging (2026-07-02)**: `helm upgrade`
> timeout (Grafana chart default RollingUpdate + PVC → deadlock), lalu retry
> gagal dengan `persistentvolumeclaims "prometheus-grafana" not found` karena
> PVC tercatat di release tapi sudah terhapus dari cluster. Pod Grafana lama
> ikut hilang → web Grafana staging **503**. Runbook ini memulihkannya dan
> menyelesaikan aktivasi di kedua environment.
>
> **Tidak ada data hilang**: keempat dashboard (Go Apps Microservices,
> PostgreSQL Database, Kubernetes Logs - Loki, Cost Calculation Engine)
> ter-provision otomatis dari ConfigMap di git (`base/monitoring/dashboards/`).
> Export manual dari production (2026-07-02) sudah diverifikasi identik
> (uid sama) — hanya cadangan, tidak dibutuhkan.

---

## Prasyarat (di VPS yang dikerjakan)

```bash
cd ~/goapps-infra
git checkout main
git pull
```

Pastikan commit terbaru sudah masuk (harus memuat
`docs/runbooks/manifests/grafana-pvc.yaml` dan
`deploymentStrategy: Recreate` di `base/monitoring/helm-values/prometheus-stack.yaml`):

```bash
git log --oneline -3
grep -A1 'deploymentStrategy' base/monitoring/helm-values/prometheus-stack.yaml
```

---

## BAGIAN 1 — Pemulihan Grafana STAGING (jalankan di VPS staging)

### 1.1 Buat ulang PVC Grafana (dari file repo — anti masalah copas indentasi)

```bash
kubectl apply -f docs/runbooks/manifests/grafana-pvc.yaml
kubectl get pvc prometheus-grafana -n monitoring
```

- Status **`Pending` adalah NORMAL** — StorageClass `local-path` memakai
  `WaitForFirstConsumer`; PVC baru `Bound` saat pod memakainya.
- Yang TIDAK normal: status `Terminating` → **STOP**, jalankan
  `kubectl get events -n monitoring --sort-by=.lastTimestamp | tail -20`
  dan laporkan (ada sesuatu yang menghapus PVC — harus diketahui dulu).

**Fallback** kalau file belum ada di checkout (JSON satu baris, kebal
kehilangan indentasi saat paste):

```bash
echo '{"apiVersion":"v1","kind":"PersistentVolumeClaim","metadata":{"name":"prometheus-grafana","namespace":"monitoring","labels":{"app.kubernetes.io/managed-by":"Helm","app.kubernetes.io/name":"grafana","app.kubernetes.io/instance":"prometheus"},"annotations":{"meta.helm.sh/release-name":"prometheus","meta.helm.sh/release-namespace":"monitoring"}},"spec":{"accessModes":["ReadWriteOnce"],"resources":{"requests":{"storage":"10Gi"}}}}' | kubectl apply -f -
```

### 1.2 Jadwalkan ulang pod Grafana yang Pending

Scheduler tidak langsung mencoba ulang pod yang gagal schedule — hapus pod
Pending supaya Deployment membuat penggantinya (yang kini menemukan PVC-nya):

```bash
kubectl get pods -n monitoring | grep grafana
# hapus pod yang statusnya Pending (nama bisa berbeda — pakai hasil di atas):
kubectl delete pod -n monitoring $(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')

# tunggu sampai 4/4 Running (biasanya < 2 menit):
kubectl get pods -n monitoring -w | grep grafana
# (Ctrl+C untuk berhenti memantau)
kubectl get pvc prometheus-grafana -n monitoring     # sekarang: Bound
```

### 1.3 Rapikan status release Helm + selesaikan aktivasi

Satu perintah ini mengerjakan tiga hal: (a) helm upgrade kube-prometheus-stack
(identitas email + Recreate), (b) install prometheus-adapter, (c) apply alert
rules baru:

```bash
export GRAFANA_PASSWORD='<password admin grafana staging SAAT INI>'
./scripts/install-monitoring.sh staging
```

Catatan:
- `GRAFANA_PASSWORD` **harus password yang sekarang** — kalau diisi berbeda,
  password admin ikut berganti.
- Grafana restart ±1 menit (strategy Recreate) — 1–2 email `DatasourceError`
  transien bisa muncul lalu resolved sendiri; abaikan.
- Helm 3 bisa upgrade di atas release berstatus `failed` — tidak perlu
  rollback/uninstall.

### 1.4 Verifikasi staging

```bash
helm list -n monitoring                                  # STATUS: deployed
kubectl get pods -n monitoring                           # semua Running
kubectl get pvc -n monitoring | grep grafana             # Bound
kubectl get apiservice v1beta1.external.metrics.k8s.io   # Available: True
kubectl get hpa -n goapps-staging                        # cost-worker: "0/5 (avg)" BUKAN <unknown>
kubectl exec rabbitmq-0 -n database -- rabbitmq-plugins list -e | grep prometheus
kubectl exec rabbitmq-0 -n database -- wget -qO- localhost:15692/metrics | grep 'messages_ready{' | head -3
```

Di browser (`https://staging-goapps.mutugading.com:24169/grafana/`):
- [ ] Web hidup lagi (503 hilang), login dengan password yang sama
- [ ] 4 dashboard ada: Go Apps Microservices, PostgreSQL Database,
      Kubernetes Logs - Loki, Cost Calculation Engine
- [ ] Alerting → Alert rules: tidak ada judul dobel
      (mis. "Deployment Unavailable Replicas" DAN "Deployment Has Unavailable
      Replicas" — yang tersisa hanya versi "Has")

---

## BAGIAN 2 — Aktivasi PRODUCTION (jalankan di VPS production)

> Grafana production saat ini **sehat** — tidak ada pemulihan yang diperlukan.
> Dengan `Recreate` sudah masuk values, upgrade tidak akan mengalami deadlock
> seperti staging. Tetap sediakan jendela ±2 menit Grafana down.

```bash
cd ~/goapps-infra && git checkout main && git pull

# Cek dulu: apakah PVC grafana ada di production?
kubectl get pvc -n monitoring | grep grafana
# - Jika TIDAK ada (kemungkinan besar, sama seperti staging):
kubectl apply -f docs/runbooks/manifests/grafana-pvc.yaml
# - Jika ADA dan Bound: lewati, langsung lanjut.

export GRAFANA_PASSWORD='<password admin grafana production SAAT INI>'
./scripts/install-monitoring.sh production
```

> ⚠️ Karena Grafana production juga berjalan tanpa persistence selama ini,
> upgrade ini memindahkannya ke PVC → konten buatan manual di UI (dashboard
> yang tidak berasal dari git, silence, history) hilang sekali ini saja.
> Export 2026-07-02 sudah membuktikan semua dashboard berasal dari git,
> jadi aman. Setelah ini, restart Grafana tidak menghilangkan apa pun lagi.

Lalu **sync manual** di ArgoCD UI (perubahan HPA/resources production):
- `finance-service-production`
- `iam-service-production`
- `frontend-production`
- `finance-cost-worker-production`

Verifikasi production:

```bash
helm list -n monitoring                                  # deployed
kubectl get pods -n monitoring                           # semua Running
kubectl get apiservice v1beta1.external.metrics.k8s.io   # Available: True
kubectl get hpa -A
#   finance/iam/frontend : min 2, target CPU saja
#   finance-cost-worker  : max 20, target "0/5 (avg)"
kubectl get pods -n goapps-production                    # 2 replika per service
```

---

## BAGIAN 3 — Verifikasi hasil akhir (beberapa jam / hari berikutnya)

| Cek | Ekspektasi |
|---|---|
| Email alert berikutnya | Pengirim `GoApps Staging Monitoring` / `GoApps Production Monitoring`; nama pod/namespace terisi (bukan `[no value]`); link `https://<host>:24169/grafana/...` bisa diklik |
| Jam 03:10 / 06:10 / 14:10 / 22:10 WIB | TIDAK ada lagi email "Pod Stuck Pending" (dulu: pod backup pending ±11 mnt karena pull `minio/mc:latest` tiap run) |
| Email "Pod OOMKilled" | Tidak berulang tiap ±4 jam lagi; hanya saat ada OOM baru |
| Sebelum tanggal 5 (cron calc 02:00 WIB) | HPA cost-worker menunjukkan angka (bukan `<unknown>`) di kedua env — kalkulasi bulanan bisa scale 2→6 (staging) / 2→20 (production) |

---

## Troubleshooting

| Gejala | Penyebab | Tindakan |
|---|---|---|
| Pod Grafana baru CrashLoop, log `permission denied /var/lib/grafana` | Isu lama grafana#1256 (initChownData dimatikan) | Cari path PV: `kubectl get pv $(kubectl get pvc prometheus-grafana -n monitoring -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.hostPath.path}{"\n"}{.spec.local.path}'` lalu `sudo chown -R 472:472 <path>` di host, hapus pod |
| PVC kembali `Terminating` sendiri | Ada yang menghapusnya — belum diketahui | STOP; `kubectl get events -n monitoring --sort-by=.lastTimestamp \| tail -20` dan laporkan |
| `helm upgrade` gagal `context deadline exceeded` lagi | Ada pod stack monitoring yang tidak ready | `kubectl get pods -n monitoring`; describe/log pod yang tidak ready; perbaiki penyebab; jalankan ulang script (aman diulang) |
| `kubectl apply` error `resource name may not be empty` | Indentasi YAML hilang saat paste | Pakai file repo (`kubectl apply -f docs/runbooks/manifests/grafana-pvc.yaml`) atau fallback JSON satu-baris di §1.1 |
| Email masih `[no value]` setelah semua selesai | Alert rules belum ter-apply / sidecar belum reload | `kubectl apply -k base/monitoring/alert-rules`; tunggu ±1 menit; cek Grafana → Alerting → Alert rules |
| HPA cost-worker masih `<unknown>` | Adapter belum terdaftar / RabbitMQ belum ter-scrape | Jalankan urutan verifikasi §1.4 dari bawah ke atas: metric di :15692 → plugin aktif → apiservice Available; laporkan di titik mana yang gagal |
