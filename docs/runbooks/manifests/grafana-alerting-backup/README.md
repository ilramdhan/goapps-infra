# Grafana Alerting Backup — Production

**Captured**: 2026-09-14
**Source**: PRODUCTION cluster, Grafana **12.3.1**
**Status**: RECOVERY ARTIFACT ONLY — nothing applies these files.

These are the raw, verbatim provisioning exports of production's alert
notification routing. They are **not** Kubernetes manifests, are **not** in any
kustomization, and are under no ArgoCD Application. They exist because, before
this capture, production's alert email routing lived **only** inside
`grafana.db` on a single RWO local-path PVC with no copy in git — one lost PVC
and the routing was gone with no way to rebuild it.

| File | Contents |
|---|---|
| `contact-points.yaml` | The single contact point `grafana-default-email` (one email receiver, 2 addresses: an operator mailbox and a ClickUp inbound-email address). |
| `notification-policies.yaml` | The notification policy tree. **Root policy only — no child routes.** Everything routes to `grafana-default-email`, grouped by `grafana_folder` + `alertname`. |

**Mute timings and message templates were exported EMPTY** (2 and 4 bytes
respectively — an empty `apiVersion: 1` document with no entries). Production
has none of either, so there is nothing to codify or restore for them.

## ⚠️ Addresses are REDACTED — this repository is PUBLIC

`${GRAFANA_ALERT_EMAIL_ADDRESSES}` stands in for the two real recipients. It is
a **documentation placeholder, not a variable Grafana expands** — the Grafana
container defines only `GF_SMTP_PASSWORD` (see
`base/monitoring/helm-values/prometheus-stack.yaml`), and file provisioning has
no env interpolation. Pasting this file into a live Grafana would set the
literal string as the recipient list and silently stop all alert email.

Recover the real addresses from any of:
- the running cluster (`/api/v1/provisioning/contact-points`, see Recapture below)
- a `grafana.db` snapshot (`base/monitoring/grafana-backup/` runs daily)
- the operator's off-repo copy

**Neither this contact point nor the policy tree is codified as a live
ConfigMap.** An earlier revision added one at
`base/monitoring/alert-rules/contact-points.yaml`; it was withdrawn because the
recipient addresses cannot be committed to a public repository and there is no
safe way to template them. Both are restored by hand, below.

The policy tree would be unsafe to provision regardless: a `policies:` key
overwrites the entire root tree on whichever cluster it reaches, and
production's tree is already Grafana's default shape.

## Recapture

Port-forward Grafana, then export. `$CREDS` is `admin:<password>` (the admin
password lives in the `grafana-admin-secret` Kubernetes Secret, never in git).

```bash
kubectl -n monitoring port-forward deploy/prometheus-grafana 3000:3000 &

curl -s -u "$CREDS" \
  'http://localhost:3000/api/v1/provisioning/contact-points/export?format=yaml' \
  -o contact-points.yaml

curl -s -u "$CREDS" \
  'http://localhost:3000/api/v1/provisioning/policies/export?format=yaml' \
  -o notification-policies.yaml

curl -s -u "$CREDS" \
  'http://localhost:3000/api/v1/provisioning/mute-timings/export?format=yaml' \
  -o mute-timings.yaml

curl -s -u "$CREDS" \
  'http://localhost:3000/api/v1/provisioning/templates' \
  -o message-templates.yaml
```

All four are **read-only GETs**. A near-empty output file (2–4 bytes) means
that resource type is genuinely empty, not that the export failed.

## Restore by hand

Only needed if the Grafana PVC is lost or the alerting config is wiped.
Restore is a `PUT`/`POST` against the same provisioning API, and each write
needs the `X-Disable-Provenance` header so the restored resource stays
editable in the UI afterwards (without it, Grafana marks it provisioned and
locks it read-only).

**1. Contact point** — convert the YAML above to the API's JSON body. Keep the
uid `cfc78ft369zwga` **exactly** if restoring into production, so the restore
is an in-place update rather than a duplicate receiver:

```bash
curl -s -u "$CREDS" -X POST \
  -H 'Content-Type: application/json' \
  -H 'X-Disable-Provenance: true' \
  http://localhost:3000/api/v1/provisioning/contact-points \
  -d '{
    "name": "grafana-default-email",
    "uid": "cfc78ft369zwga",
    "type": "email",
    "disableResolveMessage": false,
    "settings": {
      "addresses": "<REAL ADDRESSES — see redaction note above>",
      "singleEmail": false
    }
  }'
```

If the uid already exists, `PUT .../contact-points/cfc78ft369zwga` instead.

**2. Notification policy tree** — this endpoint replaces the **whole** tree in
one call. That is acceptable here precisely because the tree is root-only:

```bash
curl -s -u "$CREDS" -X PUT \
  -H 'Content-Type: application/json' \
  -H 'X-Disable-Provenance: true' \
  http://localhost:3000/api/v1/provisioning/policies \
  -d '{
    "receiver": "grafana-default-email",
    "group_by": ["grafana_folder", "alertname"]
  }'
```

Restore the contact point **before** the policy tree — the tree references the
contact point by name, and pointing the root at a receiver that does not exist
yet leaves alerts undeliverable in the interim.

**3. Verify** by re-running the recapture commands and diffing against the
files in this directory.

## UID caveat (applies to any restore into a non-production instance)

`grafana-default-email` is Grafana's **auto-created** default contact point and
its receiver uid is generated **per instance**. `cfc78ft369zwga` is
production's. Staging's is almost certainly different. Restoring production's
uid into an instance that already has a same-named contact point under a
different uid does **not** update it — Grafana keys receivers by uid, so you
get a second receiver, duplicated alert emails, and a contact point that
resists clean UI edits. Always `GET /api/v1/provisioning/contact-points` and
check the live uid before restoring into any instance other than production.
