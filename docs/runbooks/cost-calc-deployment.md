# Cost Calculation Engine — Deployment Runbook

> Phase C calc engine. Two new services (orchestrator + worker) plus DB/RMQ/observability changes.
> Audience: ops/oncall deploying the calc engine to staging then production.

---

## 1. Architecture recap

```
Browser → finance BFF → finance gRPC (CostCalcService.TriggerCalcJob)
  → INSERT cal_job (QUEUED) + publish finance.cost.job_triggered
    → finance-cost-orchestrator (replicas=1)
        plans DAG → packs chunks → publishes finance.cost.chunk (wave by wave)
          → finance-cost-worker (HPA 2→N)
              consumes chunk → calls finance.CostCalcService/ProcessChunkInternal (gRPC)
                → finance computes products, writes cst_product_cost + aud_cost_history
              → publishes finance.cost.chunk.completed
          → orchestrator advances waves → finalizes cal_job
```

- **finance** (existing): hosts CostCalcService gRPC + the actual compute path.
- **finance-cost-orchestrator** (NEW, replicas=1 singleton): job planning + wave dispatch + cron auto-trigger.
- **finance-cost-worker** (NEW, HPA 2→10 staging / 2→50 prod): RMQ→gRPC bridge.

---

## 2. Prerequisites (one-time per environment)

### 2.1 Database migrations

Apply on the shared `goapps` Postgres (via a finance service pod, NOT directly to postgres-0):

```bash
kubectl exec -it deploy/finance-service -n goapps-staging -- \
  /app/migrate -path /app/migrations -database "$DATABASE_URL" up
```

Migrations introduced by Phase C (idempotent, re-runnable):
- `000228`–`000233` — cst_product_cost, cal_job + counter, cal_job_chunk, cal_job_product, aud_cost_history, FK
- IAM `000042`–`000043` — 8 permissions + 2 sidebar menus (apply via iam-service pod)
- `000234`–`000241` — textile master parameters + formulas catalog *(fixture — SKIP in production unless you want demo data)*
- `000242` — backfill CAPP for active formula inputs *(safe in prod — only touches existing products)*
- `000245`–`000246` — default CAPP/RATE values *(fixture — SKIP in prod)*

**Production note:** the `000234`–`000241`, `000245`, `000246` migrations seed TXFX_* demo textile products + default param values. For production, apply only `000228`–`000233` (schema) + `000242` (CAPP backfill logic). The fixture migrations are harmless (tagged `created_by='seed_*'`, idempotent, reversible via `migrate down`) but pollute prod with demo data — coordinate with finance team before applying.

### 2.2 Secrets (must exist in target namespace)

| Secret | Keys used | Consumed by |
|---|---|---|
| `postgres-secret` | DATABASE_USER, DATABASE_PASSWORD | orchestrator + worker |
| `rabbitmq-secret` | RABBITMQ_USER, RABBITMQ_PASSWORD | orchestrator + worker |
| `goapps-auth-secret` | JWT_ACCESS_SECRET → FINANCE_JWT_SERVICE_SECRET | finance (service-to-service bypass) |
| `goapps-internal-token` | INTERNAL_SERVICE_TOKEN → SERVICE_AUTH_TOKEN | worker (x-service-secret header) |

**CRITICAL:** `goapps-internal-token/INTERNAL_SERVICE_TOKEN` (worker) MUST equal `goapps-auth-secret/JWT_ACCESS_SECRET`-derived service secret OR — current implementation — finance's `ProcessChunkInternal` accepts the worker unconditionally (network isolation; no public HTTP path). If you later set `finance.jwt.service_secret`, the worker's `SERVICE_AUTH_TOKEN` must match it exactly.

### 2.3 RabbitMQ topology

The orchestrator auto-declares the exchanges + queues on startup, so no manual step is strictly required. The `base/database/rabbitmq/cost-queues-configmap.yaml` definitions file is belt-and-suspenders (loaded via conf.d). Verify after orchestrator boots:

```bash
kubectl exec -it rabbitmq-0 -n database -- rabbitmqctl list_queues name | grep finance.cost
# Expect: finance.cost.chunk, finance.cost.chunk.completed, finance.cost.job_triggered, finance.cost.dlq
```

### 2.4 prometheus-adapter (for worker HPA)

The worker HPA scales on the external metric `rabbitmq_queue_messages_ready{queue="finance.cost.chunk"}`. This requires prometheus-adapter exposing RabbitMQ queue metrics as a custom/external metric. Verify:

```bash
kubectl get apiservice v1beta1.external.metrics.k8s.io
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/goapps-staging/rabbitmq_queue_messages_ready" 2>&1 | head
```

If absent, the HPA stays at minReplicas (2) — workers still process, just no autoscale. Add the adapter rule before relying on scale-up under load.

### 2.5 PgBouncer + Postgres tuning

Already in `base/database/`. Apply requires PgBouncer restart to pick up the new pool config:

```bash
kubectl rollout restart deploy/pgbouncer -n database
```

Postgres `max_connections=200` + memory settings: a restart of postgres-0 is needed if `shared_buffers` changed. **Schedule during a maintenance window** — postgres restart drops all connections briefly.

---

## 3. Deploy sequence

### Staging (auto-sync via ArgoCD)

