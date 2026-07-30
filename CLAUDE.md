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

# Database access per-environment (single shared postgres-0, not per-service):
# `goapps` and `ppc_db` are two DATABASES inside the SAME postgres instance --
# not two servers. One tunnel per environment reaches both; only `-d` changes.
# | Env        | Pod          | User      | Database | IAM tables schema |
# | Local      | -            | iam/finance | iam_db/finance_db | public |
# | Staging    | postgres-0   | stgapps   | goapps / ppc_db | public |
# | Production | postgres-0   | (check secret) | goapps / ppc_db | public |
kubectl exec -it postgres-0 -n database -- psql -U stgapps -d goapps -c "SELECT * FROM public.mst_user LIMIT 5;"
kubectl exec -it postgres-0 -n database -- psql -U stgapps -d goapps -c "\dn"   # list schemas
kubectl exec -it postgres-0 -n database -- psql -U stgapps -d ppc_db -c "\dt"   # PPC tables
kubectl exec -it deploy/iam-service -n goapps-staging -- /app/migrate -path /app/migrations -database "$DATABASE_URL" up

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
./scripts/ppc-setup.sh              # PPC service initial setup (see below)
./scripts/validate-manifests.sh     # Validate all manifests
./scripts/fix-staging.sh            # Fix staging environment issues
./scripts/fix-production.sh         # Fix production environment issues
./scripts/reset-k3s.sh              # Uninstall K3s (DESTRUCTIVE)
```

#### PPC setup (`ppc-setup.sh`)

PPC owns a dedicated `ppc_db` database, so it needs an extra `createdb` step the other services do not:

```bash
./scripts/ppc-setup.sh <namespace> [createdb|migrate|seed|all]

