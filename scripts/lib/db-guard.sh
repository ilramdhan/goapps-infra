#!/usr/bin/env bash
# Shared helpers for *-setup.sh: refuse to run DDL migrations while a postgres
# backup (pg_dump) is running, and print diagnostics when a migrate Job fails.
# Incident: pg_dump held ACCESS SHARE locks, golang-migrate's TRUNCATE
# schema_migrations_<svc> queued for ACCESS EXCLUSIVE and blocked everything.
#
# Env: FORCE_MIGRATE=1 skip guard; WAIT_FOR_BACKUP=1 poll every 30s up to 30m.
# Requires: NAMESPACE (not used here), kubectl. Postgres: pod postgres-0, ns database, user postgres.

DB_NS="database"
DB_POD="postgres-0"

_db_psql() { # $1 = sql, $2 = db (default postgres)
  kubectl exec -n "$DB_NS" "$DB_POD" -c postgres -- \
    psql -X -P pager=off -U postgres -d "${2:-postgres}" -At -c "$1" 2>/dev/null
}

# Echo "name age-seconds" lines for active postgres-backup-* jobs.
_active_backup_jobs() {
  kubectl get jobs -n "$DB_NS" \
    -o jsonpath='{range .items[?(@.status.active)]}{.metadata.name}{" "}{.status.startTime}{"\n"}{end}' 2>/dev/null \
    | grep '^postgres-backup' || true
}

guard_no_backup_running() {
  if [ "${FORCE_MIGRATE:-0}" = "1" ]; then
    echo "==> FORCE_MIGRATE=1: skipping backup pre-flight guard"
    return 0
  fi
  local waited=0
  while true; do
    local jobs pgdump waiting
    jobs=$(_active_backup_jobs)
    pgdump=$(_db_psql "SELECT count(*) FROM pg_stat_activity WHERE application_name='pg_dump'" || echo "?")
    waiting=$(_db_psql "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type='Lock' AND now()-query_start > interval '60 seconds'" || echo "?")
    if [ -z "$jobs" ] && { [ "$pgdump" = "0" ] || [ "$pgdump" = "?" ]; }; then
      [ "$pgdump" = "?" ] && echo "WARN: could not query pg_stat_activity (kubectl exec failed); backup Job check only."
      if [ "$waiting" != "0" ] && [ "$waiting" != "?" ]; then
        echo "WARN: $waiting session(s) waiting on locks > 60s; migration may also block. Inspect pg_stat_activity."
      fi
      return 0
    fi
    echo "==> Backup in progress: active job(s): ${jobs:-none}; pg_dump sessions: $pgdump"
    if [ "${WAIT_FOR_BACKUP:-0}" = "1" ] && [ "$waited" -lt 1800 ]; then
      echo "    WAIT_FOR_BACKUP=1: re-checking in 30s (waited ${waited}s of 1800s)"
      sleep 30; waited=$((waited + 30)); continue
    fi
    echo "ERROR: refusing to migrate while a postgres backup is running (pg_dump holds locks that block"
    echo "       golang-migrate's TRUNCATE/ALTER). Job start time(s) above (UTC); backups run 06:00/14:00/22:00."
    echo "       Next steps: wait for it to finish (kubectl get jobs -n $DB_NS), re-run with WAIT_FOR_BACKUP=1,"
    echo "       or override with FORCE_MIGRATE=1 (migrate Job has lock_timeout=10s and will fail fast)."
    return 1
  done
}

# $1 job name, $2 service short name (finance|iam|ppc), $3 namespace
migrate_failure_diagnostics() {
  local job="$1" svc="$2" ns="$3"
  echo "==> DIAGNOSTICS for $job"
  kubectl get job "$job" -n "$ns" -o wide || true
  kubectl get pods -n "$ns" -l job-name="$job" -o wide || true
  echo "--- last logs"
  kubectl logs "job/$job" -n "$ns" --tail=30 || true
  echo "--- lock waits / pg_dump (pg_stat_activity)"
  kubectl exec -n "$DB_NS" "$DB_POD" -c postgres -- psql -X -P pager=off -U postgres -d postgres -c \
    "SELECT pid, application_name, state, wait_event_type, now()-query_start AS age, left(query,80) AS query FROM pg_stat_activity WHERE application_name='pg_dump' OR wait_event_type='Lock' ORDER BY query_start" || true
  cat <<EOT
==> NOTE: the Job may STILL BE RUNNING (backoff retries) after this script gives up.
    Delete it safely (only after confirming no backup/lock holder you need):
      kubectl delete job $job -n $ns
    golang-migrate is transactional per file; check state afterwards:
      kubectl exec -n $DB_NS $DB_POD -c postgres -- psql -U postgres -d <goapps|ppc_db> -c "SELECT * FROM schema_migrations_$svc"
    If dirty=true, fix per CLAUDE.md (set dirty=false / force the version) before re-running.
EOT
}
