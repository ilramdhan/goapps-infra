# PPC Service — Deployment Runbook

> Production Planning & Control (`services/ppc-service`). New service, never yet deployed.
> Audience: ops deploying PPC to staging, then production.
> Written 2026-07-29 against the state of the working tree after the deployment-readiness slices (PLAN-01…07).

---

## 1. What PPC is, in deployment terms

- Separate Go service, **own database `ppc_db`** on the shared Postgres StatefulSet — *not* a schema inside `goapps` (locked decision D1).
- gRPC **50053**, HTTP gateway **8082**. `/metrics` is served by the HTTP gateway on **8082 as well** (registered in `services/ppc/internal/delivery/httpdelivery/gateway.go`), unlike iam which has a separate 8091 metrics port. This is why `service.yaml` has only `grpc` + `http` ServicePorts and `servicemonitor.yaml` scrapes `port: http`.
- Reads finance cost masters over gRPC (`CostMasterLookupService`) and calls IAM for notifications, both authenticated by a shared internal token.
- Reads Oracle (`MGTDAT`) for machine + lot sync — **SELECT only**.
- HPA is pinned `minReplicas: 1 / maxReplicas: 1` in `services/ppc-service/base/hpa.yaml` for both environments.
- **Not behind PgBouncer.** PgBouncer fronts the shared `goapps` database only; PPC connects directly to `postgres.database.svc.cluster.local:5432`. Safe here because PPC is pinned to a single replica. See `CLAUDE.md` §5.

Manifests: `services/ppc-service/{base,overlays/staging,overlays/production}`.
ArgoCD apps: `argocd/apps/staging/ppc-service.yaml` (automated sync), `argocd/apps/production/ppc-service.yaml` (**manual sync**).

---

## 2. Safe today vs blocked on CI

| Steps | Status |
|---|---|
| 1 — inspect secrets | Safe now, read-only |
| 2 — `ppc-internal-token` | **Already DONE** — the user created it in both `goapps-staging` and `goapps-production` |
| 3 — `createdb` | Safe now, idempotent, does **not** need a running deployment |
| 4 onward | **Blocked** until `goapps-backend/.github/workflows/ppc-service.yml` (PLAN-01) and the manifest fixes (PLAN-02) are merged **and** an image exists in GHCR |

Why step 4 is blocked: with no workflow there is no image; ArgoCD Image Updater's `regexp:^[a-f0-9]{7,40}$` never matches, the overlay's `newTag: latest` points at a tag that does not exist, and the pod goes `ImagePullBackOff`.

---

## 3. Staging

### Step 1 — inspect secrets (names only, never values)

```bash
kubectl get secrets -n goapps-staging

# postgres-secret lives in the `database` namespace; ppc_db reuses it.
kubectl get secret postgres-secret -n database -o jsonpath='{.data}' | jq 'keys'
# expected exactly: ["POSTGRES_DB","POSTGRES_PASSWORD","POSTGRES_USER"]

kubectl get secret ppc-internal-token -n goapps-staging -o jsonpath='{.data}' | jq 'keys' \
  || echo "ppc-internal-token not present"
# expected: ["PPC_INTERNAL_TOKEN"]

kubectl get secret oracle-credentials -n goapps-staging -o jsonpath='{.data}' | jq 'keys'
# expected to contain: ORACLE_HOST ORACLE_PORT ORACLE_SERVICE ORACLE_USER ORACLE_PASSWORD
```

`jq 'keys'` prints **key names only**. Never `base64 -d` a value into a terminal that is being shared, a doc, a chat, or a commit.

**`ppc_db` needs no new Postgres secret** — `createdb-job.yaml`, `migrate-job.yaml`, `seed-job.yaml` and `deployment.yaml` all read `POSTGRES_USER` / `POSTGRES_PASSWORD` from the existing `postgres-secret`.

### Step 2 — `ppc-internal-token` — **verify the KEY NAME, do not assume**

The secret exists in **both** `goapps-staging` and `goapps-production`. Existence is not enough — **the key name must be exactly `PPC_INTERNAL_TOKEN`.**