./scripts/ppc-setup.sh goapps-staging createdb   # create ppc_db (idempotent; NO deployment needed)
./scripts/ppc-setup.sh goapps-staging migrate    # needs a running ppc-service (image tag read from it)
./scripts/ppc-setup.sh goapps-staging seed       # staging/dev only
./scripts/ppc-setup.sh goapps-staging all        # createdb + migrate + seed
```

**Production: `createdb` + `migrate` only — never `seed`.** Full procedure in `docs/runbooks/ppc-service-deployment.md`.

Job `component=` labels are `createdb`, `migration`, `seeder` (not `migrate`/`seed`); `ppc-setup.sh` passes them explicitly. `iam-setup.sh` derives them from the job name and therefore matches nothing — masked by `|| true`, so it silently waits out its 60s timeout. Known, unfixed.

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
│       ├── ppc-service-deployment.md      # New-service deployment, end to end
│       ├── database-port-forward.md       # Tunnel goapps / ppc_db to localhost
│       └── monitoring-alerting-activation-2026-07.md
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

**All services on the shared `goapps` database MUST connect via PgBouncer, never directly to PostgreSQL.**

**Documented exception — PPC.** PgBouncer is configured with `DB_NAME: goapps` and no `[databases]` block, so it cannot front `ppc_db` at all. `ppc-service` therefore connects directly to `postgres.database.svc.cluster.local:5432` (see `services/ppc-service/base/deployment.yaml`). This is acceptable because PPC's HPA is pinned `minReplicas: 1 / maxReplicas: 1`, capping its connection count. If PPC is ever scaled past 1 replica, add a `[databases]` entry for `ppc_db` to PgBouncer first.

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
- **DB 0**: Application cache (including email verification OTPs)
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
- **ServiceMonitor**: Auto-discovery enabled for **all** ServiceMonitors in **all** namespaces. `serviceMonitorSelectorNilUsesHelmValues: false` is set in `base/monitoring/helm-values/prometheus-stack.yaml`, so a `release: prometheus` label is **NOT** required (an earlier version of this doc claimed it was — it is false for this cluster).
- **Scrape interval**: 30s default

### Grafana

- **Storage**: 10Gi PVC
- **SMTP**: Configured for email alerts
- **Dashboards** (auto-loaded via sidecar with `grafana_dashboard: "1"` label):
  - GoApps Service Dashboard (`grafana-dashboard-go-apps.json`)
  - PostgreSQL Dashboard (`grafana-dashboard-postgres.json`)
  - Loki Log Dashboard (`grafana-dashboard-loki.json`)
- **Datasources**: Prometheus + Loki — managed EXCLUSIVELY via Helm values (`grafana.additionalDataSources` in `helm-values/prometheus-stack.yaml`); never apply datasource ConfigMaps (see INFRA_STABILITY_GUIDE.md)

### Loki + Promtail

- **Purpose**: Centralized log aggregation
- **Helm values**: `base/monitoring/helm-values/loki-stack.yaml`
- **Promtail**: DaemonSet that ships logs from all pods to Loki

### Alert Rules

Located in `base/monitoring/alert-rules/`. Only these are in `kustomization.yaml`:
- `complete-alerts.yaml` -- Comprehensive alert set (Grafana **unified-alerting** rules, keyed by `title:`, not Prometheus `alert:` rules)
- `postgres-alerts.yaml` -- PostgreSQL-specific alerts (includes a `ppc_db` deadlock rule alongside the `goapps` one)
- `cost-calc-alerts.yaml` -- finance-cost-worker specific
- `grafana-alertrules-configmap.yaml` -- `deleteRules:` tombstone; do not remove, do not extend

`grafana-alert-rules.yaml` also exists in that directory but is **not** in `kustomization.yaml` and is applied by nothing. Leave it alone.

To add a new alert, create a ConfigMap with the **`grafana_alert: "1"`** label (NOT `grafana_dashboard: "1"` — that label is for dashboards) or edit the existing alert rule files.

⚠️ **Additive only.** `base/monitoring/` is under no ArgoCD Application (see §9) — nothing reconciles it and nothing restores it. Never regenerate a dashboard JSON from a Grafana export; edit surgically.

### Adding a ServiceMonitor for a New Service

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-service-monitor
  namespace: monitoring
  # No `release: prometheus` label needed — Prometheus selects all
  # ServiceMonitors in all namespaces (see above).
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

Name the endpoint after an **existing** ServicePort. A service whose gateway serves `/metrics` on the same port as its API (ppc-service: both on 8082) has **no** separate `metrics` port — Kubernetes enforces ServicePort uniqueness on `(protocol, port)`, not on name, so a second 8082 entry makes the whole Service unappliable. Use `port: http` there.

### `base/monitoring/` IS OUTSIDE GITOPS -- apply it by hand, on BOTH hosts

**No ArgoCD Application manages `base/monitoring`.** `argocd/apps/shared/infra-apps.yaml` covers only `base/database` and `base/observability/jaeger`; no workflow applies the directory either:

```bash
grep -rn "base/monitoring" argocd/     # returns nothing
```

So dashboards and alert rules reach a cluster **only** via a manual `kubectl apply`, and "sync the Application" is not a fix — there is no Application to sync. What runs in the cluster is a snapshot of whoever last applied it, which is why `ppc-service` was missing from the dashboard filter for weeks while being correct in git.

Staging and production are **separate clusters** — run the apply on both hosts:

```bash
kubectl apply -f base/monitoring/dashboards/grafana-dashboard-go-apps-configmap.yaml
```

The file is environment-agnostic (there is no production overlay, and `namespace: monitoring` is hardcoded inside it). The dashboard's own `namespace` variable carries **both** `goapps-staging` and `goapps-production` with staging pre-selected, so the same ConfigMap ships to both clusters and you switch environment from the dropdown *inside* Grafana — production's Grafana defaulting to `goapps-staging` is expected, not a mis-apply.

Two consequences worth internalizing:

- **No `selfHeal`.** An in-cluster edit is never reverted from git, and a git change is never auto-applied. Permanent drift risk — but also why the Grafana alert config has never been silently overwritten by a sync.
- Applying a **single dashboard ConfigMap** is safe (one resource, one data key, in-place update, no `--prune`, not `-k`). What is *not* safe, and must never be done casually, is `kubectl apply -k base/monitoring/alert-rules/`, any `delete`, or regenerating these files from a Grafana export.

### Dashboard service filter is a HARDCODED list -- add every new service by hand

The `service` template variable in `base/monitoring/dashboards/grafana-dashboard-go-apps.json` is **`type: custom`** — a literal comma-separated list, not a Prometheus `label_values()` query:

```json
"query": "finance-service,iam-service,ppc-service,frontend",
```

**There is no auto-discovery.** A new service emitting perfectly good metrics simply never appears in the dropdown until its name is added to that string. Edit **both** the `.json` and the `-configmap.yaml` beside it — Grafana's sidecar reads the ConfigMap; the loose `.json` is only the source copy, and they drift silently.

If a service is present in the ConfigMap but still missing from the dropdown, Grafana has stale state rather than stale config:

```bash
kubectl get cm grafana-dashboard-go-apps -n monitoring \
  -o jsonpath='{.data.go-apps-microservices\.json}' | grep -o 'finance-service,iam-service[^"]*'
