# Local Kubernetes Manifest Validation Guide

## Why Validate Locally?

Before pushing infrastructure changes to staging/production, validate manifests locally to catch:
- YAML syntax errors
- Missing/wrong Kustomize patches
- Invalid Kubernetes resource schemas
- Broken resource references

> **Note**: You do NOT need a full local Kubernetes cluster. The validation tools (`kustomize` + `kubeconform`) work offline — they parse and validate manifests without a running cluster.

---

## Prerequisites Installation

### 1. Install Kustomize

```bash
# Install to ~/.local/bin/ (one-time)
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" \
  | bash -s -- 5.6.0 ~/.local/bin

# Verify
kustomize version
```

### 2. Install Kubeconform

```bash
# Install to ~/.local/bin/ (one-time)
curl -sL https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz \
  | tar xz -C ~/.local/bin/ kubeconform

# Verify
kubeconform -v
```

### 3. Ensure PATH includes ~/.local/bin

```bash
# Add to ~/.bashrc or ~/.zshrc if not already present
export PATH="$HOME/.local/bin:$PATH"
```

---

## Usage

### Validate All Manifests

```bash
cd goapps-infra/
./scripts/validate-manifests.sh
```

**Expected output:**
```
Validating Kustomize manifests...

  ✅ base/database (16 resources)
  ✅ services/finance-service/overlays/staging (3 resources)
  ✅ services/finance-service/overlays/production (3 resources)
  ✅ services/iam-service/overlays/staging (3 resources)
  ✅ services/iam-service/overlays/production (3 resources)
  ✅ services/frontend/overlays/staging (3 resources)
  ✅ services/frontend/overlays/production (3 resources)

All targets passed validation.
```

### Validate Specific Target

```bash
# By keyword (matches any target containing the keyword)
./scripts/validate-manifests.sh database
./scripts/validate-manifests.sh finance
./scripts/validate-manifests.sh frontend
./scripts/validate-manifests.sh staging

# By exact path
./scripts/validate-manifests.sh services/frontend/overlays/staging
```

### Preview Rendered Manifests

To see exactly what Kubernetes will receive after Kustomize renders patches:

```bash
# Preview database manifests
kustomize build base/database

# Preview finance staging with all patches applied
kustomize build services/finance-service/overlays/staging

# Preview production frontend (see final env vars, resources, replicas)
kustomize build services/frontend/overlays/production
```

### Diff Against Current Cluster State

If you have `kubectl` configured with cluster access:

```bash
# See what would change if you applied
kustomize build services/frontend/overlays/staging | kubectl diff -f -
```

---

## Workflow: Before Pushing Infra Changes

```
1. Edit manifest files (resources, configs, patches)
2. Run: ./scripts/validate-manifests.sh
3. Review rendered output: kustomize build <target>
4. Commit and push
5. ArgoCD auto-syncs staging (manual for production)
6. Verify in Grafana/ArgoCD dashboard
```

---

## FAQ

### Do I need Docker/K3s/Minikube locally?

**No.** `kustomize` and `kubeconform` are standalone binaries. They validate manifests offline without any cluster.

### When WOULD I need a local cluster?

Only if you want to test the actual behavior of pods (startup, probes, networking). For 99% of infra changes (resources, configs, replicas, env vars), manifest validation is sufficient.

### What about CRD resources (VPA, ServiceMonitor, HPA)?

The validation script skips these as `kubeconform` doesn't ship schemas for custom resources. They're validated by ArgoCD at sync time.