⚠️ **This actually went wrong on staging (2026-07-29).** The secret had been created with key `token`. Manifests reference `key: PPC_INTERNAL_TOKEN`, so the pod would have failed with `CreateContainerConfigError` — it never starts, and **nothing appears in application logs**. `createdb` succeeding proves nothing here: that Job runs `postgres:18-alpine` and reads only `postgres-secret`.

**Production almost certainly has the same defect** — it was created in the same sitting. Check it before Step 4 of §4.

```bash
kubectl get secret ppc-internal-token -n <namespace> -o jsonpath='{.data}' | jq 'keys'
# REQUIRED: the list must contain "PPC_INTERNAL_TOKEN"
```

If it is missing, add it (do not delete the secret; `kubectl apply` merges keys, so the old `token` key survives harmlessly and manifests only read `PPC_INTERNAL_TOKEN`):

```bash
kubectl create secret generic ppc-internal-token -n <namespace> \
  --from-literal=PPC_INTERNAL_TOKEN='<same value as INTERNAL_SERVICE_TOKEN in goapps-internal-token>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Contract, so it is not lost:

- Key name: `PPC_INTERNAL_TOKEN`.
- Consumed twice by `deployment.yaml` and twice by `seed-job.yaml` — as `PPC_INTERNAL_TOKEN` and as `PPC_JWT_SERVICE_SECRET`, both from the same key.
- PPC sends it as the `x-internal-token` gRPC metadata header (`services/ppc/internal/infrastructure/financeclient/client.go`). Finance's `auth_interceptor.go` accepts **either** `x-service-secret` **or** `x-internal-token`, so the earlier OWED-2 header mismatch is resolved on the finance side.
- **Its value must equal what finance validates**, i.e. the `INTERNAL_SERVICE_TOKEN` in `goapps-internal-token` in the same namespace. Different value per environment; identical within an environment. `base/secrets/secrets-template.yaml` documents the derive-from-existing-secret commands.
- **The frontend BFF needs the same value.** Three PPC BFF routes call finance's internal lookup RPCs via `createInternalMetadataFromRequest` (`src/lib/grpc/metadata.ts`), which reads `process.env.FINANCE_INTERNAL_TOKEN` and sends it as `x-service-secret`: `src/app/api/v1/ppc/products/route.ts`, `.../products/route-lookup/route.ts`, `.../parameters/route.ts`. If that env is unset the header is omitted and those three lookups fail (or degrade) while the rest of PPC works — a confusing partial failure. Note the frontend uses the `FINANCE_INTERNAL_TOKEN` name, not `PPC_INTERNAL_TOKEN`; the **value** must match.

  ✅ **Closed** — `FINANCE_INTERNAL_TOKEN` is now set in both `services/frontend/overlays/staging/patches/env-backend.yaml` and `.../production/patches/env-backend.yaml`, via `secretKeyRef` on the existing `goapps-internal-token` / `INTERNAL_SERVICE_TOKEN`. See §9 below.

Never write the value into any doc, chat, or commit.

### Step 3 — create the database (safe before any deployment exists)

```bash
cd goapps-infra && git pull
./scripts/ppc-setup.sh goapps-staging createdb
```

`createdb` is idempotent (`SELECT 1 FROM pg_database WHERE datname='ppc_db'` → skip) and deliberately does **not** require a running `ppc-service` deployment — the image tag is resolved lazily, only for `migrate`/`seed`.

---

> **GATE** — everything below needs PLAN-01 + PLAN-02 merged and an image visible in GHCR (`ghcr.io/mutugading/ppc-service`).

---

### Step 4 — verify the manifests actually apply

```bash
kubectl apply -k services/ppc-service/overlays/staging --dry-run=server
```

Use `kubectl apply -k`, **not** `kustomize build … | kubectl apply -f -`. `kubectl` has kustomize built in; the standalone `kustomize` binary is not installed on the staging/production hosts and the piped form fails with `Command 'kustomize' not found` followed by `error: no objects passed to apply`.

**This is the only real check for D-2** (the duplicate `metrics` ServicePort on 8082). Kubernetes enforces ServicePort uniqueness on `(protocol, port)`, not on name, so a second entry on 8082 makes the Service unappliable. `kustomize build` exits 0 on it and `kubeconform` is schema-only — neither catches it.

Expected output — five objects accepted:

```
service/ppc-service created (server dry run)
deployment.apps/ppc-service created (server dry run)
horizontalpodautoscaler.autoscaling/ppc-service-hpa created (server dry run)
servicemonitor.monitoring.coreos.com/ppc-service created (server dry run)
ingress.networking.k8s.io/ppc-service created (server dry run)
```

A `commonLabels is deprecated` warning is pre-existing and appears for every service — ignore it.

✅ **Executed on staging 2026-07-29 — all five objects accepted. D-2 is closed.** A duplicate `(protocol, port)` would have been rejected here with `spec.ports[1]: Duplicate value`.

### Step 5a — register the ArgoCD Application — **REQUIRED ONE-TIME MANUAL STEP**

⚠️ **Nothing in this repo applies `argocd/apps/**` for you.** There is no app-of-apps root Application, and `sync-argocd.yml` only syncs Applications that *already exist* in the cluster. A new service's Application CR sits in git, valid and reviewed, and is never created — `argocd app get` then fails with `applications.argoproj.io "<name>" not found`. This bit PPC on 2026-07-29 in both environments.

```bash
kubectl apply -f argocd/apps/staging/ppc-service.yaml
kubectl apply -f argocd/apps/production/ppc-service.yaml
```

A `metadata.finalizers` warning on apply is expected and harmless.

### Step 5b — let ArgoCD deploy

Staging auto-syncs. Production does not — see §4.

**The `argocd` CLI needs `argocd login`, not just a port-forward.** A bare `kubectl port-forward svc/argocd-server -n argocd 8080:443` leaves the CLI with no server address and it exits `Argo CD server address unspecified`. Use the kubectl-native equivalents instead — they need no login and work identically on the production host, which has no `argocd` binary at all:

```bash
kubectl get application ppc-service-staging -n argocd \
  -o custom-columns='SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.status.sync.revision'

# force a refresh (equivalent to `argocd app get --hard-refresh`)
kubectl patch application ppc-service-staging -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

If a Deployment was applied out-of-band (e.g. `kubectl apply -k` during setup), the Application reports `OutOfSync` / `Missing` even though a pod is Running — ArgoCD does not yet own those resources. Confirm the provenance before syncing:

```bash
kubectl get deploy ppc-service -n goapps-production -o jsonpath='{.metadata.labels}' | jq
# no `argocd.argoproj.io/instance` label ⇒ applied by hand; the next sync adopts it
```

### Step 6 — migrate

```bash
./scripts/ppc-setup.sh goapps-staging migrate
```

Migrations use a **dedicated version table `schema_migrations_ppc`** (`x-migrations-table` in the job's `DATABASE_URL`), not the shared `schema_migrations`.

#### Step 6b — migrate IAM too — **the menu and permissions live there, not in `ppc_db`**

⚠️ **`ppc-setup.sh migrate` does NOT create the PPC menu.** PPC's menu entries, permissions and roles are seeded by **IAM** migrations `000079`–`000081`, which target the `goapps` database and `schema_migrations_iam` — a different database *and* a different version table. Skip this and the PPC pages load fine by direct URL while the sidebar stays empty. That is exactly what happened on 2026-07-29 in both environments.

```bash
./scripts/iam-setup.sh goapps-staging migrate

kubectl exec -it postgres-0 -n database -- psql -U stgapps -d goapps \
  -c "SELECT version, dirty FROM schema_migrations_iam;"    # must be >= 81, dirty = false
```

| IAM migration | What it seeds |
|---|---|
| `000079_seed_ppc_roles_menus_permissions` | 6 roles (PPC/PC/PM/MARKETING/MANAGEMENT/OPERATOR), `ppc.*` permissions, the `Production Plan` root menu tree, `menu_permissions`, and the `SUPER_ADMIN` grant |
| `000080_fix_ppc_menu_urls` | Realigns 8 singular `menu_url` values to the real plural Next.js routes (keyed by `menu_code`, idempotent) |
| `000081_seed_ppc_customer_menu_and_sync_permissions` | Customer master menu leaf + `.sync` permissions; **widens `chk_permission_action` from 35 to 36 values to admit `'sync'`** |

Because `000081` does `DROP CONSTRAINT` + `ADD CONSTRAINT` on `chk_permission_action`, compare production's live definition against staging's before running it there — a drifted production constraint would be replaced wholesale:

```bash
kubectl exec -it postgres-0 -n database -- psql -U <prod-user> -d <prod-db> -c \
  "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'chk_permission_action';"
```

Users with an existing session must log out and back in — the sidebar comes from `useMenuTree()` and permissions resolve at session start.

### Step 7 — seed (staging only)

```bash
./scripts/ppc-setup.sh goapps-staging seed
```

The seeder splits into two halves:
- **Master/reference seeders — ungated, run in every environment**: overrun thresholds, downtime reasons, waste categories, machine groups, product PPC config, lookups, shifts.
- **`seedWorkflowDemo` — gated on `APP_ENV`**, runs only when `APP_ENV` is `development` or empty (`services/ppc/seeds/main.go`). `seed-job.yaml` supplies `APP_ENV` from `fieldRef: metadata.namespace`, so in `goapps-staging`/`goapps-production` the demo demand + plan item + work order + demo lot are skipped and a log line says so.

**Known consequence — machine master is NOT primed by `seed`.** `syncMachinesForSeed` (the real finance + Oracle machine upsert, not demo data) currently sits *inside* `seedWorkflowDemo` and is therefore gated too. In practice machines still populate because `MachineSyncWorker` in `cmd/server/main.go` runs a sync on startup and then on a daily ticker. So: deploy first, let the pod come up, then check `machine_master`. A fix (splitting the sync out into its own ungated call) is proposed but **not yet approved**.

### Step 8 — verify

```bash
kubectl get pods -n goapps-staging -l app=ppc-service
kubectl logs deploy/ppc-service -n goapps-staging --tail=100
kubectl get servicemonitor ppc-service -n goapps-staging
kubectl get svc ppc-service -n goapps-staging -o yaml | grep -A6 ports
```

Then in Grafana, the **GoApps Service Dashboard** `service` variable now offers `ppc-service` (panels filter on `pod=~"$service.*"`, so no panel edits were needed).

---

## 4. Production

Same shape, three differences:

1. Namespace `goapps-production`; `ppc-internal-token` already exists there.
2. **ArgoCD sync is human-initiated. Two paths exist — know both.** `argocd/apps/production/ppc-service.yaml` deliberately has no `syncPolicy.automated` (identical to finance, iam, frontend and the finance workers), so a push to `main` never syncs production by itself. Image Updater still writes the new tag into git, but nothing applies it until a human acts:
   - **ArgoCD web UI** — the normal path. There is no `argocd` CLI on the production host, so this is the only way to sync a *single* Application.
   - **`Sync ArgoCD` workflow, run via `workflow_dispatch`** with `environment: production` or `all`. This is the only other trigger — the `sync-production` / `sync-production-only` jobs are gated by `if: github.event.inputs.environment == ...`, which is never true for a `push` event.

   ⚠️ **The workflow path syncs ALL production Applications with `--prune`, not just PPC** — `infra-apps`, `finance-service-production`, `iam-service-production`, `ppc-service-production`, `frontend-production`. `--prune` deletes any live resource that is no longer produced by the Application's rendered manifests, so an incomplete or mis-merged `main` (a deleted overlay file, a resource dropped from a `kustomization.yaml`) removes the corresponding Deployment/Service/Ingress/HPA from the cluster on sync. Note also that the GitHub `production` Environment referenced by these jobs **does not currently exist in the repository settings**, so it enforces no reviewer approval — the only gate is that a human must dispatch the run. Prefer the web UI when you intend to release one service.
3. **DO NOT run `seed`.** `createdb` + `migrate` only. The `APP_ENV` gate should prevent demo injection, but the gate is a safety net, not a licence to invoke it.

```bash
./scripts/ppc-setup.sh goapps-production createdb

# --- manual ArgoCD sync in the web UI; wait for Healthy + Synced ---

./scripts/ppc-setup.sh goapps-production migrate
# NO seed.
```

---

## 5. Rollback

```bash
kubectl rollout undo deployment/ppc-service -n goapps-production
# or, from the ArgoCD UI / CLI:
argocd app rollback ppc-service-production
```

**Migrations are not auto-reverted by a rollback.** If a migration must come back out, run `migrate down` deliberately, and afterwards check the dirty flag:

```sql
SELECT version, dirty FROM schema_migrations_ppc;
-- if dirty = true, the migration aborted mid-way; fix the schema by hand, then:
-- UPDATE schema_migrations_ppc SET dirty = false WHERE version = <n>;
```

See `docs/runbooks/migration-troubleshooting.md` for the general dirty-migration drill.

---

## 6. Backup

`ppc_db` is dumped by the same daily CronJobs as `goapps` — `base/backup/cronjobs/postgres-backup.yaml`, one shared `backup-scripts` ConfigMap key `backup.sh` used by all three CronJobs. The `ppc_db` dump runs **after** the `goapps` dump and both of its uploads, and is **non-fatal**: if it fails, the goapps backup that already succeeded is preserved, a `WARNING` is logged, and the partial file is removed. The dump runs in a subshell with `set -o pipefail` so a failed `pg_dump` is not masked by a successful `gzip`.

Artifacts: `${ENVIRONMENT}_ppc_db_${TIMESTAMP}.sql.gz`, uploaded to MinIO `postgres-backups/` and synced to Backblaze B2 by explicit filename (the script names files explicitly rather than globbing).

---

## 7. Alerting

A `postgres-deadlocks-ppc` Grafana rule (`datname="ppc_db"`) mirrors the existing `goapps` deadlock rule in `base/monitoring/alert-rules/postgres-alerts.yaml`.

⚠️ **`base/monitoring/` is under no ArgoCD Application.** It is applied imperatively by `scripts/install-monitoring.sh`. Nothing reconciles it and nothing restores it. Treat every monitoring change as **additive and surgical** — do not regenerate dashboards from a Grafana export, do not enable `prune` on a monitoring Application without first deduplicating the double-prefixed ConfigMaps that `install-monitoring.sh` creates. Bringing monitoring under GitOps is tracked as a separate effort.

---

## 8. Script reference

```bash
./scripts/ppc-setup.sh <namespace> [createdb|migrate|seed|all]
```

| Action | Job | Needs a running deployment? |
|---|---|---|
| `createdb` | `ppc-createdb` (postgres:18-alpine, `component=createdb`) | No |
| `migrate` | `ppc-migrate` (`component=migration`) | Yes — image tag is read from the deployment |
| `seed` | `ppc-seed` (`component=seeder`) | Yes |
| `all` | all three in order | Yes (createdb runs first, before the tag is required) |

Note the label values: `createdb`, **`migration`**, **`seeder`** — not `migrate`/`seed`. The script passes them explicitly.

> **Known bug in a sibling script**: `scripts/iam-setup.sh` derives its label as `${job_name#iam-}`, which yields `migrate`/`seed` and matches nothing. It is masked by `|| true` on `kubectl wait`, so it silently waits out the 60s timeout instead of failing. Not fixed here; recorded as a follow-up.

---

## 9. Frontend BFF internal token (`FINANCE_INTERNAL_TOKEN`)

### What it is for

Three PPC BFF routes do not talk to PPC at all — they proxy **finance**'s read-only
`CostMasterLookupService` so the PPC UI can pick products, routes and parameters:

| BFF route | Frontend file |
|---|---|
| `/api/v1/ppc/products` | `src/app/api/v1/ppc/products/route.ts` |
| `/api/v1/ppc/products/route-lookup` | `src/app/api/v1/ppc/products/route-lookup/route.ts` |
| `/api/v1/ppc/parameters` | `src/app/api/v1/ppc/parameters/route.ts` |

All three build metadata with `createInternalMetadataFromRequest`
(`src/lib/grpc/metadata.ts`). That helper reads `process.env.FINANCE_INTERNAL_TOKEN`
and, **only when it is non-empty**, sets the `x-service-secret` gRPC header. When the
env var is unset it does not throw and does not send an empty header — it simply
**omits** the header. That is why the failure mode is a confusing partial one: the rest
of PPC works and only these three lookups return `Unauthenticated`.

On the receiving side, `services/finance/internal/delivery/grpc/auth_interceptor.go`
lists these RPCs in `internalLookupMethods` and gates them with `serviceSecretValid`,
which accepts **either** `x-service-secret` **or** `x-internal-token` matching
`cfg.JWT.ServiceSecret`. If `ServiceSecret` is empty the check is skipped entirely
(dev default) — so a missing token degrades silently in dev and hard-fails in a
cluster where the secret is set.

### Which secret and key

Finance reads its `jwt.service_secret` from env **`JWT_SERVICE_SECRET`** (viper
`AutomaticEnv`, dots → underscores, no prefix), wired in
`services/finance-service/base/deployment.yaml` from:

| Secret | Key |
|---|---|
| `goapps-internal-token` | `INTERNAL_SERVICE_TOKEN` |

The frontend therefore uses **the same secret and key**, exposed under the name the
frontend code expects:

```yaml
- name: FINANCE_INTERNAL_TOKEN
  valueFrom:
    secretKeyRef:
      name: goapps-internal-token
      key: INTERNAL_SERVICE_TOKEN
```

Applied in both `services/frontend/overlays/staging/patches/env-backend.yaml` and
`services/frontend/overlays/production/patches/env-backend.yaml`. No new secret is
needed — `goapps-internal-token` already exists in both namespaces.

> **Not the same as `ppc-internal-token`.** `ppc-internal-token` / `PPC_INTERNAL_TOKEN`
> is what the **PPC service** sends outbound (and validates inbound). The frontend BFF
> needs whatever **finance** validates, which is `goapps-internal-token`. The two
> secrets are required to hold the *same value* within an environment (§Step 2), but
> they are distinct objects — do not rename, merge or repurpose either.

### Verify it is present (never print the value)

```bash
kubectl get secret goapps-internal-token -n goapps-staging -o jsonpath='{.data}' | jq 'keys'
# expected: ["INTERNAL_SERVICE_TOKEN"]

kubectl get secret goapps-internal-token -n goapps-production -o jsonpath='{.data}' | jq 'keys'

# confirm the env reaches the pod — name and source only, no value
kubectl get deploy frontend -n goapps-staging \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="FINANCE_INTERNAL_TOKEN")]}' | jq .
```

Never `base64 -d` the value into a terminal, a doc, or a commit.

### Value consistency requirement

Within a single environment these must all be the **same value**:

| Consumer | Env var | Secret / key |
|---|---|---|
| finance-service | `JWT_SERVICE_SECRET` | `goapps-internal-token` / `INTERNAL_SERVICE_TOKEN` |
| ppc-service | `PPC_INTERNAL_TOKEN`, `PPC_JWT_SERVICE_SECRET` | `ppc-internal-token` / `PPC_INTERNAL_TOKEN` |
| frontend (BFF) | `FINANCE_INTERNAL_TOKEN` | `goapps-internal-token` / `INTERNAL_SERVICE_TOKEN` |

Use a **different** value per environment, identical across all three consumers within
each. Rotating `goapps-internal-token` requires re-deriving `ppc-internal-token` from it
and restarting `frontend`, `finance-service`, `ppc-service`, `iam-service` and the
workers in that namespace.
