# Runbook — Port-forwarding the cluster databases to your laptop

For inspecting `goapps` and `ppc_db` from `psql`, GoLand/DataGrip, or any local client.

---

## 1. Topology you are connecting to

Two facts shape every command below:

1. **Staging and production are separate VPS/clusters.** They are reached by different SSH hosts and never share a tunnel.
2. **Each cluster runs ONE shared postgres** — `postgres-0`, StatefulSet `postgres`, Service `postgres`, namespace `database`. There is no per-service postgres. `goapps` (IAM + finance) and `ppc_db` are two **databases inside the same instance**.

Consequence: **one tunnel per environment reaches both databases.** Only `-d` changes.

`kubectl` lives on the remote host, not on your laptop, so this needs two layers: an SSH tunnel plus a `kubectl port-forward` on the far side.

---

## 2. Open the tunnels

Staging → `localhost:15432`:

```bash
ssh -L 15432:localhost:15432 deploy@staging-goapps.mutugading.com \
  "kubectl port-forward svc/postgres -n database 15432:5432"
```

Production → `localhost:15433`:

```bash
ssh -L 15433:localhost:15433 deploy@goapps.mutugading.com \
  "kubectl port-forward svc/postgres -n database 15433:5432"
```

Distinct local ports (15432 / 15433) let both tunnels live at once. Leave the terminal open; `Ctrl-C` closes the tunnel.

**The local and remote port numbers are deliberately identical** (`15432:localhost:15432`). `-L` forwards to `localhost` *on the remote host*, which is where `kubectl port-forward` listens. Mismatched numbers connect the tunnel to a port nothing is bound to, and the failure looks like a dead database rather than a bad tunnel.

Neither port is 5432, so a local postgres on the default port is never shadowed.

### If `svc/postgres` misbehaves

Target the pod directly:

```bash
ssh -L 15432:localhost:15432 deploy@staging-goapps.mutugading.com \
  "kubectl port-forward pod/postgres-0 -n database 15432:5432"
```

**Do not tunnel through PgBouncer** for manual inspection. It uses transaction pooling, which breaks session-level commands (`\d`, `\dt`, temp tables, `SET`) in many clients. Connect straight to postgres.

---

## 3. Connect

| Target | Host | Port | Database | User |
|---|---|---|---|---|
| goapps staging | localhost | 15432 | `goapps` | `stgapps` |
| ppc staging | localhost | 15432 | `ppc_db` | `stgapps` |
| goapps production | localhost | 15433 | `goapps` | see §4 |
| ppc production | localhost | 15433 | `ppc_db` | see §4 |

```bash
psql -h localhost -p 15432 -U stgapps -d goapps
psql -h localhost -p 15432 -U stgapps -d ppc_db
```

GoLand / DataGrip: Host `localhost`, Port `15432`, Database `goapps` or `ppc_db`, **SSL mode `disable`** — the in-cluster postgres runs `sslmode=disable`, and a client defaulting to `require` fails with a TLS error that reads like a network problem.

---

## 4. Credentials

The production postgres user is **not recorded in this repo** (CLAUDE.md says `(check secret)`). Read the KEY NAMES first:

```bash
ssh deploy@goapps.mutugading.com \
  "kubectl get secret postgres-secret -n database -o jsonpath='{.data}' | jq 'keys'"
```

Then decode the value **in your own terminal**. Never paste a secret value into a chat, a ticket, or a commit. Staging's `POSTGRES_USER` is `stgapps`.

Both databases share one `postgres-secret` per cluster — `ppc_db` has no separate credential (see `services/ppc-service/base/deployment.yaml`, which reads `POSTGRES_USER` / `POSTGRES_PASSWORD` from that same secret).

---

## 5. Verifying migration state

The two migration universes have **separate version tables in separate databases** — a frequent source of confusion:

```bash
# PPC schema  (ppc-setup.sh migrate)
psql -h localhost -p 15432 -U stgapps -d ppc_db \
  -c "SELECT version, dirty FROM schema_migrations_ppc;"

# IAM schema, incl. the PPC menu + permissions  (iam-setup.sh migrate)
psql -h localhost -p 15432 -U stgapps -d goapps \
  -c "SELECT version, dirty FROM schema_migrations_iam;"
```

A missing sidebar menu for a new service is almost always the second one lagging — see CLAUDE.md §15 Step 9.

---

## 6. Cautions

- **This is read-write access to production**, not a read-only replica. For inspection only, `kubectl exec -it postgres-0 -n database -- psql ... -c "SELECT ..."` is safer than a GUI session that can fire an accidental `UPDATE`.
- A GUI client holds connections open. `max_connections = 200` is shared with PgBouncer (`MAX_DB_CONNECTIONS=80`) and the cost-worker fan-out — close idle sessions rather than leaving a project connected overnight.
- Kill a forgotten tunnel: `pkill -f "port-forward svc/postgres"` on the remote host, or just close the SSH session.
