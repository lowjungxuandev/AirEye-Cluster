# Fix: ArgoCD Applications Not Applied on Bootstrap

## Problem

`aireye-cluster` ArgoCD Application was deployed without `automated` sync policy, so ArgoCD detected drift but never acted on it. Git pushes had no effect on the cluster.

**Root cause**: `argocd/applications/` was missing from `argocd/kustomization.yaml`, so `aireye-cluster.yaml` was never applied when bootstrapping ArgoCD. The application had to be created manually (without the `automated` block).

## Fix

Added `applications` to `argocd/kustomization.yaml`:

```diff
 resources:
   - namespace.yaml
   - https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.1/manifests/install.yaml
   - ingress.yaml
+  - applications
```

## Result

On next bootstrap, `argocd/applications/aireye-cluster.yaml` is applied automatically, which includes:

```yaml
syncPolicy:
  automated:
    prune: true
    selfHeal: true
```

This means ArgoCD will auto-sync whenever live state drifts from `main`.