```bash
# 1. Push images (CI builds on merge to main):
#    ghcr.io/mutugading/goapps-finance-cost-orchestrator:<sha>
#    ghcr.io/mutugading/goapps-finance-cost-worker:<sha>

# 2. ArgoCD auto-syncs staging apps:
argocd app sync finance-cost-orchestrator-staging
argocd app sync finance-cost-worker-staging

# 3. Verify pods Ready
kubectl get pods -n goapps-staging | grep finance-cost
# Expect: 1 orchestrator, 2 worker (HPA min)

# 4. Verify orchestrator logs show cron + RMQ topology
kubectl logs deploy/finance-cost-orchestrator -n goapps-staging | grep -E "cron scheduler started|coordinator subscribed"

# 5. Verify metrics scraping
kubectl exec -it deploy/finance-cost-orchestrator -n goapps-staging -- wget -qO- localhost:8092/metrics | grep finance_cost_ | head
```

### Production (manual approval per ArgoCD policy)

```bash
# 1. Apply migrations (schema only — see §2.1 production note):
kubectl exec -it deploy/finance-service -n goapps-production -- \
  /app/migrate -path /app/migrations -database "$DATABASE_URL" up   # to version 000233 + 000242

# 2. Verify secrets exist (§2.2)

# 3. PgBouncer restart (§2.5) — maintenance window

# 4. Manual ArgoCD sync (production apps are syncPolicy: manual)
argocd app sync finance-cost-orchestrator-production
argocd app sync finance-cost-worker-production

# 5. Smoke test (see §4)
```

---

## 4. Smoke test (both environments)

```bash
# 1. Pick a product with an active COMPLETE/LOCKED route:
kubectl exec -it postgres-0 -n database -- psql -U <user> -d goapps -tA -c \
  "SELECT cpm_product_sys_id FROM cost_product_master cpm
   JOIN cost_route_head crh ON crh.crh_product_sys_id = cpm.cpm_product_sys_id
   WHERE crh.crh_routing_status IN ('COMPLETE','LOCKED') AND crh.crh_deleted_at IS NULL LIMIT 1;"

# 2. From the UI: Calc Jobs → New job → SINGLE_PRODUCT (or use product detail Calculate button)

# 3. Watch the pipeline:
kubectl logs -f deploy/finance-cost-orchestrator -n <ns> | grep "plan and dispatch\|wave dispatched"
kubectl logs -f deploy/finance-cost-worker -n <ns> | grep "processing chunk\|chunk done"

# 4. Verify result row written:
kubectl exec -it postgres-0 -n database -- psql -U <user> -d goapps -c \
  "SELECT cpc_product_sys_id, cpc_cost_per_unit, cpc_status FROM cst_product_cost
   WHERE cpc_status != 'SUPERSEDED' ORDER BY cpc_cost_id DESC LIMIT 5;"
```

Expected: job reaches SUCCESS / PARTIAL_FAILED, cost rows present, no alerts firing.

---

## 5. Monitoring + alerts

- **Grafana dashboard**: "Cost Calc Engine" (7 panels) — jobs/hour, chunk duration p50/p95/p99, product compute, blocked-by-reason, worker scaling, DB pool, queue depth.
- **Alerts** (Grafana-provisioned, `base/monitoring/alert-rules/cost-calc-alerts.yaml`):
  - `CalcJobStuck` — queue depth > 0 for 30min (proxy for stuck job)
  - `CalcWorkerCrashLoop` — worker restart rate > 0.1/15min
  - `CalcChunkRetryRateHigh` — FAILED chunks > 5% over 10min
  - `CalcBlockedRateHigh` — BLOCKED products > 20% over 15min (likely systemic data gap)
  - `CalcDBPoolNearLimit` — pool > 85%

---

## 6. Cron auto-trigger

The orchestrator runs `0 0 2 5 * *` Asia/Jakarta (tanggal 5 each month, 02:00 WIB) → triggers an ALL-scope ACTUAL calc for the **previous** month. Verify next-fire on startup:

```bash
kubectl logs deploy/finance-cost-orchestrator -n <ns> | grep "cron scheduler started"
# {"next_fire":"2026-06-05T02:00:00+07:00","expr":"0 0 2 5 * *","tz":"Asia/Jakarta"}
```

To disable temporarily: set `orchestrator.cron_schedule=""` in the config overlay + redeploy (empty falls back to default — to truly disable, the code would need a flag; for now scale orchestrator to 0 to halt cron + dispatch).

---

## 7. Rollback

Calc engine is additive — rolling back the two new services does NOT corrupt existing data (cost results stay in cst_product_cost).

```bash
# 1. Scale down new services (stops processing; queued chunks wait in RMQ)
kubectl scale deploy/finance-cost-orchestrator deploy/finance-cost-worker --replicas=0 -n <ns>

# 2. Revert finance to prior image if ProcessChunkInternal is problematic
argocd app rollback finance-service <prior-revision>

# 3. Schema rollback (only if absolutely necessary — cost data lost):
kubectl exec -it deploy/finance-service -n <ns> -- /app/migrate ... down 6   # reverts 000233→000228
```

In-flight chunks in `finance.cost.chunk` persist (durable queue, TTL 1h). On redeploy they resume. Beyond TTL they dead-letter to `finance.cost.dlq` for manual inspection.

---

## 8. Capacity reference

- Per-chunk wall: ~10-120ms (50 products/chunk)
- 12k products full batch: target < 5 min wall with 50 workers
- Connection budget at full HPA: finance 30 + orchestrator 8 + worker(50×6)=300 → 338 via PgBouncer → ≤80 to Postgres (transaction pool_mode mandatory)
- If `CalcDBPoolNearLimit` fires under stress: raise PgBouncer `max_db_connections` + Postgres `max_connections`, OR cap worker maxReplicas.