```

Missing there ⇒ sync the `infra-apps` Application. Present there ⇒ `kubectl rollout restart deploy/prometheus-grafana -n monitoring`.

### Alerting is namespace-scoped, NOT per-service -- new services are covered automatically

`base/monitoring/alert-rules/complete-alerts.yaml` selects on namespace, never on service name:

```
KubePodCrashLooping   kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff", namespace!~"database"}
KubePodNotReady       kube_pod_status_phase{phase="Pending", namespace=~"goapps-staging|goapps-production|..."}
KubeDeploymentReplicasMismatch, PodOOMKilled, PodRestartingTooOften, HPAMaxedOut, ...
```

Any Deployment in `goapps-staging` / `goapps-production` inherits all of them the moment it exists. **Silence after a rollout means the rollout succeeded** — these rules fire only on `CrashLoopBackOff`, `Pending`, unavailable replicas, or OOMKills. The email flood people associate with "a new image went out" is the signature of a *failing* rollout, not a routine notification. Do not read a quiet inbox as missing coverage.

Only genuinely service-specific alerts need authoring (e.g. `ppc_db` size/connection/backup rules live in `postgres-alerts.yaml`).

⚠️ **`grafana-alert-rules.yaml` is NOT in `alert-rules/kustomization.yaml`** — only `complete-alerts`, `grafana-alertrules-configmap`, `postgres-alerts`, `cost-calc-alerts` are applied. It appears to be a superseded copy of `grafana-alertrules-configmap.yaml`. Left in place deliberately: **never delete, rename, regenerate, or reformat Grafana alert config** — this configuration was lost once before and had to be rebuilt from scratch. Never add a uid to `deleteRules:`.

---

## 7. Observability

### Jaeger (Distributed Tracing)

- **Deployment**: All-in-one (collector + query + UI in single pod)
- **Protocol**: OTLP (OpenTelemetry)
- **Collector endpoint**: `jaeger-collector.observability.svc.cluster.local:4317`
- **Storage**: In-memory only (**5000** traces max -- `MEMORY_MAX_TRACES: "5000"` in `base/observability/jaeger/deployment.yaml`)
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
| ppc-service | 50053 | 8082 | **8082 (same port, served by the HTTP gateway)** |
| frontend | -- | 3000 | -- |

**PPC is the exception to the separate-metrics-port pattern**: `/metrics` is registered on the gateway mux (`services/ppc/internal/delivery/httpdelivery/gateway.go`), so `service.yaml` declares only `grpc` + `http` and `servicemonitor.yaml` scrapes `port: http`. Adding a second ServicePort on 8082 makes the Service **unappliable** — Kubernetes enforces uniqueness on `(protocol, port)`, not on port name, and neither `kustomize build` nor `kubeconform` catches it. Only `kubectl apply --dry-run=server` does.

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
| `infra-database` (in `argocd/apps/shared/infra-apps.yaml`) | `base/database` | Auto |
| `infra-observability` (in `argocd/apps/shared/infra-apps.yaml`) | `base/observability/jaeger` | Auto |
| `finance-service-staging` | `services/finance-service/overlays/staging` | Auto (prune + selfHeal) |
| `iam-service-staging` | `services/iam-service/overlays/staging` | Auto (prune + selfHeal) |
| `ppc-service-staging` | `services/ppc-service/overlays/staging` | Auto (prune + selfHeal) |
| `frontend-staging` | `services/frontend/overlays/staging` | Auto (prune + selfHeal) |
| `finance-service-production` | `services/finance-service/overlays/production` | Manual |
| `iam-service-production` | `services/iam-service/overlays/production` | Manual |
| `ppc-service-production` | `services/ppc-service/overlays/production` | Manual |
| `frontend-production` | `services/frontend/overlays/production` | Manual |
| `infra-backup-staging` | Staging backup overlay | Auto |
| `infra-minio-staging` | Staging MinIO overlay | Auto |
| `infra-backup-production` | Production backup overlay | Manual |
| `infra-minio-production` | Production MinIO overlay | Manual |

⚠️ **`argocd/apps/shared/infra-apps.yaml` declares exactly two Applications: `infra-database` and `infra-observability`.** An earlier version of this doc claimed it also covered monitoring and image-updater — it does **not**.

- **`base/monitoring/` is under NO ArgoCD Application.** It is applied **imperatively** by `scripts/install-monitoring.sh`. Nothing reconciles it, nothing restores it after a manual change, and a Grafana-side edit silently diverges from git. Treat all monitoring changes as additive and surgical.
- The ArgoCD Image Updater is likewise installed by script (`scripts/install-image-updater.sh` / `install-argocd.sh`), not by an Application.
- Bringing monitoring under GitOps is tracked as a **separate effort**. It must deduplicate the double-prefixed ConfigMaps that `install-monitoring.sh` generates *before* `prune` is ever enabled, or ArgoCD will delete ConfigMaps it does not own.

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
| `goapps-internal-token` | `goapps-staging`, `goapps-production` | INTERNAL_SERVICE_TOKEN |
| `ppc-internal-token` | `goapps-staging`, `goapps-production` | PPC_INTERNAL_TOKEN |
| `oracle-credentials` | `goapps-staging`, `goapps-production` | ORACLE_HOST, ORACLE_PORT, ORACLE_SERVICE, ORACLE_USER, ORACLE_PASSWORD |
| `git-creds` | `argocd` | Used by ArgoCD Image Updater for git write-back |

`ppc-internal-token`'s single key `PPC_INTERNAL_TOKEN` is consumed twice by both `ppc-service` `deployment.yaml` and `seed-job.yaml` — as `PPC_INTERNAL_TOKEN` and as `PPC_JWT_SERVICE_SECRET`. Its **value must equal** the `INTERNAL_SERVICE_TOKEN` in `goapps-internal-token` in the same namespace, because finance/IAM validate the incoming token against their own. Different value per environment. See `docs/runbooks/ppc-service-deployment.md`.

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

### Step 4: Create ArgoCD Application -- AND APPLY IT BY HAND (see Step 8)

Add `argocd/apps/staging/<service>.yaml` and `argocd/apps/production/<service>.yaml`.

Staging gets `syncPolicy.automated` with prune + selfHeal. Production gets no automated sync (manual).

Include ArgoCD Image Updater annotations for automatic image tag updates.

Committing the file is **not** enough to create the Application -- see Step 8.

### Step 5: Add Database Schema (If Needed)

Edit `base/database/postgres/configmap.yaml` to add the new schema.

### Step 6: Add to Sync Workflow

Update `.github/workflows/sync-argocd.yml` to include the new service in the sync steps.

### Step 7: Add a build workflow in `goapps-backend` -- DO NOT SKIP

A new backend service also needs its own `goapps-backend/.github/workflows/<service>.yml` (model it on `iam-service.yml`), or **no image is ever built**. Everything downstream then fails silently:

- No image in GHCR ->
- ArgoCD Image Updater's `allow-tags: regexp:^[a-f0-9]{7,40}$` never matches ->
- the overlay's `newTag` is never rewritten and still points at a nonexistent tag ->
- `ImagePullBackOff`.

Nothing in `goapps-infra` detects this: the manifests are valid, `kustomize build` passes, ArgoCD reports the Application Synced. This omission is exactly what happened to `ppc-service` (gap D-1) — manifests, overlays and ArgoCD Applications all existed for weeks with no workflow behind them.

The workflow's `paths:` filter must also list every shared directory the service imports (e.g. `services/shared/**`, `pkg/**`), or a change there will not rebuild the service.

### Step 8: Apply the ArgoCD Application manually -- ONE-TIME, DO NOT SKIP

**Nothing in this repo applies `argocd/apps/**` for you.** There is no app-of-apps root Application, and `sync-argocd.yml` only syncs Applications that *already exist* in the cluster. A new service's Application CR sits in git -- valid, reviewed, merged -- and is never created:

```
$ argocd app get ppc-service-staging
applications.argoproj.io "ppc-service-staging" not found
```

```bash
kubectl apply -f argocd/apps/staging/<service>.yaml
kubectl apply -f argocd/apps/production/<service>.yaml
```

A `metadata.finalizers` warning on apply is expected and harmless.

This bit `ppc-service` on 2026-07-29 in **both** environments. It is the same class of failure as Step 7: a correct artifact in git that nothing ever applies to the cluster.

### Step 9: Migrate IAM too -- the menu and permissions live in a DIFFERENT database

A service's own `<service>-setup.sh migrate` targets its own database and its own version table (e.g. `ppc_db` / `schema_migrations_ppc`). But the sidebar **menu entries, permissions and roles** are seeded by **IAM** migrations against the `goapps` database and `schema_migrations_iam` -- a different database *and* a different version table.

Skip this and the new pages load fine by direct URL while the sidebar stays permanently empty. That is exactly what happened to `ppc-service` on 2026-07-29 in both environments (IAM migrations `000079`-`000081`).

```bash
./scripts/iam-setup.sh goapps-staging migrate

kubectl exec -it postgres-0 -n database -- psql -U stgapps -d goapps \
  -c "SELECT version, dirty FROM schema_migrations_iam;"   # verify by VERSION, not by script output
```

Verify by version number: `iam-setup.sh`'s `kubectl wait` derives its `component=` label from the job name, matches no pod, and burns its timeout masked by `|| true` -- the migration still runs, but the script's output tells you nothing.

If a seed migration widens a CHECK constraint via `DROP CONSTRAINT` + `ADD CONSTRAINT` (e.g. `chk_permission_action` to admit a new action verb), compare production's live definition against staging's **before** running it there -- a drifted production constraint would be replaced wholesale:

```bash
kubectl exec -it postgres-0 -n database -- psql -U <prod-user> -d <prod-db> -c \
  "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'chk_permission_action';"
```

Users with an existing session must log out and back in -- the sidebar comes from `useMenuTree()` and permissions resolve at session start.

### Step 10: Verify against the ORG repo, not your fork

Every ArgoCD Application tracks `repoURL: https://github.com/mutugading/goapps-infra.git`. If your local `origin` is a personal fork, **verifying `origin/main` proves nothing about what ArgoCD sees.** A merged-to-fork-only fix leaves the cluster reading the old, possibly broken manifest. Query the org directly:

```bash
# quote the URL -- an unquoted `?` is glob-expanded by zsh and gh fails with
# "no matches found", which reads as a false ABSENT
gh api "repos/mutugading/goapps-infra/contents/services/<service>/base/service.yaml?ref=main" \
  --jq '.content' | base64 -d
```

For files that ArgoCD Image Updater writes back to (`*/kustomization.yaml` `newTag`), do **not** trust `git diff a..b` -- the direction is easy to misread as an image rollback. Compare per side instead:

```bash
git show origin/main:services/<service>/overlays/staging/kustomization.yaml | grep newTag
git show HEAD:services/<service>/overlays/staging/kustomization.yaml | grep newTag
git log --oneline --date=short --format='%h %ad %s' -3 origin/main -- <path>   # newest wins
```

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
| Pod Disruption Budgets | None defined -- needed for StatefulSets (PostgreSQL, RabbitMQ, MinIO) to survive node drains safely. |
| Resource Quotas | No per-namespace ResourceQuota resources -- risk of one namespace exhausting cluster resources. |
| PostgreSQL ServiceMonitor | Exporter is deployed but no ServiceMonitor resource wires it into Prometheus scraping. |
| App service accounts | Workloads run under the default K8s service account -- no dedicated RBAC service accounts per app. |
| Documentation path inconsistencies | Backup paths documented inconsistently, e.g. `/staging-goapps-backup` vs `/mnt/staging-goapps-backup`. |
| RabbitMQ clustering | Single pod, no clustering -- SPOF for the message queue. |
| Jaeger storage | In-memory only (**5000** trace cap, `MEMORY_MAX_TRACES`) -- consider persistent storage for production. |
