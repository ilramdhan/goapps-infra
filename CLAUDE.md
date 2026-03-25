# CLAUDE.md -- GoApps Infrastructure Repository

> Single source of truth for Claude Code working on `goapps-infra`.
> Read this before making any changes.

---

## Table of Contents

1. [Quick Overview](#1-quick-overview)
2. [Key Commands](#2-key-commands)
3. [Directory Structure](#3-directory-structure)
4. [Environments](#4-environments)
5. [Database Architecture](#5-database-architecture)
6. [Monitoring Stack](#6-monitoring-stack)
7. [Observability](#7-observability)
8. [Deployment Pattern](#8-deployment-pattern)
9. [ArgoCD Configuration](#9-argocd-configuration)
10. [Backup Strategy](#10-backup-strategy)
11. [CI/CD Pipelines](#11-cicd-pipelines)
12. [Secrets Management](#12-secrets-management)
13. [Linting and Validation](#13-linting-and-validation)
14. [Naming Conventions](#14-naming-conventions)
15. [Adding a New Service](#15-adding-a-new-service)
16. [Emergency Procedures](#16-emergency-procedures)
17. [Operational Lessons Learned](#17-operational-lessons-learned)

---

## 1. Quick Overview

This repository manages the Kubernetes infrastructure for the GoApps platform. It runs on **K3s** (lightweight Kubernetes) and uses **Kustomize** for manifest templating, **ArgoCD** for GitOps-based deployment, and a full monitoring stack (Prometheus, Grafana, Loki, Jaeger).

**What this repo controls:**
- Kubernetes namespaces and base infrastructure (databases, caches, message queues)
- Service deployments for finance-service, iam-service, and frontend
- Environment overlays for staging and production
- Monitoring, alerting, logging, and tracing
- Backup CronJobs for PostgreSQL and MinIO
- ArgoCD application definitions for GitOps sync
- Ingress and TLS configuration (NGINX + wildcard cert)

**What this repo does NOT do:**
- Application code (that lives in goapps-backend and goapps-frontend)
- Database migrations (run from goapps-backend via `make migrate-up`)
- Proto definitions (goapps-shared-proto)

---

## 2. Key Commands

### Makefile Targets

```bash
# Bootstrap and Installation
make bootstrap              # Initial K3s cluster setup from scratch
make install-monitoring     # Install Prometheus/Grafana/Loki stack
make install-argocd         # Install ArgoCD for GitOps

# Manual Apply (use ArgoCD in production, these are for emergency/initial setup)
make apply-base             # Apply namespaces + database + backup base configs
make apply-staging          # Apply base + staging overlays
make apply-production       # Apply base + production overlays

# Service Deployments (manual, prefer ArgoCD)
make deploy-finance-staging
make deploy-finance-production
make deploy-iam-staging
make deploy-iam-production

# Status and Monitoring
make status                 # Show nodes, pods (all namespaces), HPA, ArgoCD apps
make logs-postgres          # Tail PostgreSQL logs
make logs-argocd            # Tail ArgoCD server logs

# Port Forwarding
make port-forward-grafana   # Grafana UI on localhost:3000
make port-forward-argocd    # ArgoCD UI on localhost:8080

# Backup
make backup-now             # Trigger manual PostgreSQL backup CronJob

# Validation
make lint                   # Dry-run validate all base kustomizations

# Danger Zone
make reset                  # Uninstall K3s entirely (DESTRUCTIVE, requires confirmation)
```

### Kustomize Commands

```bash
# Validate a kustomization builds without errors
kustomize build base/database/
kustomize build services/finance-service/overlays/staging/
kustomize build overlays/staging/

# Apply a kustomization directly
kubectl apply -k services/finance-service/overlays/staging/

# Preview what would be applied
kustomize build services/frontend/overlays/production/ | kubectl diff -f -
```

### kubectl Quick Reference

```bash
# Check cluster state
kubectl get pods -A                          # All pods across namespaces
kubectl get pods -n goapps-staging           # Staging app pods
kubectl get pods -n database                 # Database pods
kubectl get hpa -A                           # All HorizontalPodAutoscalers
kubectl get pvc -A                           # All PersistentVolumeClaims
kubectl get cronjobs -n database             # Backup CronJobs

# Debug a pod
kubectl describe pod <pod> -n <namespace>
kubectl logs <pod> -n <namespace>
kubectl logs <pod> -n <namespace> --previous # Previous container (after crash)
kubectl top pod <pod> -n <namespace>         # Resource usage

# Database access
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps
kubectl exec -it postgres-0 -n database -- psql -U postgres -c "SELECT count(*) FROM pg_stat_activity"

# Rollback
kubectl rollout undo deployment/<name> -n <namespace>
kubectl rollout history deployment/<name> -n <namespace>
```

### ArgoCD Commands

ArgoCD CLI requires port-forwarding first (no direct CLI access in production):

```bash
# Port forward first
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# Then use argocd CLI
argocd app list
argocd app sync finance-service-staging
argocd app sync finance-service-production
argocd app get finance-service-staging
argocd app rollback <app-name>
```

### Bootstrap Scripts

```bash
./scripts/bootstrap.sh              # Full K3s setup from scratch
./scripts/install-nginx-ingress.sh  # NGINX Ingress Controller
./scripts/install-monitoring.sh     # Prometheus + Grafana + Loki
./scripts/install-argocd.sh         # ArgoCD + Image Updater
./scripts/install-image-updater.sh  # ArgoCD Image Updater standalone
./scripts/install-runner.sh         # GitHub Actions self-hosted runner
./scripts/finance-setup.sh          # Finance service initial setup
./scripts/iam-setup.sh              # IAM service initial setup
./scripts/validate-manifests.sh     # Validate all manifests
./scripts/fix-staging.sh            # Fix staging environment issues
./scripts/fix-production.sh         # Fix production environment issues
./scripts/reset-k3s.sh              # Uninstall K3s (DESTRUCTIVE)
```

---

## 3. Directory Structure

```
goapps-infra/
├── CLAUDE.md                          # This file
├── RULES.md                           # Development rules and conventions
├── Makefile                           # Common operations
├── .yamllint.yml                      # YAML lint configuration
│
├── base/                              # Base Kubernetes manifests (env-agnostic)
│   ├── namespaces/                    # Namespace definitions
│   │   ├── kustomization.yaml
│   │   └── namespaces.yaml            # database, monitoring, minio, goapps-staging, goapps-production
│   ├── database/
│   │   ├── kustomization.yaml         # Aggregates all database components
│   │   ├── postgres/                  # PostgreSQL 18 StatefulSet
│   │   │   ├── statefulset.yaml       # 20Gi PVC, custom postgresql.conf
│   │   │   ├── service.yaml
│   │   │   ├── configmap.yaml         # Init schemas, postgresql.conf
│   │   │   ├── vpa.yaml              # VerticalPodAutoscaler
│   │   │   └── kustomization.yaml
│   │   ├── pgbouncer/                 # PgBouncer connection pooler
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   ├── configmap.yaml         # Pool config (transaction mode, 100 pool)
│   │   │   ├── hpa.yaml
│   │   │   ├── vpa.yaml
│   │   │   └── kustomization.yaml
│   │   ├── redis/                     # Redis 7 (emptyDir, non-persistent)
│   │   │   ├── deployment.yaml
│   │   │   └── kustomization.yaml
│   │   ├── rabbitmq/                  # RabbitMQ 3 (5Gi PVC, management UI)
│   │   │   ├── deployment.yaml
│   │   │   └── kustomization.yaml
│   │   ├── exporter/                  # PostgreSQL Prometheus exporter
│   │   │   ├── deployment.yaml
│   │   │   ├── queries.yaml           # Custom metric queries
│   │   │   └── kustomization.yaml
│   │   └── oracle/                    # External Oracle DB references
│   │       ├── external-services.yaml
│   │       └── kustomization.yaml
│   ├── backup/
│   │   ├── kustomization.yaml
│   │   ├── cronjobs/                  # Backup CronJobs
│   │   │   ├── postgres-backup.yaml   # PostgreSQL 3x/day
│   │   │   ├── minio-backup.yaml      # MinIO daily
│   │   │   └── kustomization.yaml
│   │   ├── minio/                     # MinIO S3 storage (50Gi, TLS)
│   │   │   ├── deployment.yaml
│   │   │   └── kustomization.yaml
│   │   └── scripts/                   # Backup scripts (currently empty)
│   ├── monitoring/
│   │   ├── helm-values/
│   │   │   ├── prometheus-stack.yaml  # kube-prometheus-stack Helm values
│   │   │   └── loki-stack.yaml        # Loki + Promtail Helm values
│   │   ├── dashboards/                # Grafana dashboard JSON files
│   │   │   ├── grafana-dashboard-go-apps.json
│   │   │   ├── grafana-dashboard-go-apps-configmap.yaml
│   │   │   ├── grafana-dashboard-postgres.json
│   │   │   ├── grafana-dashboard-postgres-configmap.yaml
│   │   │   └── grafana-dashboard-loki.json
│   │   ├── datasources/
│   │   │   └── unified-datasources.yaml
│   │   └── alert-rules/               # Grafana/Prometheus alert rules
│   │       ├── grafana-alert-rules.yaml
│   │       ├── grafana-alertrules-configmap.yaml
│   │       ├── complete-alerts.yaml
│   │       ├── postgres-alerts.yaml
│   │       └── kustomization.yaml
│   ├── observability/
│   │   └── jaeger/                    # Jaeger all-in-one (OTLP, 10K traces in-memory)
│   │       ├── deployment.yaml
│   │       └── kustomization.yaml
│   ├── ingress/                       # NGINX Ingress + TLS
│   │   ├── tls-config.yaml            # Wildcard cert references
│   │   └── kustomization.yaml
│   ├── argocd/                        # ArgoCD NodePort service
│   │   ├── nodeport-service.yaml
│   │   └── kustomization.yaml
│   ├── argocd-image-updater/          # Auto image tag updates
│   │   └── kustomization.yaml
│   ├── kubernetes-dashboard/          # K8s Dashboard admin access
│   │   ├── admin-user.yaml
│   │   └── kustomization.yaml
│   └── secrets/                       # Secret TEMPLATES only (never real values)
│       ├── secrets-template.yaml
│       └── kustomization.yaml
│
├── overlays/                          # Environment-specific overrides for shared infra
│   ├── staging/
│   │   ├── ingress.yaml               # staging-goapps.mutugading.com
│   │   ├── backup-patch.yaml
│   │   ├── backup/
│   │   │   └── kustomization.yaml
│   │   └── minio/
│   │       ├── kustomization.yaml
│   │       └── minio-patch.yaml
│   └── production/
│       ├── ingress.yaml               # goapps.mutugading.com + Basic Auth on Prometheus
│       ├── backup-patch.yaml
│       ├── backup/
│       │   └── kustomization.yaml
│       └── minio/
│           ├── kustomization.yaml
│           └── minio-patch.yaml
│
├── services/                          # Application service deployments
│   ├── finance-service/
│   │   ├── base/
│   │   │   ├── deployment.yaml        # gRPC :50051, HTTP :8080, Metrics :8090
│   │   │   ├── service.yaml
│   │   │   ├── hpa.yaml               # min 1, max 5, 70% CPU
│   │   │   ├── ingress.yaml
│   │   │   ├── migrate-job.yaml       # DB migration Job
│   │   │   ├── seed-job.yaml          # Data seeder Job
│   │   │   ├── servicemonitor.yaml    # Prometheus ServiceMonitor
│   │   │   └── kustomization.yaml
│   │   └── overlays/
│   │       ├── staging/
│   │       │   ├── kustomization.yaml
│   │       │   └── patches/
│   │       │       ├── replicas.yaml
│   │       │       ├── resources.yaml
│   │       │       ├── env-cors.yaml
│   │       │       └── ingress-host.yaml
│   │       └── production/
│   │           ├── kustomization.yaml
│   │           └── patches/           # (same structure, higher resources)
│   ├── iam-service/
│   │   ├── base/
│   │   │   ├── deployment.yaml        # gRPC :50052, HTTP :8081, Metrics :8091
│   │   │   ├── service.yaml
│   │   │   ├── hpa.yaml
│   │   │   ├── ingress.yaml
│   │   │   ├── migrate-job.yaml
│   │   │   ├── seed-job.yaml          # Seeds admin user + menus + permissions
│   │   │   ├── servicemonitor.yaml
│   │   │   └── kustomization.yaml
│   │   └── overlays/
│   │       ├── staging/
│   │       │   ├── kustomization.yaml
│   │       │   └── patches/
│   │       │       ├── replicas.yaml
│   │       │       ├── resources.yaml
│   │       │       ├── env-cors.yaml
│   │       │       ├── env-storage.yaml  # MinIO/S3 config
│   │       │       └── ingress-host.yaml
│   │       └── production/
│   │           ├── kustomization.yaml
│   │           └── patches/
│   └── frontend/
│       ├── base/
│       │   ├── deployment.yaml        # HTTP :3000
│       │   ├── service.yaml
│       │   ├── hpa.yaml
│       │   ├── ingress.yaml
│       │   └── kustomization.yaml
│       └── overlays/
│           ├── staging/
│           │   ├── kustomization.yaml
│           │   └── patches/
│           │       ├── replicas.yaml
│           │       ├── resources.yaml
│           │       ├── env-backend.yaml   # gRPC host/port for BFF
│           │       └── ingress-host.yaml
│           └── production/
│               ├── kustomization.yaml
│               └── patches/
│
├── argocd/                            # ArgoCD application definitions
│   ├── projects/
│   │   └── goapps-project.yaml        # AppProject: allowed repos + destinations
│   └── apps/
│       ├── shared/
│       │   └── infra-apps.yaml        # Shared infra (database, monitoring, jaeger, image-updater)
│       ├── staging/
│       │   ├── finance-service.yaml   # Auto-sync, image updater annotations
│       │   ├── iam-service.yaml
│       │   ├── frontend.yaml
│       │   ├── infra-backup.yaml
│       │   └── infra-minio.yaml
│       └── production/
│           ├── finance-service.yaml   # Manual sync, requires approval
│           ├── iam-service.yaml
│           ├── frontend.yaml
│           ├── infra-backup.yaml
│           └── infra-minio.yaml
│
├── scripts/                           # Bootstrap and maintenance scripts
│   ├── bootstrap.sh                   # Full K3s cluster setup
│   ├── install-nginx-ingress.sh
│   ├── install-monitoring.sh
│   ├── install-argocd.sh
│   ├── install-image-updater.sh
│   ├── install-runner.sh              # GitHub self-hosted runner
│   ├── finance-setup.sh
│   ├── iam-setup.sh
│   ├── validate-manifests.sh
│   ├── fix-staging.sh
│   ├── fix-production.sh
│   └── reset-k3s.sh                  # DESTRUCTIVE: wipes cluster
│
├── docs/                              # Operational documentation
│   ├── deployment-guide.md
│   ├── INFRA_STABILITY_GUIDE.md
│   ├── LOCAL_VALIDATION_GUIDE.md
│   ├── vps-reset-guide.md
│   └── runbooks/
│
└── .github/
    ├── workflows/
    │   ├── ci.yml                     # Validate manifests + yamllint + Trivy scan
    │   ├── sync-argocd.yml            # Auto-sync staging, manual production
    │   └── health-check.yml           # Every 6 hours: nodes, pods, PVCs, backups
    ├── actions/
    │   └── install-argocd-cli/        # Reusable action for ArgoCD CLI
    ├── ISSUE_TEMPLATE/                # Bug, feature, incident, new-service templates
    └── PULL_REQUEST_TEMPLATE.md
```

---

## 4. Environments

| Property | Staging | Production |
|----------|---------|------------|
| Domain | `staging-goapps.mutugading.com` | `goapps.mutugading.com` |
| VPS | 4 CPU / 8GB RAM | 8 CPU / 16GB RAM |
| Namespace | `goapps-staging` | `goapps-production` |
| ArgoCD Sync | Automatic (prune + selfHeal) | Manual approval required |
| Service Replicas | 1 | 3 |
| Resource Limits | Lower (dev-friendly) | Higher (production-grade) |
| Backup Paths | `/staging-goapps-backup/` | `/goapps-backup/` |

### Namespace Layout

| Namespace | Purpose |
|-----------|---------|
| `database` | PostgreSQL, PgBouncer, Redis, RabbitMQ, exporters |
| `monitoring` | Prometheus, Grafana, Loki, Promtail |
| `observability` | Jaeger distributed tracing |
| `minio` | MinIO S3-compatible object storage |
| `argocd` | ArgoCD server and controllers |
| `ingress-nginx` | NGINX Ingress Controller |
| `goapps-staging` | Staging app pods (finance, iam, frontend) |
| `goapps-production` | Production app pods |

### Deployment Rules

1. **Always test in staging first** -- minimum 24 hours before production
2. Production sync requires manual approval via ArgoCD or workflow dispatch
3. Use overlays for environment differences -- never duplicate base manifests

---

## 5. Database Architecture

### PostgreSQL 18

- **Type**: StatefulSet (single pod)
- **Storage**: 20Gi PersistentVolumeClaim
- **Access**: `postgres.database.svc.cluster.local:5432` (internal only)
- **Schemas**: `finance`, `auth`, `hr`, `export`
- **Timezone**: `Asia/Jakarta`

Key configuration (`configmap.yaml`):

| Setting | Value | Purpose |
|---------|-------|---------|
| `max_connections` | 100 (configmap) / 150 (RULES.md target) | PgBouncer pooling + direct |
| `shared_buffers` | 256MB | ~25% of available RAM |
| `work_mem` | 16MB | Per-operation sort/hash memory |
| `maintenance_work_mem` | 128MB | VACUUM, CREATE INDEX |

### PgBouncer (Connection Pooler)

- **Mode**: Transaction pooling
- **Pool size**: 100 connections
- **Access**: `pgbouncer.database.svc.cluster.local:5432`
- **HPA**: Enabled
- **VPA**: Enabled

**All services MUST connect via PgBouncer, never directly to PostgreSQL.**

```yaml
# CORRECT
DATABASE_HOST: "pgbouncer.database.svc.cluster.local"
DATABASE_PORT: "5432"

# WRONG -- never do this in services
DATABASE_HOST: "postgres.database.svc.cluster.local"
```

### Redis 7

- **Type**: Deployment (non-StatefulSet)
- **Storage**: emptyDir (data lost on restart -- cache only)
- **Access**: `redis.database.svc.cluster.local:6379`
- **DB 0**: Application cache
- **DB 1**: Token blacklist (shared between IAM and other services for JWT invalidation)

### RabbitMQ 3

- **Storage**: 5Gi PVC
- **Management UI**: Port 15672
- **Note**: Single pod (no clustering) -- single point of failure risk

### Adding a New Schema

Edit `base/database/postgres/configmap.yaml` and add to `init-schemas.sql`:

```sql
CREATE SCHEMA IF NOT EXISTS new_schema;
GRANT ALL PRIVILEGES ON SCHEMA new_schema TO postgres;
```

Then restart PostgreSQL (data is preserved):

```bash
kubectl rollout restart statefulset/postgres -n database
```

---

## 6. Monitoring Stack

Installed via Helm charts. Configuration in `base/monitoring/helm-values/`.

### Prometheus (kube-prometheus-stack)

- **Retention**: 30 days
- **Storage**: 20Gi PVC
- **ServiceMonitor**: Auto-discovery enabled (services with `release: prometheus` label)
- **Scrape interval**: 30s default

### Grafana

- **Storage**: 10Gi PVC
- **SMTP**: Configured for email alerts
- **Dashboards** (auto-loaded via sidecar with `grafana_dashboard: "1"` label):
  - GoApps Service Dashboard (`grafana-dashboard-go-apps.json`)
  - PostgreSQL Dashboard (`grafana-dashboard-postgres.json`)
  - Loki Log Dashboard (`grafana-dashboard-loki.json`)
- **Datasources**: Prometheus + Loki (configured in `datasources/unified-datasources.yaml`)

### Loki + Promtail

- **Purpose**: Centralized log aggregation
- **Helm values**: `base/monitoring/helm-values/loki-stack.yaml`
- **Promtail**: DaemonSet that ships logs from all pods to Loki

### Alert Rules

Located in `base/monitoring/alert-rules/`:
- `grafana-alert-rules.yaml` -- Application-level alerts
- `postgres-alerts.yaml` -- PostgreSQL-specific alerts
- `complete-alerts.yaml` -- Comprehensive alert set

To add a new alert, create a ConfigMap with the `grafana_dashboard: "1"` label or edit the existing alert rule files.

### Adding a ServiceMonitor for a New Service

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-service-monitor
  namespace: monitoring
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app: my-service
  namespaceSelector:
    matchNames:
      - goapps-staging
      - goapps-production
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
```

---

## 7. Observability

### Jaeger (Distributed Tracing)

- **Deployment**: All-in-one (collector + query + UI in single pod)
- **Protocol**: OTLP (OpenTelemetry)
- **Collector endpoint**: `jaeger-collector.observability.svc.cluster.local:4317`
- **Storage**: In-memory only (10,000 traces max)
- **Namespace**: `observability`

Services configure tracing via environment variables:

```yaml
TRACING_ENABLED: "true"
JAEGER_ENDPOINT: "jaeger-collector.observability.svc.cluster.local:4317"
```

---

## 8. Deployment Pattern

Every service follows the **base + overlays** pattern with Kustomize:

```
services/<service-name>/
├── base/                    # Environment-agnostic manifests
│   ├── kustomization.yaml   # Lists all resources + commonLabels
│   ├── deployment.yaml      # Container spec, ports, probes, base env vars
│   ├── service.yaml         # ClusterIP service (gRPC, HTTP, metrics ports)
│   ├── hpa.yaml             # HPA: min 1, max 5, 70% CPU, 80% memory
│   ├── ingress.yaml         # Ingress rules (host set via overlay patch)
│   ├── migrate-job.yaml     # One-time DB migration Job (optional)
│   ├── seed-job.yaml        # One-time data seed Job (optional)
│   └── servicemonitor.yaml  # Prometheus scrape config
└── overlays/
    ├── staging/
    │   ├── kustomization.yaml    # namespace: goapps-staging, image tag, patches
    │   └── patches/
    │       ├── replicas.yaml     # 1 replica
    │       ├── resources.yaml    # Lower CPU/memory limits
    │       ├── env-cors.yaml     # Staging CORS origins
    │       └── ingress-host.yaml # staging-goapps.mutugading.com
    └── production/
        ├── kustomization.yaml    # namespace: goapps-production
        └── patches/
            ├── replicas.yaml     # 3 replicas
            ├── resources.yaml    # Higher CPU/memory limits
            ├── env-cors.yaml     # Production CORS origins
            └── ingress-host.yaml # goapps.mutugading.com
```

### Service Ports Convention

| Service | gRPC | HTTP/Gateway | Metrics |
|---------|------|-------------|---------|
| finance-service | 50051 | 8080 | 8090 |
| iam-service | 50052 | 8081 | 8091 |
| frontend | -- | 3000 | -- |

### Health Probes

Backend services use gRPC health checks:

```yaml
livenessProbe:
  grpc:
    port: 50051
  initialDelaySeconds: 30
  periodSeconds: 10
readinessProbe:
  grpc:
    port: 50051
  initialDelaySeconds: 5
  periodSeconds: 5
```

Frontend uses HTTP health checks on port 3000.

### Image Pull

All images come from `ghcr.io/mutugading/` and require `imagePullSecrets`:

```yaml
imagePullSecrets:
  - name: ghcr-secret
```

---

## 9. ArgoCD Configuration

### Project

Defined in `argocd/projects/goapps-project.yaml`:
- **Source repos**: `goapps-infra.git`, `goapps-backend.git`
- **Destinations**: All namespaces on the local cluster
- **Role**: `admin` role for `goapps-admins` group

### Application Definitions

Located in `argocd/apps/`:

| Application | Path | Sync Policy |
|-------------|------|-------------|
| `infra-apps` (shared) | `argocd/apps/shared/` | Covers database, monitoring, jaeger, image-updater |
| `finance-service-staging` | `services/finance-service/overlays/staging` | Auto (prune + selfHeal) |
| `iam-service-staging` | `services/iam-service/overlays/staging` | Auto (prune + selfHeal) |
| `frontend-staging` | `services/frontend/overlays/staging` | Auto (prune + selfHeal) |
| `finance-service-production` | `services/finance-service/overlays/production` | Manual |
| `iam-service-production` | `services/iam-service/overlays/production` | Manual |
| `frontend-production` | `services/frontend/overlays/production` | Manual |
| `infra-backup-staging` | Staging backup overlay | Auto |
| `infra-minio-staging` | Staging MinIO overlay | Auto |
| `infra-backup-production` | Production backup overlay | Manual |
| `infra-minio-production` | Production MinIO overlay | Manual |

### ArgoCD Image Updater

Automatically detects new Docker image tags and updates Kustomize overlays:

```yaml
# Annotations on ArgoCD Application resources:
argocd-image-updater.argoproj.io/image-list: finance=ghcr.io/mutugading/finance-service
argocd-image-updater.argoproj.io/finance.update-strategy: newest-build
argocd-image-updater.argoproj.io/finance.allow-tags: regexp:^[a-f0-9]{7,40}$
argocd-image-updater.argoproj.io/write-back-method: git:secret:argocd/git-creds
argocd-image-updater.argoproj.io/write-back-target: kustomization
argocd-image-updater.argoproj.io/git-branch: main
```

Flow: New image pushed to GHCR (Git SHA tag) -> Image Updater detects it -> Updates `kustomization.yaml` in git -> ArgoCD syncs the change to cluster.

### Sync Retry Policy

All staging apps have retry with exponential backoff:

```yaml
retry:
  limit: 5
  backoff:
    duration: 10s
    factor: 2
    maxDuration: 3m
```

---

## 10. Backup Strategy

| Target | Frequency | Schedule (WIB) | Retention | Destinations |
|--------|-----------|----------------|-----------|-------------|
| PostgreSQL | 3x daily | 06:00, 14:00, 22:00 | 7 days | MinIO + Backblaze B2 + VPS disk |
| MinIO buckets | Daily | 03:00 | 7 days | VPS disk |

### Backup CronJobs

Defined in `base/backup/cronjobs/`:
- `postgres-backup.yaml` -- Three CronJobs (morning, afternoon, evening)
- `minio-backup.yaml` -- Daily MinIO bucket backup

### Manual Backup

```bash
make backup-now
# Creates a one-off Job from the morning CronJob template
```

### Backup Verification (Weekly Checklist)

```bash
kubectl get cronjobs -n database              # Check schedules and last run
kubectl get jobs -n database                  # Check recent job status
# Verify MinIO bucket contents
# Verify Backblaze B2 console
# Check VPS disk: ls -la /mnt/goapps-backup/postgres/
```

### Restore Testing (Monthly)

```bash
# 1. Get latest backup
BACKUP=$(ls -t /mnt/stgapps-backup/postgres/*.sql.gz | head -1)

# 2. Create test database
kubectl exec -it postgres-0 -n database -- psql -U postgres -c "CREATE DATABASE goapps_restore_test"

# 3. Restore
kubectl exec -it postgres-0 -n database -- bash -c "gunzip -c ${BACKUP} | psql -U postgres -d goapps_restore_test"

# 4. Verify tables exist and have data
# 5. Drop test database
kubectl exec -it postgres-0 -n database -- psql -U postgres -c "DROP DATABASE goapps_restore_test"
```

---

## 11. CI/CD Pipelines

### CI Pipeline (`.github/workflows/ci.yml`)

Triggered on: push to `main`/`develop`, PRs to `main`.

| Job | What it does |
|-----|-------------|
| `validate` | `kustomize build` on all base/, overlays/, and service manifests |
| `lint` | `yamllint` with `.yamllint.yml` config (non-blocking currently) |
| `security` | Trivy config scan for CRITICAL/HIGH issues (non-blocking currently) |

### ArgoCD Sync Pipeline (`.github/workflows/sync-argocd.yml`)

Triggered on: push to `main` (paths: `base/**`, `overlays/**`, `services/**`, `argocd/**`) or manual dispatch.

- **Staging**: Automatic on push. Runs on self-hosted runner (`staging` label). Syncs `infra-apps`, `finance-service-staging`, `frontend-staging`, `iam-service-staging`. Waits for healthy (600s timeout).
- **Production**: Manual dispatch only (choose `production` or `all`). Runs on self-hosted runner (`production` label). Requires `sync-staging` to succeed first when using `all`.

Authentication: Uses `ARGOCD_AUTH_TOKEN` secrets (`ARGOCD_TOKEN_STAGING`, `ARGOCD_TOKEN_PRODUCTION`). ArgoCD CLI runs inside the ArgoCD server pod via `kubectl exec`.

### Health Check Pipeline (`.github/workflows/health-check.yml`)

Triggered: Every 6 hours (cron) or manual dispatch.

Checks per environment:
- Node status (Ready/NotReady)
- Critical pod status (CrashLoopBackOff detection)
- PVC status
- CronJob and backup job status

Production checks are stricter (exit 1 on failures vs warnings for staging).

---

## 12. Secrets Management

**Golden Rule: NEVER commit secrets to Git.**

### Secret Templates

`base/secrets/secrets-template.yaml` contains placeholder templates showing required secret keys. These are NOT real values.

### Creating Secrets in Cluster

```bash
# PostgreSQL
kubectl create secret generic postgres-secret -n database \
  --from-literal=POSTGRES_USER='postgres' \
  --from-literal=POSTGRES_PASSWORD='<password>' \
  --from-literal=POSTGRES_DB='goapps'

# JWT Auth
kubectl create secret generic goapps-auth-secret -n goapps-staging \
  --from-literal=JWT_ACCESS_SECRET='<secret>' \
  --from-literal=JWT_REFRESH_SECRET='<secret>'

# GHCR Image Pull
kubectl create secret docker-registry ghcr-secret -n goapps-staging \
  --docker-server=ghcr.io \
  --docker-username=<user> \
  --docker-password=<token>

# TLS Wildcard
kubectl create secret tls goapps-tls -n <namespace> \
  --cert=tls.crt --key=tls.key

# MinIO
kubectl create secret generic minio-secret -n minio \
  --from-literal=MINIO_ROOT_USER='<user>' \
  --from-literal=MINIO_ROOT_PASSWORD='<password>'
```

### Secrets Inventory

| Secret | Namespace(s) | Keys |
|--------|-------------|------|
| `postgres-secret` | `database` | POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB |
| `goapps-auth-secret` | `goapps-staging`, `goapps-production` | JWT_ACCESS_SECRET, JWT_REFRESH_SECRET |
| `goapps-tls` | multiple | tls.crt, tls.key (wildcard cert) |
| `ghcr-secret` | `goapps-staging`, `goapps-production` | .dockerconfigjson |
| `minio-secret` | `minio`, `database` | MINIO_ROOT_USER, MINIO_ROOT_PASSWORD |
| `grafana-admin-secret` | `monitoring` | admin-user, admin-password |
| `grafana-smtp-secret` | `monitoring` | password |
| `git-creds` | `argocd` | Used by ArgoCD Image Updater for git write-back |

### Referencing Secrets in Deployments

```yaml
env:
  - name: DATABASE_PASSWORD
    valueFrom:
      secretKeyRef:
        name: postgres-secret
        key: POSTGRES_PASSWORD
```

---

## 13. Linting and Validation

### yamllint Configuration (`.yamllint.yml`)

```yaml
extends: default
rules:
  line-length:
    max: 200            # Generous for K8s manifests
    level: warning
  truthy:
    allowed-values: ['true', 'false', 'yes', 'no']
  comments:
    min-spaces-from-content: 1
  indentation:
    spaces: 2
    indent-sequences: true
  document-start: disable
  empty-lines:
    max: 2
ignore: |
  .git/
  node_modules/
```

### Validation Commands

```bash
# Lint all YAML
yamllint -c .yamllint.yml .

# Validate specific kustomization
kustomize build base/database/
kustomize build services/finance-service/overlays/staging/

# Dry-run against cluster
kubectl apply --dry-run=client -k base/database/

# Full manifest validation script
./scripts/validate-manifests.sh

# Trivy security scan
trivy config --severity CRITICAL,HIGH .
```

### CI Validation

The CI pipeline (`ci.yml`) runs three validation jobs on every push/PR:
1. **Validate Manifests** -- `kustomize build` on every directory with a `kustomization.yaml`
2. **Lint YAML** -- `yamllint` (currently non-blocking with `|| true`)
3. **Security Scan** -- Trivy config scan for CRITICAL/HIGH (currently non-blocking)

---

## 14. Naming Conventions

### Kubernetes Resources

| Resource | Pattern | Examples |
|----------|---------|---------|
| Namespace | `<purpose>` or `<app>-<env>` | `database`, `monitoring`, `goapps-staging` |
| Deployment | `<service-name>` | `finance-service`, `frontend`, `pgbouncer` |
| StatefulSet | `<app-name>` | `postgres`, `rabbitmq` |
| Service | `<deployment-name>` | `finance-service`, `postgres`, `redis` |
| ConfigMap | `<app>-config` | `postgres-config`, `grafana-config` |
| Secret | `<app>-secret` | `postgres-secret`, `minio-secret` |
| HPA | `<deployment>-hpa` | `finance-service-hpa`, `pgbouncer-hpa` |
| VPA | `<deployment>-vpa` | `postgres-vpa`, `pgbouncer-vpa` |
| PVC | `<app>-data` | `postgres-data`, `grafana-data` |
| CronJob | `<purpose>-<schedule>` | `postgres-backup-morning`, `minio-backup-daily` |
| Ingress | `<app>-ingress` | `grafana-ingress`, `argocd-ingress` |
| ServiceMonitor | `<service>-monitor` | `finance-service-monitor` |

### ArgoCD Application Names

| Pattern | Examples |
|---------|---------|
| `<service>-<env>` | `finance-service-staging`, `frontend-production` |
| `infra-<component>` | `infra-database`, `infra-monitoring`, `infra-backup` |

### Required Labels (All Resources)

```yaml
labels:
  app: <service-name>
  app.kubernetes.io/name: <service-name>
  app.kubernetes.io/part-of: goapps
  app.kubernetes.io/component: <type>    # backend, frontend, database, cache, queue
```

### Required Annotations (Prometheus Scraping)

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8090"
  prometheus.io/path: "/metrics"
```

### Git Conventions

Branch names: `infra/<description>`, `feat/<service>`, `fix/<issue>`, `hotfix/<issue>`

Commit format: `<type>(<scope>): <description>`
- Types: `feat`, `fix`, `docs`, `chore`, `refactor`, `perf`
- Examples: `feat(iam-service): add staging deployment`, `fix(backup): correct minio endpoint`

---

## 15. Adding a New Service

Follow these steps in order:

### Step 1: Create Directory Structure

```bash
SERVICE_NAME="my-service"
mkdir -p services/${SERVICE_NAME}/{base,overlays/{staging,production}/patches}
```

### Step 2: Create Base Manifests

Create these files in `services/${SERVICE_NAME}/base/`:
- `deployment.yaml` -- Container spec with gRPC/HTTP/metrics ports, probes, env vars, resource limits
- `service.yaml` -- ClusterIP service exposing gRPC (50051), HTTP (8080), metrics (8090)
- `hpa.yaml` -- HPA with min 1, max 5, CPU 70%, memory 80%
- `kustomization.yaml` -- Lists resources + commonLabels
- `servicemonitor.yaml` -- Prometheus scrape config (optional)
- `ingress.yaml` -- Ingress rules (optional, host set via overlay patch)

Use existing services (`finance-service` or `iam-service`) as templates.

### Step 3: Create Overlays

Staging overlay (`overlays/staging/kustomization.yaml`):
- Set `namespace: goapps-staging`
- Reference `../../base`
- Add patches for replicas, resources, env, ingress host
- Set image tag

Production overlay: same structure with higher resources, 3 replicas, production domain.

### Step 4: Create ArgoCD Application

Add `argocd/apps/staging/<service>.yaml` and `argocd/apps/production/<service>.yaml`.

Staging gets `syncPolicy.automated` with prune + selfHeal. Production gets no automated sync (manual).

Include ArgoCD Image Updater annotations for automatic image tag updates.

### Step 5: Add Database Schema (If Needed)

Edit `base/database/postgres/configmap.yaml` to add the new schema.

### Step 6: Add to Sync Workflow

Update `.github/workflows/sync-argocd.yml` to include the new service in the sync steps.

---

## 16. Emergency Procedures

### Pod CrashLoopBackOff

```bash
kubectl describe pod <pod> -n <namespace>       # Check events
kubectl logs <pod> -n <namespace>                # Current logs
kubectl logs <pod> -n <namespace> --previous     # Previous crash logs
kubectl top pod <pod> -n <namespace>             # Check for OOM
kubectl rollout undo deployment/<name> -n <namespace>  # Rollback
```

### Database Connection Issues

```bash
kubectl get pods -n database -l app=postgres     # Check PostgreSQL
kubectl get pods -n database -l app=pgbouncer    # Check PgBouncer
kubectl logs postgres-0 -n database --tail=100
kubectl logs deploy/pgbouncer -n database
kubectl exec -it postgres-0 -n database -- psql -U postgres -c "SELECT count(*) FROM pg_stat_activity"
```

### Dirty Migration Fix

If a migration fails and leaves the schema_migrations table dirty:

```bash
kubectl exec -it postgres-0 -n database -- psql -U postgres -d goapps -c \
  "UPDATE schema_migrations_<service> SET dirty = false"
```

### Rollback Deployment

```bash
# Via kubectl
kubectl rollout undo deployment/<name> -n <namespace>
kubectl rollout undo deployment/<name> -n <namespace> --to-revision=2

# Via ArgoCD
argocd app rollback <app-name>
```

---

## 17. Operational Lessons Learned

These are hard-won lessons from production operations:

| Area | Lesson |
|------|--------|
| RabbitMQ | Needs minimum 500m CPU, 512Mi memory, 30s probe timeouts. Always add `startupProbe`. |
| Frontend (Next.js) | Minimum 500m CPU limit or pod will cycle continuously. |
| Dirty migrations | Fix with `UPDATE schema_migrations_{service} SET dirty = false` in psql. |
| Old K8s Jobs | Failed Jobs from old CronJob runs trigger Grafana backup alerts. Delete stale jobs manually. |
| ArgoCD CLI | Requires port-forward first. Production has no CLI -- use the ArgoCD dashboard. |
| Kustomize commonLabels | Adding to existing deployments breaks them (immutable label selector). Only set on initial creation. |
| VPA CRD | Must be installed in the cluster before any VPA resource is referenced in `kustomization.yaml`. |
| Redis emptyDir | Data is lost on pod restart. Do not store anything that cannot be regenerated. |
| NetworkPolicies | Required by RULES.md but not yet implemented -- known gap. |
| Backup CronJob env | Currently hardcoded to "production" label even in staging -- known bug. |
