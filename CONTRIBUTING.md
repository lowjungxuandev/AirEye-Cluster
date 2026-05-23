# Contributing to AirEye-Cluster

AirEye-Cluster is a GitOps Kubernetes deployment platform. Contributions must
keep manifests reproducible, avoid committing secrets, and maintain the
consistency that ArgoCD depends on.

## Getting Started

1. Read the [README](README.md) for the platform overview and bootstrap order.
2. Review [docs/architecture.md](docs/architecture.md) for the component
   topology and sync wave rationale.
3. Review [docs/deployment-sequence.md](docs/deployment-sequence.md) for the
   full deployment order.

## Rules for Manifests

- **Reproducibility.** Every manifest must render cleanly with
  `kustomize build`. Use `bash scripts/validate.sh` before committing.
- **No live secrets.** Real secret values never enter this repository. Reference
  Vault paths and VaultStaticSecret templates instead. Placeholder values in
  ConfigMaps must be clearly documented as defaults to override.
- **Sync wave assignments.** New workloads must carry an
  `argocd.argoproj.io/sync-wave` annotation. Follow the existing convention:
  wave `-2` for Vault, `-1` for VSO, `0` for infrastructure and secrets, `5`
  for database init jobs, `10` for application deployments.
- **Labels.** Every resource must carry
  `app.kubernetes.io/part-of: aireye-cluster` and
  `app.kubernetes.io/managed-by: argocd`. The root Kustomization injects these
  automatically for most resources; verify with `kustomize build` if in doubt.
- **Tolerations.** The root Kustomization patches control-plane tolerations onto
  every Deployment, StatefulSet, Job, DaemonSet, and CronJob. If your workload
  needs a different toleration, test that it does not conflict.

## Adding or Changing a Component

When you add a new platform component or change an existing one, also update:

- The stack table and folder structure in [README.md](README.md)
- Relevant docs in `docs/` (architecture, deployment sequence, or
  cloudflare-proxy if TLS endpoints change)
- The hosts table if a new public ingress is added
- The required Vault keys list if new secrets are introduced

## Before Opening a Pull Request

1. Run `bash scripts/validate.sh` and ensure it passes.
2. If you have cluster access, run `bash scripts/check-cluster-sync.sh`.
3. Review the diff for any committed secrets, tokens, or API keys.
4. Confirm the PR template checklist is complete.

## Commit Style

This project follows [Conventional Commits][conv-commits]. Recent examples from
the log:

```
chore: pin MinIO release and add Langfuse GitOps deployment
refactor: rename GRIM stack to AirEye (aireye-cluster)
chore: harden GitOps sync checks and hook cleanup
```

Prefix with the affected component when relevant.

[conv-commits]: https://www.conventionalcommits.org/
