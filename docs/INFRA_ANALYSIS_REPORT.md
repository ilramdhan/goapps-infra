# GoApps Infrastructure — Deep Analysis Report

**Tanggal Analisis**: 27 Februari 2026  
**Analis**: Kilo AI  
**Repo**: `goapps-infra` (fork: `ilramdhan/goapps-infra`)  
**Organisasi**: PT Mutu Gading Tekstil  
**Tujuan**: Evaluasi menyeluruh dari layer terdalam hingga terluar untuk mencapai infrastruktur _production-grade_, _scalable_, _sustainable_, dan _secure_.

---

## Daftar Isi

1. [Executive Summary](#1-executive-summary)
2. [Arsitektur Saat Ini](#2-arsitektur-saat-ini)
3. [Temuan: Temuan Positif (Kekuatan)](#3-temuan-positif-kekuatan)
4. [Temuan Kritis — Harus Segera Diperbaiki](#4-temuan-kritis--harus-segera-diperbaiki)
5. [Temuan High — Prioritas Tinggi](#5-temuan-high--prioritas-tinggi)
6. [Temuan Medium — Prioritas Menengah](#6-temuan-medium--prioritas-menengah)
7. [Temuan Low & Inkonsistensi](#7-temuan-low--inkonsistensi)
8. [Komponen yang Hilang (Missing)](#8-komponen-yang-hilang-missing)
9. [Rekomendasi Perbaikan Terperinci](#9-rekomendasi-perbaikan-terperinci)
   - [9.1 Security Hardening](#91-security-hardening)
   - [9.2 High Availability & Scalability](#92-high-availability--scalability)
   - [9.3 GitOps & CI/CD Improvements](#93-gitops--cicd-improvements)
   - [9.4 Observability & Alerting](#94-observability--alerting)
   - [9.5 Backup & Disaster Recovery](#95-backup--disaster-recovery)
   - [9.6 Code Quality & Consistency](#96-code-quality--consistency)
   - [9.7 Documentation & Runbooks](#97-documentation--runbooks)
10. [Roadmap Implementasi (Prioritas)](#10-roadmap-implementasi-prioritas)
11. [Estimasi Effort per Item](#11-estimasi-effort-per-item)

---

## 1. Executive Summary

Infrastruktur GoApps adalah implementasi GitOps berbasis K3s yang sudah berada di level **intermediate-to-advanced** untuk sebuah startup/SME. Banyak pola yang sudah benar: Kustomize base/overlay, ArgoCD Image Updater, monitoring Prometheus/Grafana/Loki, backup multi-destinasi, dan dokumentasi yang cukup lengkap.

Namun terdapat sejumlah **celah kritis** yang harus ditangani sebelum infrastruktur ini dapat dianggap _production-grade_:

- **1 celah CRITICAL** (credential bocor di git config)
- **6 celah HIGH** (SPOF database, direct DB connection, weak default password, dll.)
- **9 celah MEDIUM** (NetworkPolicy tidak ada, Redis ephemeral, MinIO CORS `*`, dll.)
- **15+ komponen missing** (NetworkPolicy, PDB, Alertmanager routing, runbooks, dll.)
- **12 inkonsistensi** yang berdampak pada operasional (Jaeger namespace salah, nama ArgoCD app duplikat, dll.)

---

## 2. Arsitektur Saat Ini

```
┌─────────────────────────────────────────────────────────────────┐
│                    GITHUB REPOSITORY                            │
│  goapps-infra (GitOps source of truth)                          │
│  goapps-backend (Go microservices)                              │
│  goapps-frontend (Next.js 15)                                   │
│  goapps-shared-proto (Protobuf)                                 │
└──────────────────────────┬──────────────────────────────────────┘
                           │ ArgoCD pulls + ArgoCD Image Updater pushes
          ┌────────────────┴────────────────┐
          ▼                                 ▼
┌─────────────────────┐         ┌─────────────────────┐
│   STAGING VPS       │         │   PRODUCTION VPS    │
│   4 core / 8GB RAM  │         │   8 core / 16GB RAM │
│   K3s (single node) │         │   K3s (single node) │
│                     │         │                     │
│ Namespaces:         │         │ Namespaces:         │
│  - goapps-staging   │         │  - goapps-production│
│  - database         │         │  - database         │
│  - minio            │         │  - minio            │
│  - monitoring       │         │  - monitoring       │
│  - argocd           │         │  - argocd           │
│  - observability    │         │  - observability    │
└─────────────────────┘         └─────────────────────┘

Services per environment:
  - iam-service      (gRPC :50052, HTTP :8081, metrics :8091)
  - finance-service  (gRPC :50051, HTTP :8080, metrics :8090)
  - frontend         (HTTP :3000 → svc :80)

Shared Infrastructure (per VPS):
  - PostgreSQL 18     (StatefulSet, 1 replica, 20Gi PVC)
  - PgBouncer         (Deployment, HPA 1-4)
  - Redis 7           (Deployment, emptyDir ← MASALAH)
  - RabbitMQ 3        (StatefulSet, 1 replica, 5Gi PVC)
  - MinIO             (Deployment, 50Gi PVC, NodePort)
  - Jaeger all-in-one (Deployment, namespace: observability)
  - Prometheus Stack  (Helm, 20Gi PVC, 30d retention)
  - Loki Stack        (Helm, 10Gi PVC)
  - NGINX Ingress     (DaemonSet/Deployment)
  - ArgoCD            (Helm, NodePort :30080)

Backup:
  - 3× daily (06:00, 14:00, 22:00 WIB): pg_dump → MinIO + B2 + hostPath
  - 1× daily (03:00 WIB): mc mirror MinIO → hostPath
  - Retention: 7 hari

CI/CD:
  GitHub Actions (self-hosted runners, label: staging/production)
  → Staging: auto-sync on push to main
  → Production: Image Updater updates tag, sync MANUAL
```

---

## 3. Temuan Positif (Kekuatan)

Sebelum masuk ke masalah, penting untuk mencatat apa yang sudah berjalan dengan baik:

| # | Kekuatan | Alasan |
|---|----------|--------|
| 1 | **Kustomize base/overlay pattern** | Konsisten di semua services, separation of concerns jelas |
| 2 | **ArgoCD Image Updater + GitOps** | CI push image → Image Updater update tag → ArgoCD sync — alur ini murni GitOps, immutable |
| 3 | **Monitoring komprehensif** | 25+ alert rules: node, pod, deployment, HPA, PVC, DB, service — dengan email routing |
| 4 | **Multi-destination backup** | PostgreSQL ke 3 lokasi (MinIO lokal + Backblaze B2 + VPS disk) — ini sudah _production mindset_ |
| 5 | **3× daily backup dengan timezone-aware** | Cron menggunakan `Asia/Jakarta`, `concurrencyPolicy: Forbid` mencegah overlap |
| 6 | **VPA Off mode** | Memberikan rekomendasi resource tanpa apply otomatis — aman untuk production |
| 7 | **Production deployment manual** | AutoSync staging, manual production — mengurangi risiko deployment tak sengaja |
| 8 | **PgBouncer sebagai connection pooler** | Melindungi PostgreSQL dari connection exhaustion, dengan HPA |
| 9 | **Dokumentasi lengkap** | README.md (990 baris), CONTRIBUTING.md (701 baris), RULES.md (942 baris), 2 ops docs |
| 10 | **Jaeger distributed tracing** | OTLP endpoint diinjeksikan ke semua services |
| 11 | **HPA di semua services** | finance-service, iam-service, frontend, pgbouncer — semua ada HPA |
| 12 | **Issue templates & PR templates** | GitHub-native project management tooling lengkap |
| 13 | **Secrets tidak di-commit** | `.gitignore` memblokir `*-secret.yaml` dan `secrets/` dir |
| 14 | **CalVer versioning** | Strategi versioning terdefinisi di CONTRIBUTING.md |
| 15 | **Bootstrap script idempotent** | Mengecek tools sudah terinstall sebelum install ulang |

---

## 4. Temuan Kritis — Harus Segera Diperbaiki

### CRIT-01: Git Config Mengandung GitHub Access Token Plaintext

**File**: `.git/config`  
**Severity**: 🔴 CRITICAL  

Remote URL format:
```
url = https://x-access-token:ghs_bK9qHHg[REDACTED]@github.com/ilramdhan/goapps-infra.git
```

Token GitHub (`ghs_...`) tersimpan dalam plaintext di `.git/config`. Siapa pun yang bisa membaca file system pada server ini memiliki akses GitHub penuh sesuai scope token tersebut.

**Dampak**: Jika token ini adalah GHCR token atau repo token, penyerang dapat membaca/menulis ke semua repository yang terhubung, membaca secrets, atau melakukan supply chain attack.

**Tindakan Segera**:
1. Revoke token `ghs_bK9qHHg...` di GitHub → Settings → Developer Settings → Personal Access Tokens SEKARANG
2. Regenerate token baru
3. Gunakan SSH atau credential helper alih-alih menyematkan token di URL:
   ```bash
   git remote set-url origin git@github.com:mutugading/goapps-infra.git
   ```
4. Atau gunakan GitHub CLI (`gh auth login`) dengan credential store terenkripsi

---

## 5. Temuan High — Prioritas Tinggi

### HIGH-01: Single Point of Failure — PostgreSQL Tanpa HA

**File**: `base/database/postgres/statefulset.yaml`  
**Severity**: 🟠 HIGH

PostgreSQL berjalan sebagai StatefulSet dengan **1 replica**, tanpa:
- Streaming replication
- Read replica
- Automatic failover (Patroni/pg_auto_failover)
- Hot standby

Jika pod PostgreSQL crash atau node gagal, **seluruh platform down** karena semua services bergantung pada satu instance ini.

**Rekomendasi**: Lihat [Bagian 9.2](#92-high-availability--scalability) untuk solusi HA.

---

### HIGH-02: finance-service dan iam-service Bypass PgBouncer

**File**: `services/finance-service/base/deployment.yaml`, `services/iam-service/base/deployment.yaml`  
**Severity**: 🟠 HIGH

```yaml
# finance-service/base/deployment.yaml
- name: DATABASE_HOST
  value: "postgres.database.svc.cluster.local"  # ← LANGSUNG ke Postgres!
```

`RULES.md` secara eksplisit menyatakan:
> "All services MUST connect through PgBouncer"

Namun kedua services ini connect langsung ke PostgreSQL, membypass connection pooler. Ini menyebabkan:
- PostgreSQL membuka koneksi baru per request (bukan pooled)
- Risiko `max_connections` terlampaui (saat ini dikonfigurasi hanya 100)
- PgBouncer HPA tidak berguna karena traffic tidak melaluinya

**Tindakan**: Ubah `DATABASE_HOST` ke `pgbouncer.database.svc.cluster.local` di kedua services.

---

### HIGH-03: Redis Menggunakan `emptyDir` — Tidak Persisten

**File**: `base/database/redis/deployment.yaml`  
**Severity**: 🟠 HIGH

```yaml
volumes:
  - name: redis-data
    emptyDir: {}
```

Redis dikonfigurasi dengan `emptyDir` — **semua data hilang saat pod restart** atau reschedule. Jika Redis digunakan untuk:
- Session management → semua user logout saat Redis restart
- Rate limiting → counter direset, memungkinkan bypass rate limit
- Cache invalidation → data stale bisa muncul
- JWT token revocation → revoked tokens menjadi valid kembali

**Tindakan**: Ganti ke PVC dengan `ReadWriteOnce` atau aktifkan RDB/AOF persistence.

---

### HIGH-04: IAM Seed Job Default Password `admin123`

**File**: `services/iam-service/base/seed-job.yaml`  
**Severity**: 🟠 HIGH

```yaml
# seed-job.yaml comment: Admin user: username=admin, password=admin123
```

Default credential admin ini **harus diubah segera setelah deployment**. Jika tidak, siapa pun yang tahu URL bisa login sebagai administrator.

**Tindakan**: 
1. Inject password dari Kubernetes Secret (bukan hardcoded)
2. Dokumentasikan mandatory post-deployment step untuk change admin password
3. Atau generate random password via `openssl rand -base64 32` saat seed job dijalankan

---

### HIGH-05: iam-service Production Menggunakan Tag Mutable `latest`

**File**: `services/iam-service/overlays/production/kustomization.yaml`  
**Severity**: 🟠 HIGH

```yaml
images:
  - name: ghcr.io/mutugading/iam-service
    newTag: latest  # ← MUTABLE TAG di PRODUCTION!
```

Tag `latest` adalah mutable — setiap push image baru dengan tag `latest` berpotensi ter-deploy ke production tanpa melalui proses review atau approval. Ini melanggar prinsip GitOps dan immutable deployments.

Bandingkan dengan finance-service yang sudah benar menggunakan SHA:
```yaml
newTag: "8c4fd5e"  # ← IMMUTABLE
```

**Tindakan**: Gunakan ArgoCD Image Updater dengan strategi SHA seperti services lainnya, atau pin ke SHA spesifik.

---

### HIGH-06: Tidak Ada NetworkPolicy — Zero Isolation Antar Pods

**File**: (tidak ada)  
**Severity**: 🟠 HIGH

`RULES.md` secara eksplisit menyebutkan network policies wajib, namun **tidak ada satu pun `NetworkPolicy` resource** di seluruh repository. Ini berarti:
- Setiap pod bisa berkomunikasi dengan pod lain di namespace mana pun
- Jika satu pod dikompromikan, penyerang bebas lateral movement ke database, monitoring, dll.
- Tidak ada microsegmentation

**Tindakan**: Implement NetworkPolicy per namespace. Lihat [Bagian 9.1](#91-security-hardening).

---

## 6. Temuan Medium — Prioritas Menengah

### MED-01: ArgoCD Tidak Ada Auth Tambahan di Ingress

**File**: `overlays/production/ingress.yaml`, `overlays/staging/ingress.yaml`  
**Severity**: 🟡 MEDIUM

ArgoCD di-expose via `/argocd` path tanpa Basic Auth annotation di ingress. Perlindungan satu-satunya adalah login ArgoCD sendiri. Ini membuka ArgoCD UI ke publik untuk percobaan bruteforce.

**Tindakan**: Tambahkan Basic Auth annotation (seperti Prometheus di production), atau restrict akses ArgoCD ke VPN/IP whitelist saja.

---

### MED-02: MinIO CORS `*` di Production

**File**: `overlays/production/ingress.yaml`  
**Severity**: 🟡 MEDIUM

```yaml
nginx.ingress.kubernetes.io/cors-allow-origin: "*"
```

`*` di CORS mengizinkan **domain mana pun** untuk membuat request ke MinIO endpoint. Di production, ini harus di-restrict ke domain spesifik (`goapps.mutugading.com`).

---

### MED-03: `kubernetes-dashboard` Admin User Punya `cluster-admin`

**File**: `base/kubernetes-dashboard/admin-user.yaml`  
**Severity**: 🟡 MEDIUM

```yaml
roleRef:
  name: cluster-admin  # ← Full cluster access
```

Token dashboard ini memberikan akses penuh ke cluster. Jika token dicuri atau dashboard dieksploitasi, penyerang punya kontrol total.

**Tindakan**: Buat role custom dengan permission minimal yang dibutuhkan untuk dashboard, atau gunakan `view` ClusterRole.

---

### MED-04: Backup Script Download MinIO Client Runtime via `curl`

**File**: `base/backup/cronjobs/postgres-backup.yaml`  
**Severity**: 🟡 MEDIUM

```bash
curl -o /usr/local/bin/mc https://dl.min.io/client/mc/release/linux-amd64/mc
```

Setiap CronJob backup mendownload MinIO client dari internet. Ini:
- Rentan MITM attack (tidak ada checksum verification)
- Bergantung pada ketersediaan `dl.min.io`
- Tidak reproducible (versi bisa berubah kapan pun)
- Memperlambat backup jika jaringan lambat

**Tindakan**: Buat custom Docker image dengan `mc` sudah terinstall, atau gunakan image `minio/mc:latest` sebagai init container.

---

### MED-05: MinIO Single Instance — Tidak Ada Redundancy

**File**: `base/backup/minio/deployment.yaml`  
**Severity**: 🟡 MEDIUM

MinIO berjalan sebagai Deployment single-instance dengan PVC `ReadWriteOnce`. Jika:
- Pod restart → MinIO tidak tersedia (backup gagal, file upload gagal)
- PVC corrupt → semua objek hilang
- Node failure → MinIO tidak bisa dijadwal ulang sampai node recover

MinIO juga digunakan sebagai target backup utama — jika MinIO down saat backup PostgreSQL, backup silently gagal (jika tidak ada alerting untuk backup failure).

---

### MED-06: Prometheus Staging Tidak Ada Autentikasi

**File**: `overlays/staging/ingress.yaml`  
**Severity**: 🟡 MEDIUM

Production Prometheus menggunakan Basic Auth, tapi staging tidak. Metrics bisa mengekspos informasi sensitif tentang infrastruktur (memory usage, connection counts, dll.) tanpa autentikasi.

---

### MED-07: ArgoCD Password Dicetak ke Stdout saat Install

**File**: `scripts/install-argocd.sh`  
**Severity**: 🟡 MEDIUM

```bash
echo "ArgoCD admin password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
```

Password di-output ke terminal, berpotensi tersimpan di shell history, log file CI/CD runner, atau terminal scrollback.

---

### MED-08: RabbitMQ Tanpa Clustering

**File**: `base/database/rabbitmq/deployment.yaml`  
**Severity**: 🟡 MEDIUM

RabbitMQ berjalan single-node. Jika pod restart, semua messages yang belum di-consume hilang (kecuali persistent queues). Tidak ada mirroring atau quorum queues.

---

### MED-09: Loki Stack Minimal Config — Tidak Aman

**File**: `base/monitoring/helm-values/loki-stack.yaml`  
**Severity**: 🟡 MEDIUM

```yaml
loki:
  enabled: true
  persistence:
    enabled: true
    size: 10Gi
promtail:
  enabled: true
```

Hanya 5 baris. Tidak ada:
- Authentication
- Retention policy eksplisit
- Resource limits untuk Loki/Promtail
- Network isolation

---

## 7. Temuan Low & Inkonsistensi

### Inkonsistensi Operasional

| # | Inkonsistensi | File | Dampak |
|---|---------------|------|--------|
| INC-01 | Jaeger di-deploy ke namespace `observability`, tapi services mengirim trace ke `jaeger-collector.monitoring.svc.cluster.local` | `services/*/base/deployment.yaml` | Traces tidak dikirim — distributed tracing tidak berfungsi |
| INC-02 | `argocd/apps/shared/infra-apps.yaml` hanya define `infra-database`, tapi workflow `sync-argocd.yml` menunggu app bernama `infra-apps` (tidak ada) | `sync-argocd.yml` | CI/CD sync workflow gagal |
| INC-03 | `overlays/*/backup-patch.yaml` (root level) dan `overlays/*/backup/kustomization.yaml` melakukan hal yang sama — duplikasi, backup-patch.yaml lebih terbatas (Postgres saja) | `overlays/*/` | Potensi conflict saat apply |
| INC-04 | `argocd/projects/goapps-project.yaml` sourceRepos: `mutugading/goapps-infra` tapi `.git/config` remote: `ilramdhan/goapps-infra` | ArgoCD Project | ArgoCD mungkin menolak sync jika fork tidak terdaftar |
| INC-05 | `rabbitmq/deployment.yaml` berisi StatefulSet, bukan Deployment | `base/database/rabbitmq/` | Confusion maintenance |
| INC-06 | `grafana-alert-rules.yaml` tidak di-include di `kustomization.yaml` | `base/monitoring/alert-rules/` | 14 alert rules tidak pernah diterapkan |
| INC-07 | `infra-backup` ArgoCD app punya nama sama di staging dan production | `argocd/apps/staging/infra-backup.yaml`, `argocd/apps/production/infra-backup.yaml` | Risk overwrite jika di-apply ke cluster yang sama |
| INC-08 | Dashboard JSON dan ConfigMap YAML ada dua versi untuk Go Apps dan Postgres | `base/monitoring/dashboards/` | Potensi duplikasi jika keduanya di-apply |
| INC-09 | `fix-staging.sh` dan `fix-production.sh` hampir identik | `scripts/` | Maintenance burden |
| INC-10 | `install-argocd.sh` membuat AppProject inline berbeda dengan `argocd/projects/goapps-project.yaml` | `scripts/install-argocd.sh` | Drift antara script dan deklaratif manifest |
| INC-11 | Tidak ada `kustomization.yaml` di `overlays/staging/` dan `overlays/production/` root | `overlays/*/` | `kubectl apply -k overlays/staging/` gagal — Makefile `apply-staging` target tidak berjalan |
| INC-12 | `docs/deployment-guide.md` Step 9.2 heading muncul di dalam code block (Markdown broken) | `docs/deployment-guide.md` | Dokumentasi tidak bisa dibaca dengan benar |

---

## 8. Komponen yang Hilang (Missing)

| # | Komponen | Lokasi Yang Seharusnya | Dampak |
|---|----------|----------------------|--------|
| M-01 | **NetworkPolicy** untuk semua namespace | `base/*/network-policy.yaml` | Zero isolation — HIGH security risk |
| M-02 | **PodDisruptionBudget (PDB)** untuk semua services | `services/*/base/pdb.yaml` | Zero-downtime deployment tidak terjamin |
| M-03 | **Root `kustomization.yaml`** di `overlays/staging/` dan `overlays/production/` | `overlays/staging/kustomization.yaml` | Makefile `apply-staging`/`apply-production` gagal |
| M-04 | **Alertmanager config** dengan email routing | `base/monitoring/helm-values/prometheus-stack.yaml` | Alert rules tidak ada penerima — email tidak terkirim |
| M-05 | **Loki dashboard ConfigMap** | `base/monitoring/dashboards/grafana-dashboard-loki-configmap.yaml` | Loki JSON dashboard tidak ter-provision |
| M-06 | **`grafana-alert-rules.yaml` di kustomization** | `base/monitoring/alert-rules/kustomization.yaml` | 14 Grafana alert rules tidak diterapkan |
| M-07 | **`base/secrets/` directory** | `base/secrets/secrets-template.yaml` | Deployment guide step 4 tidak berjalan |
| M-08 | **Runbooks** | `docs/runbooks/*.md` | Operator tidak tahu respons saat incident |
| M-09 | **ArgoCD Application untuk Jaeger** | `argocd/apps/shared/jaeger.yaml` | Jaeger tidak di-manage oleh ArgoCD |
| M-10 | **ArgoCD Application untuk Monitoring** | `argocd/apps/shared/infra-monitoring.yaml` | Monitoring tidak di-manage oleh ArgoCD |
| M-11 | **Dokumentasi pembuatan `goapps-auth-secret`** | `docs/vps-reset-guide.md` | Finance-service dan iam-service tidak berjalan tanpa secret ini |
| M-12 | **Dokumentasi pembuatan `smtp-secret`** | `docs/vps-reset-guide.md` | IAM service email tidak berjalan |
| M-13 | **Dokumentasi pembuatan `minio-tls` secret** | `docs/vps-reset-guide.md` | MinIO tidak bisa start tanpa TLS cert |
| M-14 | **`make port-forward-jaeger`** target | `Makefile` | Disebutkan di docs tapi tidak ada |
| M-15 | **`develop` branch ArgoCD App** | `argocd/apps/` | CI trigger develop branch tapi tidak ada app target |

---

## 9. Rekomendasi Perbaikan Terperinci

### 9.1 Security Hardening

#### 9.1.1 Implement NetworkPolicy Per Namespace

Buat NetworkPolicy yang menerapkan _default deny all_ kemudian allow berdasarkan kebutuhan:

**`base/database/network-policy.yaml`** (contoh untuk namespace `database`):
```yaml
# Default deny all ingress dan egress
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: database
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
# Allow PostgreSQL hanya dari goapps-staging, goapps-production, dan database (pgbouncer)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-postgres-ingress
  namespace: database
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: postgres
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: database  # pgbouncer
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: goapps-staging
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: goapps-production
      ports:
        - protocol: TCP
          port: 5432
---
# Allow PgBouncer dari goapps namespaces
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-pgbouncer-ingress
  namespace: database
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: pgbouncer
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: goapps-staging
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: goapps-production
      ports:
        - protocol: TCP
          port: 5432
---
# Allow Redis dari goapps namespaces
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-redis-ingress
  namespace: database
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: redis
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: goapps-staging
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: goapps-production
      ports:
        - protocol: TCP
          port: 6379
```

Lakukan hal serupa untuk namespace `monitoring`, `minio`, `goapps-staging`, `goapps-production`, `argocd`, `observability`.

Tambahkan label namespace di `base/namespaces/namespaces.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: database
  labels:
    kubernetes.io/metadata.name: database  # ← Wajib untuk NetworkPolicy selector
```

#### 9.1.2 Redis Persistence — Aktifkan RDB/AOF

Ubah `base/database/redis/deployment.yaml`:
```yaml
# Tambah PVC
volumes:
  - name: redis-data
    persistentVolumeClaim:
      claimName: redis-data

# Tambah args untuk persistence
args:
  - "--save 60 1"        # Save setiap 60 detik jika ada 1 perubahan
  - "--save 300 10"      # Save setiap 5 menit jika ada 10 perubahan  
  - "--appendonly yes"   # AOF persistence
  - "--appendfsync everysec"
  - "--maxmemory 512Mi"
  - "--maxmemory-policy allkeys-lru"

# Buat PVC terpisah
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: redis-data
  namespace: database
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
```

#### 9.1.3 Fix finance-service dan iam-service ke PgBouncer

Di `services/finance-service/base/deployment.yaml`:
```yaml
# SEBELUM (SALAH):
- name: DATABASE_HOST
  value: "postgres.database.svc.cluster.local"
- name: DATABASE_PORT
  value: "5432"

# SESUDAH (BENAR):
- name: DATABASE_HOST
  value: "pgbouncer.database.svc.cluster.local"
- name: DATABASE_PORT
  value: "5432"
```

Lakukan hal yang sama untuk `services/iam-service/base/deployment.yaml`.

**Catatan penting**: PgBouncer dalam transaction pooling mode tidak support `SET` statements, prepared statements, dan beberapa extension. Pastikan driver koneksi Go (pgx/pq) dikonfigurasi dengan `prefer_simple_protocol=true` untuk kompatibilitas PgBouncer.

#### 9.1.4 Fix Jaeger Endpoint Namespace

Di semua services, ubah dari:
```yaml
- name: JAEGER_ENDPOINT
  value: "jaeger-collector.monitoring.svc.cluster.local:4317"
```
Menjadi:
```yaml
- name: JAEGER_ENDPOINT
  value: "jaeger-collector.observability.svc.cluster.local:4317"
```

#### 9.1.5 ArgoCD — Tambah IP Whitelist atau Basic Auth

Di `overlays/production/ingress.yaml`, tambahkan:
```yaml
# Option A: Basic Auth (seperti Prometheus)
nginx.ingress.kubernetes.io/auth-type: basic
nginx.ingress.kubernetes.io/auth-secret: argocd-basic-auth
nginx.ingress.kubernetes.io/auth-realm: "ArgoCD - Restricted Access"

# Option B: IP Whitelist (lebih baik untuk production)
nginx.ingress.kubernetes.io/whitelist-source-range: "YOUR_OFFICE_IP/32,YOUR_VPN_IP/32"
```

#### 9.1.6 MinIO CORS — Restrict ke Domain Spesifik

Di `overlays/production/ingress.yaml`:
```yaml
# SEBELUM:
nginx.ingress.kubernetes.io/cors-allow-origin: "*"

# SESUDAH:
nginx.ingress.kubernetes.io/cors-allow-origin: "https://goapps.mutugading.com"
```

Di staging:
```yaml
nginx.ingress.kubernetes.io/cors-allow-origin: "https://staging-goapps.mutugading.com"
```

#### 9.1.7 IAM Seed Job — Inject Password dari Secret

Di `services/iam-service/base/seed-job.yaml`, ubah default admin credentials:
```yaml
env:
  - name: ADMIN_PASSWORD
    valueFrom:
      secretKeyRef:
        name: iam-admin-seed-secret  # Secret baru yang harus dibuat
        key: admin-password
  - name: ADMIN_USERNAME
    valueFrom:
      secretKeyRef:
        name: iam-admin-seed-secret
        key: admin-username
```

#### 9.1.8 Kubernetes Dashboard — Kurangi Privilege

Di `base/kubernetes-dashboard/admin-user.yaml`, ubah dari `cluster-admin` ke role yang lebih terbatas:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dashboard-viewer
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps", "endpoints", "namespaces", "nodes", "persistentvolumeclaims"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "statefulsets", "daemonsets", "replicasets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["batch"]
    resources: ["jobs", "cronjobs"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dashboard-viewer-binding
subjects:
  - kind: ServiceAccount
    name: admin-user
    namespace: kubernetes-dashboard
roleRef:
  kind: ClusterRole
  name: dashboard-viewer
  apiGroup: rbac.authorization.k8s.io
```

#### 9.1.9 Buat Secrets Template Directory

Buat `base/secrets/` directory dengan template:

```bash
# base/secrets/README.md (dokumentasi saja, tidak di-apply)
# SEMUA FILE DI SINI HARUS DI-GITIGNORE
# Gunakan sebagai template untuk pembuatan secret
```

Dan dokumentasikan semua secrets yang dibutuhkan di `docs/vps-reset-guide.md`:
- `goapps-auth-secret`: JWT signing keys
- `smtp-secret`: SMTP credentials untuk iam-service
- `minio-tls`: TLS certificate untuk MinIO
- `iam-admin-seed-secret`: Admin credentials untuk seed job
- `prometheus-basic-auth`: Basic auth untuk Prometheus ingress
- `argocd/git-creds`: Git credentials untuk ArgoCD Image Updater

#### 9.1.10 Backup — Gunakan Custom Image dengan mc Pre-installed

Buat `Dockerfile` untuk backup image:
```dockerfile
FROM postgres:18-alpine

# Install MinIO client
RUN wget -q -O /usr/local/bin/mc https://dl.min.io/client/mc/release/linux-amd64/mc \
    && chmod +x /usr/local/bin/mc \
    && mc --version

# Install rclone untuk Backblaze B2 (opsional, lebih reliable dari mc untuk B2)
RUN wget -q https://downloads.rclone.org/rclone-current-linux-amd64.zip \
    && unzip rclone-current-linux-amd64.zip \
    && mv rclone-*-linux-amd64/rclone /usr/local/bin/ \
    && rm -rf rclone-*

ENTRYPOINT ["/bin/sh"]
```

Push ke `ghcr.io/mutugading/backup-tools:latest` dan gunakan di CronJob.

---

### 9.2 High Availability & Scalability

#### 9.2.1 PostgreSQL — High Availability dengan CloudNativePG

Untuk production-grade PostgreSQL HA, gunakan **CloudNativePG** operator (CNCF project):

```yaml
# base/database/postgres/cluster.yaml (BARU - menggantikan statefulset.yaml)
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres-cluster
  namespace: database
spec:
  instances: 3  # 1 primary + 2 replicas
  
  primaryUpdateStrategy: unsupervised
  
  postgresql:
    parameters:
      max_connections: "100"
      shared_buffers: "256MB"
      effective_cache_size: "768MB"
      work_mem: "4MB"
      timezone: "Asia/Jakarta"
  
  bootstrap:
    initdb:
      database: goapps
      owner: goapps_user
      secret:
        name: postgres-credentials
  
  storage:
    size: 20Gi
    storageClass: local-path
  
  monitoring:
    enablePodMonitor: true
  
  backup:
    retentionPolicy: "7d"
    barmanObjectStore:
      destinationPath: "s3://postgres-backup"
      endpointURL: "http://minio.minio.svc.cluster.local:9000"
      s3Credentials:
        accessKeyId:
          name: minio-secret
          key: MINIO_ROOT_USER
        secretAccessKey:
          name: minio-secret
          key: MINIO_ROOT_PASSWORD
```

Keuntungan CloudNativePG:
- Automatic failover (primary election)
- Streaming replication built-in
- Integrated backup ke object store (MinIO/S3)
- Point-in-time recovery
- Rolling updates tanpa downtime

**Alternatif lebih sederhana** jika tidak mau operator: Jalankan PostgreSQL dengan satu primary + satu standby menggunakan Patroni.

#### 9.2.2 Redis — Gunakan Redis Sentinel atau Redis Cluster

Untuk production, pertimbangkan:

**Option A — Redis dengan Persistence (minimal, untuk small team)**:
```yaml
# Tambah PVC + aktifkan AOF (sudah dijelaskan di 9.1.2)
```

**Option B — Redis Sentinel (HA, 1 primary + 2 replica)**:
```yaml
# Gunakan Helm chart: bitnami/redis
# base/database/redis/helm-values.yaml
architecture: replication
auth:
  enabled: true
  existingSecret: redis-secret
  existingSecretPasswordKey: password
replica:
  replicaCount: 2
  persistence:
    enabled: true
    size: 5Gi
sentinel:
  enabled: true
  masterSet: mymaster
  quorum: 2
```

#### 9.2.3 MinIO — Distributed Mode (Multi-Drive)

Untuk production MinIO yang reliable:
```yaml
# base/backup/minio/statefulset.yaml (upgrade dari deployment ke StatefulSet)
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: minio
spec:
  replicas: 1  # Single node tapi dengan volumeClaimTemplates untuk multiple drives
  # Atau jika ada multi-node K3s: replicas: 4 (distributed mode)
  
  template:
    spec:
      containers:
        - name: minio
          image: minio/minio:RELEASE.2024-01-xx  # Pin versi, jangan :latest
          args:
            - server
            - /data
            - --console-address=:9001
          env:
            - name: MINIO_SITE_REGION
              value: "ap-southeast-1"
          
  volumeClaimTemplates:
    - metadata:
        name: minio-data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 50Gi
```

Minimal: **pin versi MinIO** alih-alih menggunakan `minio/minio:latest`.

#### 9.2.4 Tambah PodDisruptionBudget untuk Semua Services

Buat `services/*/base/pdb.yaml` untuk setiap service:

```yaml
# services/finance-service/base/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: finance-service-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: finance-service
---
# services/iam-service/base/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: iam-service-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: iam-service
---
# services/frontend/base/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: frontend-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: frontend
```

#### 9.2.5 RabbitMQ — Aktifkan Quorum Queues

Jika membutuhkan message durability:
```yaml
# base/database/rabbitmq/statefulset.yaml (rename dari deployment.yaml)
env:
  - name: RABBITMQ_DEFAULT_VHOST
    value: "/"
  - name: RABBITMQ_ERLANG_COOKIE
    valueFrom:
      secretKeyRef:
        name: rabbitmq-secret
        key: erlang-cookie
```

Dan aktifkan quorum queues sebagai default di aplikasi (bukan di infra manifest).

#### 9.2.6 Ingress Rate Limiting

Di `overlays/production/ingress.yaml`:
```yaml
# Untuk semua service
nginx.ingress.kubernetes.io/limit-rps: "100"
nginx.ingress.kubernetes.io/limit-rpm: "1000"
nginx.ingress.kubernetes.io/limit-connections: "20"

# Untuk auth endpoints (lebih ketat)
# Di iam-service ingress:
nginx.ingress.kubernetes.io/limit-rps: "5"
```

---

### 9.3 GitOps & CI/CD Improvements

#### 9.3.1 Tambah Root `kustomization.yaml` di Overlays

Buat `overlays/staging/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base/namespaces
  - ../../base/database
  - ../../base/ingress
  - backup/
  - minio/

patchesStrategicMerge:
  - ingress.yaml
```

Buat `overlays/production/kustomization.yaml` serupa.

#### 9.3.2 Perbaiki Workflow `sync-argocd.yml`

```yaml
# .github/workflows/sync-argocd.yml
# Ganti referensi 'infra-apps' yang tidak ada:
- name: Sync ArgoCD Apps
  run: |
    argocd app sync infra-database --grpc-web  # ← Nama yang benar
    argocd app sync infra-backup --grpc-web
    argocd app sync infra-minio --grpc-web
```

#### 9.3.3 Fix iam-service — Gunakan SHA Tag

Di `services/iam-service/overlays/staging/kustomization.yaml`:
```yaml
# Hapus newTag: main, biarkan ArgoCD Image Updater yang manage
# Tambah annotation yang sama dengan services lain:

# annotations:
#   argocd-image-updater.argoproj.io/image-list: iam-service=ghcr.io/mutugading/iam-service
#   argocd-image-updater.argoproj.io/iam-service.update-strategy: newest-build
#   argocd-image-updater.argoproj.io/iam-service.allow-tags: regexp:^[a-f0-9]{7,40}$
```

Dan di `argocd/apps/staging/iam-service.yaml`, tambahkan annotations Image Updater yang sama seperti finance-service.

#### 9.3.4 Tambah ArgoCD Application untuk Jaeger dan Monitoring

Buat `argocd/apps/shared/jaeger.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: infra-jaeger
  namespace: argocd
spec:
  project: goapps
  source:
    repoURL: https://github.com/mutugading/goapps-infra.git
    targetRevision: HEAD
    path: base/observability/jaeger
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

#### 9.3.5 Perbaiki Duplikasi `backup-patch.yaml`

Hapus `overlays/staging/backup-patch.yaml` dan `overlays/production/backup-patch.yaml` (root level), karena `backup/kustomization.yaml` sudah menangani hal yang sama dengan lebih lengkap.

#### 9.3.6 Ubah `infra-backup` App Name Agar Unik

Di `argocd/apps/production/infra-backup.yaml`:
```yaml
metadata:
  name: infra-backup-production  # ← Tambah suffix
```

Di `argocd/apps/staging/infra-backup.yaml`:
```yaml
metadata:
  name: infra-backup-staging  # ← Tambah suffix
```

Lakukan hal yang sama untuk `infra-minio`.

---

### 9.4 Observability & Alerting

#### 9.4.1 Konfigurasi Alertmanager dengan Email Routing

Tambahkan di `base/monitoring/helm-values/prometheus-stack.yaml`:
```yaml
alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 5Gi
  
  config:
    global:
      smtp_smarthost: 'smtp.gmail.com:587'
      smtp_from: 'alerts@mutugading.com'
      smtp_auth_username: '{{ SMTP_USER }}'
      smtp_auth_password: '{{ SMTP_PASS }}'
      
    route:
      group_by: ['alertname', 'severity']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      receiver: 'email-critical'
      routes:
        - match:
            severity: critical
          receiver: 'email-critical'
          repeat_interval: 1h
        - match:
            severity: warning
          receiver: 'email-warning'
          repeat_interval: 4h
    
    receivers:
      - name: 'email-critical'
        email_configs:
          - to: 'ops-team@mutugading.com'
            send_resolved: true
      - name: 'email-warning'
        email_configs:
          - to: 'dev-team@mutugading.com'
            send_resolved: true
    
    inhibit_rules:
      - source_match:
          severity: critical
        target_match:
          severity: warning
        equal: ['alertname', 'namespace']
```

**Catatan**: SMTP credentials harus diinject dari Secret, bukan hardcoded.

#### 9.4.2 Tambahkan `grafana-alert-rules.yaml` ke Kustomization

Di `base/monitoring/alert-rules/kustomization.yaml`, tambahkan:
```yaml
resources:
  - complete-alerts.yaml
  - grafana-alertrules-configmap.yaml
  - postgres-alerts.yaml
  - grafana-alert-rules.yaml  # ← TAMBAHKAN INI (saat ini hilang!)
```

#### 9.4.3 Buat Loki Dashboard ConfigMap

Buat `base/monitoring/dashboards/grafana-dashboard-loki-configmap.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-loki
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  loki-dashboard.json: |-
    # ← Isi dengan konten grafana-dashboard-loki.json
```

#### 9.4.4 Tambah Health Check Alert untuk Backup

Di `base/monitoring/alert-rules/postgres-alerts.yaml`, pastikan ada alert untuk backup failure:
```yaml
- alert: PostgresBackupFailed
  expr: |
    kube_job_status_failed{namespace="database", job_name=~"postgres-backup-.*"} > 0
  for: 1h
  labels:
    severity: critical
  annotations:
    summary: "PostgreSQL backup job failed"
    description: "Backup job {{ $labels.job_name }} has failed. Immediate action required."
```

#### 9.4.5 Konfigurasikan Loki Retention

Update `base/monitoring/helm-values/loki-stack.yaml`:
```yaml
loki:
  enabled: true
  persistence:
    enabled: true
    size: 10Gi
  config:
    table_manager:
      retention_deletes_enabled: true
      retention_period: 720h  # 30 hari
    limits_config:
      retention_period: 720h
      ingestion_rate_mb: 16
      ingestion_burst_size_mb: 32
      max_entries_limit_per_query: 5000
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

promtail:
  enabled: true
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi
```

---

### 9.5 Backup & Disaster Recovery

#### 9.5.1 Buat Custom Backup Image

Buat `base/backup/Dockerfile`:
```dockerfile
FROM postgres:18-alpine

RUN apk add --no-cache curl wget && \
    # Install MinIO client dengan checksum verification
    wget -q "https://dl.min.io/client/mc/release/linux-amd64/mc" -O /usr/local/bin/mc && \
    chmod +x /usr/local/bin/mc && \
    # Verifikasi instalasi
    mc --version

ENTRYPOINT ["/bin/sh"]
```

Push ke `ghcr.io/mutugading/backup-tools:YYYYMMDD` dan update CronJob:
```yaml
containers:
  - name: backup
    image: ghcr.io/mutugading/backup-tools:20260227  # Versi pinned
    # Hapus semua langkah download mc dari backup script
```

#### 9.5.2 Tambah Backup Monitoring Alert

Pastikan Prometheus alert untuk CronJob backup sudah ada dan routing ke email. Tambahkan ke `base/monitoring/alert-rules/postgres-alerts.yaml`:
```yaml
- alert: BackupCronJobNotRunning
  expr: |
    time() - kube_cronjob_status_last_schedule_time{
      namespace="database",
      cronjob=~"postgres-backup-.*"
    } > 86400  # 24 jam
  for: 30m
  labels:
    severity: critical
  annotations:
    summary: "Backup CronJob tidak pernah berjalan dalam 24 jam"
```

#### 9.5.3 Tambah Restore Procedure di Runbooks

Buat `docs/runbooks/restore-postgres.md` dengan langkah-langkah:
1. Cara mengidentifikasi backup terbaru (dari MinIO, B2, atau hostPath)
2. Cara restore dari pg_dump
3. Cara restore dengan PITR jika menggunakan CloudNativePG
4. Cara verifikasi restore berhasil (row counts, schema check)

#### 9.5.4 Test Restore Secara Berkala

Tambahkan ke CronJob atau GitHub Actions workflow sebuah `restore-test` yang:
1. Mengambil backup terbaru
2. Me-restore ke database temporary (bukan production)
3. Menjalankan query validation dasar
4. Melaporkan hasil ke Prometheus/Grafana

---

### 9.6 Code Quality & Consistency

#### 9.6.1 Rename `rabbitmq/deployment.yaml` → `statefulset.yaml`

```bash
git mv base/database/rabbitmq/deployment.yaml base/database/rabbitmq/statefulset.yaml
```

Update `base/database/rabbitmq/kustomization.yaml`:
```yaml
resources:
  - statefulset.yaml  # Sebelumnya: deployment.yaml
```

#### 9.6.2 Konsolidasi Fix Scripts

Buat `scripts/fix-environment.sh` yang parameterizable:
```bash
#!/bin/bash
set -e

ENVIRONMENT="${1:-staging}"

case "$ENVIRONMENT" in
  staging)
    DOMAIN="staging-goapps.mutugading.com"
    NAMESPACE="goapps-staging"
    ;;
  production)
    DOMAIN="goapps.mutugading.com"
    NAMESPACE="goapps-production"
    ;;
  *)
    echo "Usage: $0 [staging|production]"
    exit 1
    ;;
esac

echo "Fixing $ENVIRONMENT environment..."
# ... common logic
```

Hapus `fix-staging.sh` dan `fix-production.sh`.

#### 9.6.3 Sinkronisasi ArgoCD Project Source Repos

Update `argocd/projects/goapps-project.yaml`:
```yaml
spec:
  sourceRepos:
    - "https://github.com/mutugading/goapps-infra.git"
    - "https://github.com/ilramdhan/goapps-infra.git"  # Fork jika dipakai
```

Dan update `scripts/install-argocd.sh` untuk menggunakan canonical repo URL:
```bash
SOURCE_REPOS='["https://github.com/mutugading/goapps-infra.git"]'
```

#### 9.6.4 Dashboard — Hapus Duplikasi

Pilih salah satu pendekatan provisioning Grafana dashboard, **bukan keduanya**:

**Option A** — Gunakan raw JSON + create ConfigMap via script (pendekatan saat ini di install-monitoring.sh):
- Hapus `grafana-dashboard-go-apps-configmap.yaml` dan `grafana-dashboard-postgres-configmap.yaml`
- Tetap gunakan raw JSON + kustomize configMapGenerator

**Option B** — Gunakan ConfigMap YAML yang sudah ada (lebih GitOps-friendly):
- Hapus raw JSON processing dari script
- Pastikan ConfigMap YAML selalu sync dengan JSON

Rekomendasi: **Option B** — lebih GitOps, tidak butuh script runtime.

#### 9.6.5 Pin Semua Image Tags

Audit semua deployment dan pastikan tidak ada `:latest` atau tag mutable:

| Component | Saat Ini | Rekomendasi |
|-----------|----------|-------------|
| MinIO | `minio/minio:latest` | `minio/minio:RELEASE.2024-01-31T20-20-33Z` |
| MinIO mc | `minio/mc:latest` | `minio/mc:RELEASE.2024-01-31T08-59-40Z` |
| iam-service prod | `latest` | SHA via Image Updater |
| K3s install | latest (curl script) | Pin versi: `INSTALL_K3S_VERSION=v1.31.x+k3s1` |

#### 9.6.6 Fix Markdown di Deployment Guide

Di `docs/deployment-guide.md`, perbaiki code block yang tidak ditutup sebelum heading Step 9.2:
```markdown
# Pastikan ada closing ``` sebelum ### Step 9.2
```

---

### 9.7 Documentation & Runbooks

#### 9.7.1 Buat Runbooks Lengkap

Buat file-file berikut di `docs/runbooks/`:

**`docs/runbooks/postgres-restore.md`**:
- Restore dari backup harian
- Point-in-time recovery
- Verifikasi restore

**`docs/runbooks/service-down.md`**:
- Diagnosa service tidak available
- Rollback deployment ke versi sebelumnya via ArgoCD
- Force sync ArgoCD

**`docs/runbooks/node-failure.md`**:
- Recovery setelah VPS crash
- Restart K3s services
- Verifikasi storage integrity

**`docs/runbooks/certificate-renewal.md`**:
- Renew wildcard TLS certificate
- Update `minio-tls` secret
- Rolling restart affected deployments

**`docs/runbooks/database-connection-issues.md`**:
- Diagnosa connection pool exhaustion
- Restart PgBouncer safely
- Monitor active connections

**`docs/runbooks/backup-failure.md`**:
- Diagnosa backup CronJob gagal
- Manual backup trigger
- Verify backup integrity

#### 9.7.2 Lengkapi Secrets Documentation

Di `docs/vps-reset-guide.md`, tambahkan bagian lengkap untuk semua secrets:

```bash
# goapps-auth-secret (JWT)
kubectl create secret generic goapps-auth-secret \
  -n database \
  --from-literal=JWT_SECRET_KEY=$(openssl rand -base64 64) \
  --from-literal=JWT_REFRESH_SECRET=$(openssl rand -base64 64)

# smtp-secret
kubectl create secret generic smtp-secret \
  -n database \
  --from-literal=SMTP_HOST=smtp.gmail.com \
  --from-literal=SMTP_PORT=587 \
  --from-literal=SMTP_USER=your-email@gmail.com \
  --from-literal=SMTP_PASS=your-app-password

# minio-tls (generate self-signed atau import dari cert-manager)
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout tls.key \
  -out tls.crt \
  -subj "/CN=minio.minio.svc.cluster.local"
kubectl create secret tls minio-tls \
  -n minio \
  --cert=tls.crt \
  --key=tls.key

# iam-admin-seed-secret
kubectl create secret generic iam-admin-seed-secret \
  -n goapps-staging \
  --from-literal=admin-username=admin \
  --from-literal=admin-password=$(openssl rand -base64 24)
```

---

## 10. Roadmap Implementasi (Prioritas)

### Sprint 1 — Immediate (< 1 minggu) 🚨

Ini **wajib** dilakukan sebelum sistem dianggap aman di production:

| # | Action | File(s) | Effort |
|---|--------|---------|--------|
| 1 | **Revoke & rotate GitHub token yang bocor** | `.git/config` | 15 menit |
| 2 | **Fix Jaeger endpoint** ke namespace yang benar | `services/*/base/deployment.yaml` | 30 menit |
| 3 | **Fix iam-service tag** dari `latest` ke SHA | `argocd/apps/*/iam-service.yaml`, overlay | 1 jam |
| 4 | **Fix `finance-service` dan `iam-service`** connect via PgBouncer | `services/*/base/deployment.yaml` | 2 jam |
| 5 | **Fix sync-argocd.yml** — rename `infra-apps` ke `infra-database` | `.github/workflows/sync-argocd.yml` | 30 menit |
| 6 | **Tambah `grafana-alert-rules.yaml`** ke kustomization | `base/monitoring/alert-rules/kustomization.yaml` | 15 menit |
| 7 | **Dokumentasikan & buat** semua missing secrets | `docs/vps-reset-guide.md` | 2 jam |
| 8 | **Fix CORS MinIO production** dari `*` ke domain spesifik | `overlays/production/ingress.yaml` | 15 menit |

### Sprint 2 — High Priority (1-2 minggu) 🟠

| # | Action | Effort |
|---|--------|--------|
| 1 | Implement NetworkPolicy untuk semua namespace | 2 hari |
| 2 | Tambah PersistentVolumeClaim untuk Redis | 2 jam |
| 3 | Tambah PodDisruptionBudget untuk semua services | 2 jam |
| 4 | Buat root `kustomization.yaml` di overlays | 1 jam |
| 5 | Konfigurasi Alertmanager email routing | 3 jam |
| 6 | Tambah ArgoCD Basic Auth di production ingress | 1 jam |
| 7 | Buat custom backup Docker image (hapus runtime curl) | 4 jam |
| 8 | Rename `rabbitmq/deployment.yaml` → `statefulset.yaml` | 30 menit |
| 9 | Buat ArgoCD App untuk Jaeger dan Monitoring | 1 jam |
| 10 | Tambah rate limiting di ingress | 1 jam |
| 11 | Fix `backup-patch.yaml` duplikasi | 30 menit |
| 12 | Buat runbooks dasar (restore, service-down, node-failure) | 1 hari |

### Sprint 3 — Medium Priority (2-4 minggu) 🟡

| # | Action | Effort |
|---|--------|--------|
| 1 | Deploy CloudNativePG untuk PostgreSQL HA | 3 hari |
| 2 | Redis Sentinel atau persistence | 1 hari |
| 3 | MinIO versi pinned + evaluasi distributed mode | 4 jam |
| 4 | Loki stack config lengkap (retention, resource limits, auth) | 4 jam |
| 5 | Prometheus staging — tambah Basic Auth | 1 jam |
| 6 | Kurangi privilege Kubernetes Dashboard | 1 jam |
| 7 | Konsolidasi fix-scripts menjadi satu | 2 jam |
| 8 | Sinkronisasi ArgoCD project source repos | 30 menit |
| 9 | Buat Loki dashboard ConfigMap | 1 jam |
| 10 | Hapus duplikasi dashboard ConfigMap vs JSON | 1 jam |
| 11 | Tambah namespace labels untuk NetworkPolicy selector | 1 jam |
| 12 | Pin semua image tags (MinIO, tools) | 2 jam |

### Sprint 4 — Long-term Improvements (1-3 bulan) 🟢

| # | Action | Effort |
|---|--------|--------|
| 1 | Multi-node K3s cluster untuk true HA | 3-5 hari |
| 2 | Cert-manager untuk automatic TLS rotation | 1 hari |
| 3 | RabbitMQ clustering dengan quorum queues | 2 hari |
| 4 | Automated restore testing CronJob | 2 hari |
| 5 | OPA/Kyverno policy enforcement | 1 minggu |
| 6 | Vault/External Secrets Operator untuk secret management | 3 hari |
| 7 | Service mesh (Linkerd) untuk mTLS antar services | 1 minggu |
| 8 | GitOps untuk monitoring (ArgoCD manage Helm releases) | 2 hari |
| 9 | Lengkapi semua runbooks | 3 hari |
| 10 | Cost optimization review (VPA auto mode setelah stabil) | 1 hari |

---

## 11. Estimasi Effort per Item

### Summary Effort Total

| Sprint | Estimasi Effort | Risk Reduction |
|--------|----------------|----------------|
| Sprint 1 (Immediate) | ~6 jam | Eliminasi CRITICAL + sebagian HIGH |
| Sprint 2 (High Priority) | ~4 hari | Eliminasi semua HIGH + sebagian MEDIUM |
| Sprint 3 (Medium Priority) | ~1.5 minggu | Eliminasi semua MEDIUM |
| Sprint 4 (Long-term) | ~3-4 minggu | Production-grade penuh |

### ROI Tertinggi (Impact / Effort Ratio)

Berdasarkan analisis, item-item berikut memberikan dampak terbesar dengan effort terkecil:

| Item | Effort | Impact |
|------|--------|--------|
| Rotate GitHub token | 15 menit | Eliminasi CRITICAL security breach |
| Fix Jaeger namespace | 30 menit | Distributed tracing mulai berfungsi |
| Fix ArgoCD sync workflow | 30 menit | CI/CD pipeline tidak error lagi |
| Add grafana-alert-rules ke kustomization | 15 menit | 14 alert rules mulai aktif |
| Fix PgBouncer routing | 2 jam | Prevent DB connection exhaustion di load |
| Alertmanager email config | 3 jam | Alert mulai terkirim ke tim |
| NetworkPolicy | 2 hari | Drastis tingkatkan security posture |
| Redis PVC | 2 jam | Prevent session invalidation saat restart |

---

## Penutup

Infrastruktur GoApps memiliki **fondasi yang kuat** — GitOps dengan ArgoCD, monitoring komprehensif, backup multi-destinasi, dan dokumentasi yang di atas rata-rata. Ini bukan infrastruktur dari nol — sudah ada pola-pola yang benar.

Yang perlu dilakukan adalah:
1. **Segera** — perbaiki celah keamanan kritis dan inkonsistensi yang menyebabkan fitur tidak berfungsi (Jaeger, alerts, CI/CD sync)
2. **Short-term** — tambahkan NetworkPolicy, PDB, dan konfigurasi yang hilang untuk mencapai baseline security yang proper
3. **Medium-term** — implementasikan HA untuk PostgreSQL dan Redis untuk menghilangkan SPOF
4. **Long-term** — evolusi ke zero-trust dengan service mesh, secret management yang proper, dan automated DR testing

Dengan roadmap ini, infrastruktur akan mencapai level **production-grade, scalable, sustainable, dan secure** yang sesuai dengan standar industri.

---

*Laporan ini dibuat berdasarkan analisis statik dari repository. Beberapa temuan mungkin sudah ditangani di environment aktual namun belum di-commit ke Git. Selalu verifikasi temuan ini di environment aktual sebelum mengambil tindakan.*
