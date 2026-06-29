# Runbook — Bulk Import v2 (MinIO CORS + ILM)

> For the v2 ETL bulk import (`/finance/product-master` → Import Produk+Routing / Params Saja).
> The browser uploads the file **directly to MinIO** via a presigned PUT URL, then the
> finance-worker streams it from MinIO into staging tables and resolves it set-based.
>
> Two infra prerequisites must be in place per environment:
> 1. **CORS** — so the browser PUT is not blocked (declarative, in the MinIO overlay patch).
> 2. **ILM expiry** — so uploaded import objects + error reports under `imports/` are
>    auto-deleted after 7 days (applied once via `mc`, below).

---

## 1. CORS (declarative — already in git)

`MINIO_API_CORS_ALLOW_ORIGIN` is set on the MinIO deployment per environment:

| Env | File | Origin |
|-----|------|--------|
| Staging | `overlays/staging/minio/minio-patch.yaml` | `https://staging-goapps.mutugading.com:24169` |
| Production | `overlays/production/minio/minio-patch.yaml` | `https://goapps.mutugading.com:24169` |

> The origin MUST match the frontend page origin **exactly, including the port**. The
> app is served on the ingress NodePort `:24169`, so the browser's `Origin` header is
> `https://<host>:24169` — an allow-origin without the port (i.e. implicit 443) will NOT
> match and the presigned PUT is blocked by CORS. Update this value if that port changes.

Applied automatically when the `infra-minio-<env>` ArgoCD app syncs (staging auto; production manual).
MinIO must restart to pick up the env var — ArgoCD rolls the deployment on change.

### Verify CORS after sync

```bash
# Preflight from the frontend origin to the public MinIO API endpoint (NodePort :30091).
# Expect HTTP 200 and an Access-Control-Allow-Origin header echoing the origin.
curl -sS -i -X OPTIONS \
  -H "Origin: https://staging-goapps.mutugading.com:24169" \
  -H "Access-Control-Request-Method: PUT" \
  "https://staging-goapps.mutugading.com:30091/goapps-staging/" --insecure \
  | grep -i "access-control-allow-origin\|HTTP/"
```

If `Access-Control-Allow-Origin` is missing, confirm the MinIO pod restarted and carries the env:

```bash
kubectl get deploy minio -n minio -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'; echo
kubectl rollout restart deployment/minio -n minio   # if the env is present but not yet live
```

---

## 2. ILM expiry for `imports/` (manual — run once per environment)

Import uploads and generated error reports live under the `imports/` prefix of the app bucket.
Expire them after 7 days so the bucket does not grow unbounded. The app bucket differs per env,
so run the matching block. (Mirrors the existing `minio-ilm-setup` Job pattern for `postgres-backups`.)

### Staging (bucket `goapps-staging`)

```bash
kubectl run mc-ilm --rm -it --restart=Never -n minio --image=minio/mc:latest -- sh -c '
  mc alias set m https://minio.minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --api S3v4 --insecure
  mc ilm rule add --expire-days 7 --prefix "imports/" m/goapps-staging --insecure
  mc ilm rule ls m/goapps-staging --insecure
' --overrides='{"spec":{"containers":[{"name":"mc-ilm","image":"minio/mc:latest","envFrom":[{"secretRef":{"name":"minio-secret"}}],"stdin":true,"tty":true,"command":["sh","-c"],"args":["mc alias set m https://minio.minio:9000 \"$MINIO_ROOT_USER\" \"$MINIO_ROOT_PASSWORD\" --api S3v4 --insecure && mc ilm rule add --expire-days 7 --prefix imports/ m/goapps-staging --insecure && mc ilm rule ls m/goapps-staging --insecure"]}]}}'
```

Simpler — exec inside the running MinIO pod (mc is not in the server image, so use a one-off pod);
the most reliable form is a throwaway Job that loads the `minio-secret`:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: minio-ilm-imports-staging
  namespace: minio
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: mc
          image: minio/mc:latest
          command: ["sh", "-c"]
          args:
            - |
              mc alias set m https://minio.minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --api S3v4 --insecure
              mc ilm rule add --expire-days 7 --prefix "imports/" m/goapps-staging --insecure
              mc ilm rule ls m/goapps-staging --insecure
          envFrom:
            - secretRef:
                name: minio-secret
EOF
kubectl logs job/minio-ilm-imports-staging -n minio
```

### Production (bucket `goapps-production`)

Same Job with `name: minio-ilm-imports-production` and `m/goapps-production`. Run during a
maintenance window after the production MinIO overlay sync.

---

## 3. Worker memory

`finance-worker` memory limit is **1Gi** (base + staging; production already 1Gi). The ETL streams
the upload into staging via `COPY` so resident memory stays well under that even for 2.4M-row files.
Watch during the first large import:

```bash
kubectl top pod -n goapps-staging -l app=finance-worker
```

If RSS approaches 1Gi on a real import, capture a heap profile before raising the limit — streaming
should keep it low; sustained high usage indicates a regression (e.g. an accidental full-file read).

---

## 4. End-to-end smoke (after CORS + ILM)

1. `/finance/product-master` → **Import** → "Import Produk + Routing (Bulk)".
2. Pick an `.xlsx` (or `.zip` of CSVs) → watch the upload progress bar reach 100%.
3. Job is queued → dialog polls status → DONE/PARTIAL; on PARTIAL a "Unduh laporan error" link appears.
4. Confirm on `/finance/import-jobs` and that the bell notification arrived.
5. Repeat with "Import Params Saja" using a `.zip` of `product_parameters.csv` + `applicable_params.csv`.
