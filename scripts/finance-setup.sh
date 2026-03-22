#!/usr/bin/env bash
# Finance Setup Script — runs migration + seed for a given namespace.
# Automatically uses the same image tag as the running finance-service deployment.
#
# Usage:
#   ./scripts/finance-setup.sh <namespace> [action]
#
# Examples:
#   ./scripts/finance-setup.sh goapps-staging          # migrate + seed
#   ./scripts/finance-setup.sh goapps-production        # migrate + seed
#   ./scripts/finance-setup.sh goapps-staging migrate   # migrate only
#   ./scripts/finance-setup.sh goapps-production seed   # seed only

set -euo pipefail

NAMESPACE="${1:?Usage: $0 <namespace> [migrate|seed]}"
ACTION="${2:-all}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$SCRIPT_DIR/../services/finance-service/base"

# Get image tag from running deployment
IMAGE_TAG=$(kubectl get deployment finance-service -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oP ':\K.*$')

if [ -z "$IMAGE_TAG" ]; then
  echo "ERROR: Could not find finance-service deployment in namespace '$NAMESPACE'"
  echo "       Make sure finance-service is deployed and ArgoCD has synced."
  exit 1
fi

echo "==> Namespace: $NAMESPACE"
echo "==> Image tag: $IMAGE_TAG"
echo ""

run_job() {
  local job_name="$1"
  local job_file="$2"

  echo "==> Deleting old $job_name job (if exists)..."
  kubectl delete job "$job_name" -n "$NAMESPACE" --ignore-not-found

  echo "==> Applying $job_name job..."
  sed "s|IMAGE_TAG|$IMAGE_TAG|" "$job_file" | kubectl apply -n "$NAMESPACE" -f -

  echo "==> Waiting for $job_name to start..."
  kubectl wait --for=condition=Ready pod -l "component=${job_name#finance-}" \
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
  migrate)
    run_job "finance-migrate" "$BASE_DIR/migrate-job.yaml"
    ;;
  seed)
    run_job "finance-seed" "$BASE_DIR/seed-job.yaml"
    ;;
  all)
    run_job "finance-migrate" "$BASE_DIR/migrate-job.yaml"
    run_job "finance-seed" "$BASE_DIR/seed-job.yaml"
    ;;
  *)
    echo "Unknown action: $ACTION"
    echo "Usage: $0 <namespace> [migrate|seed]"
    exit 1
    ;;
esac

echo "==> Done!"
