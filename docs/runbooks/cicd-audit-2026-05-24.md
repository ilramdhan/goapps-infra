# CI/CD Audit — Post Phase C (2026-05-24)

Audit of the build/deploy pipeline after the Phase C calc engine + the
post-Phase-C stabilization work. Scope: backend service workflows (in
`goapps-backend`), infra sync workflow + ArgoCD apps (this repo).

## Backend service workflows (`goapps-backend/.github/workflows/`)

| Workflow | test | build | docker push (ghcr, main) | Trivy |
|---|:---:|:---:|:---:|:---:|
| finance-service.yml | ✅ | ✅ | ✅ | ❌ |
| iam-service.yml | ✅ | ✅ | ✅ | ❌ |
| finance-cost-orchestrator.yml | ✅ | ✅ | ✅ | ❌ |
| finance-cost-worker.yml | ✅ | ✅ | ✅ | ❌ |

- All four run `go test -race`, build a binary, and push a Git-SHA-tagged
  image to `ghcr.io/mutugading/<svc>` on `main` (docker job gated on
  `github.ref == refs/heads/main`).
- **GAP — no Trivy image/config scan** on any backend service workflow.
  The infra CI (`goapps-infra/.github/workflows/ci.yml`) runs Trivy on
  manifests, but service container images are not scanned. Low-severity
  (non-blocking) but worth adding.
  - [ ] TODO (backend repo): add a Trivy `image` scan job to each service
    workflow after the docker push, severity CRITICAL,HIGH, non-blocking
    first then promote to blocking.

## Frontend (`goapps-frontend/.github/workflows/ci.yml`)

- Separate repo; single `ci.yml`. Not re-audited here beyond confirming it
  exists. (Frontend build verified green locally during this work.)

## ArgoCD applications (this repo)

| App | staging sync | production sync |
|---|---|---|
| finance-service | auto (prune+selfHeal) | manual ✅ |
| iam-service | auto | manual ✅ |
| frontend | auto | manual ✅ |
| **finance-cost-orchestrator** | auto ✅ | manual ✅ (comment-confirmed, no `automated:` block) |
| **finance-cost-worker** | auto ✅ | manual ✅ |

- Both new cost services have staging + production ArgoCD apps with the
  correct policy split (staging automated, production manual).
- ArgoCD Image Updater annotations: confirm the two cost apps carry the
  `allow-tags: regexp:^[a-f0-9]{7,40}$` SHA filter like the other services.
  - [ ] TODO: verify image-updater annotations on the two cost apps (not
    checked in this pass).

## `sync-argocd.yml` workflow

- **FIXED in this commit**: the explicit staging sync/wait steps now include
  `finance-cost-orchestrator-staging` and `finance-cost-worker-staging`.
  Previously the workflow synced only finance/iam/frontend, so the cost
  services relied solely on their ArgoCD auto-sync policy and were skipped
  by the push-triggered workflow sync.
- Production steps intentionally still exclude the cost services from the
  automated block — production cost deploy is manual (S8e.9), matching the
  app policy. Add them to the production manual-dispatch path when S8e.9 is
  executed.
  - [ ] TODO (S8e.9): add cost services to the production sync step during
    the production rollout maintenance window.

## Summary of changes made in this pass

- `sync-argocd.yml`: cost-orchestrator + cost-worker added to staging sync + wait.
- (see sibling commits) pgbouncer pool 25→50/5→10, postgres limit 2Gi→3Gi /
  1500m→2000m, orchestrator `ORCHESTRATOR_CHUNK_SIZE=100`, prometheus-adapter
  install (External Metrics API for worker HPA).

## Open follow-ups (not done here)

1. Trivy image scan on the 4 backend service workflows.
2. Verify image-updater annotations on the 2 cost ArgoCD apps.
3. S8e.9 production rollout: add cost services to production sync, run during
   a maintenance window (PgBouncer + Postgres restart for the limit bump),
   confirm prometheus-adapter is installed in prod cluster first.
