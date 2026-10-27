#!/usr/bin/env bash
# render_job <service-dir> <job-name> <base-job-file>
# Prints exactly ONE Job manifest (IMAGE_TAG not yet substituted).
# If services/<service-dir>/overlays/<env>/jobs/kustomization.yaml exists
# (env derived from $NAMESPACE: goapps-staging -> staging), the overlay is rendered
# and only the Job named <job-name> is emitted; otherwise the base file is printed.
render_job() {
  local svc="$1" job_name="$2" base_file="$3"
  local env="${NAMESPACE#goapps-}"
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/services/$svc/overlays/$env/jobs"
  if [ -f "$dir/kustomization.yaml" ]; then
    echo "==> Using env job overlay: services/$svc/overlays/$env/jobs" >&2
    local out
    # nodes ship kubectl but not standalone kustomize; kubectl kustomize takes the same flags
    if command -v kustomize >/dev/null 2>&1; then
      out="$(kustomize build --load-restrictor LoadRestrictionsNone "$dir")" || return 1
    else
      out="$(kubectl kustomize --load-restrictor LoadRestrictionsNone "$dir")" || return 1
    fi
    printf '%s\n' "$out" | awk -v want="$job_name" '
      function flush() { if (doc != "" && kind_ok && name_ok) { printf "%s", doc; found=1 } doc=""; kind_ok=0; name_ok=0 }
      /^---[[:space:]]*$/ { flush(); next }
      { doc = doc $0 "\n" }
      /^kind: Job$/ { kind_ok=1 }
      $0 == "  name: " want { name_ok=1 }
      END { flush(); if (!found) { print "render_job: job " want " not found in overlay" > "/dev/stderr"; exit 1 } }'
  else
    cat "$base_file"
  fi
}
