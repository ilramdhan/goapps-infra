#!/usr/bin/env bash
# PPC Setup Script — creates ppc_db, then runs migration + seed for a given namespace.
# Automatically uses the same image tag as the running ppc-service deployment.
#
# Usage:
#   ./scripts/ppc-setup.sh <namespace> [action]
#
# Examples:
#   ./scripts/ppc-setup.sh goapps-staging            # createdb + migrate + seed
#   ./scripts/ppc-setup.sh goapps-production          # createdb + migrate + seed
#   ./scripts/ppc-setup.sh goapps-staging createdb    # create ppc_db only
#   ./scripts/ppc-setup.sh goapps-staging migrate     # migrate only
#   ./scripts/ppc-setup.sh goapps-production seed     # seed only
#
# Prerequisites:
#   - postgres-secret must exist in the target namespace (used by createdb)
#   - ppc-service deployment must be running for the migrate/seed actions
#     (createdb deliberately does NOT require it — ppc_db must exist first)

set -euo pipefail

NAMESPACE="${1:?Usage: $0 <namespace> [createdb|migrate|seed|all]}"
ACTION="${2:-all}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$SCRIPT_DIR/../services/ppc-service/base"

# Resolved lazily by require_image_tag(); createdb runs before any ppc-service
# deployment exists, and createdb-job.yaml has no IMAGE_TAG placeholder.
# Must be initialised for run_job's sed expansion under `set -u`.
IMAGE_TAG=""

echo "==> Namespace: $NAMESPACE"
echo ""

require_image_tag() {
  IMAGE_TAG=$(kubectl get deployment ppc-service -n "$NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oP ':\K.*$' || true)

  if [ -z "$IMAGE_TAG" ]; then
    echo "ERROR: no ppc-service deployment in '$NAMESPACE' — deploy via ArgoCD first."
    exit 1
  fi

  echo "==> Image tag: $IMAGE_TAG"
  echo ""
}

run_job() {
  local job_name="$1"
  local job_file="$2"
  local component="$3"

  echo "==> Deleting old $job_name job (if exists)..."
  kubectl delete job "$job_name" -n "$NAMESPACE" --ignore-not-found

  echo "==> Applying $job_name job..."
  sed "s|IMAGE_TAG|$IMAGE_TAG|" "$job_file" | kubectl apply -n "$NAMESPACE" -f -

  echo "==> Waiting for $job_name to start..."
  kubectl wait --for=condition=Ready pod -l "component=$component" \
    -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

  echo "==> Logs for $job_name:"
  echo "---"
  kubectl wait --for=condition=complete job/"$job_name" -n "$NAMESPACE" --timeout=120s &
  local wait_pid=$!
  sleep 2
  kubectl logs -f "job/$job_name" -n "$NAMESPACE" 2>/dev/null || true
  wait $wait_pid 2>/dev/null

  # Check job status
  local succeeded
  succeeded=$(kubectl get job "$job_name" -n "$NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null)
  if [ "$succeeded" = "1" ]; then
    echo "==> $job_name: SUCCESS"
  else
    echo "==> $job_name: FAILED"
    echo "    Check: kubectl describe job $job_name -n $NAMESPACE"
    exit 1
  fi
  echo ""
}

case "$ACTION" in
  createdb)
    run_job "ppc-createdb" "$BASE_DIR/createdb-job.yaml" "createdb"
    ;;
  migrate)
    require_image_tag
    run_job "ppc-migrate" "$BASE_DIR/migrate-job.yaml" "migration"
    ;;
  seed)
    require_image_tag
    run_job "ppc-seed" "$BASE_DIR/seed-job.yaml" "seeder"
    ;;
  all)
    run_job "ppc-createdb" "$BASE_DIR/createdb-job.yaml" "createdb"
    require_image_tag
    run_job "ppc-migrate" "$BASE_DIR/migrate-job.yaml" "migration"
    run_job "ppc-seed" "$BASE_DIR/seed-job.yaml" "seeder"
    ;;
  *)
    echo "Unknown action: $ACTION"
    echo "Usage: $0 <namespace> [createdb|migrate|seed|all]"
    exit 1
    ;;
esac

echo "==> Done!"
