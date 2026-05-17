# Deployment Sequence

End-to-end order for a fresh cluster.

## At A Glance

```text
manual:  ingress-nginx -> CF Origin Cert Secrets -> Vault values -> root kustomize -> argocd -> argocd apps
gitops:  ArgoCD reconciles root path "." on every commit
```

## Manual Bootstrap

### 1. Cluster Prereqs

```sh
kubectl apply -k ingress-nginx
```

Then follow [cloudflare-proxy.md](cloudflare-proxy.md) to create the TLS
Secrets referenced by the ingresses.

### 2. Vault Values

Ensure Vault KV-v2 path `secret/grim-k8s` contains the existing platform keys
and the LiteLLM keys listed in the root README. No real secret values belong in
git.

### 3. Root Manifests

```sh
kubectl apply -k .
```

This installs the VSO custom resources, Postgres, Redis, Keycloak, MinIO,
`grim-app`, and LiteLLM. The VSO controller is installed by the ArgoCD
Application in step 5.

### 4. ArgoCD

```sh
kubectl apply --server-side=true --force-conflicts -k argocd
kubectl apply -k argocd/applications
```

The first command installs ArgoCD itself. The second creates the self-managed
`grim-k8s` Application and the `vault-secrets-operator` Application.

## ArgoCD Waves

| Wave | Resource | File | Why |
|------|----------|------|-----|
| `-1` | `Application/vault-secrets-operator` | `argocd/applications/vault-secrets-operator.yaml` | VSO before secret sync |
| `0` | `VaultStaticSecret/server-secret` | `vault-secrets-operator/server-secret.yaml` | Shared platform Secret |
| `0` | `VaultStaticSecret/grim-app-secret` | `vault-secrets-operator/grim-app-secret.yaml` | App Secret |
| `0` | `VaultStaticSecret/litellm-secret` | `vault-secrets-operator/litellm-secret.yaml` | LiteLLM runtime Secret |
| `0` | `VaultStaticSecret/zealot-secret` | `vault-secrets-operator/zealot-secret.yaml` | Zealot runtime Secret |
| `0` | Infrastructure and Services | component dirs | Default wave |
| `5` | `Job/litellm-postgres-init` | `litellm/postgres-init-job.yaml` | Creates the LiteLLM DB in existing Postgres |
| `5` | `Job/zealot-postgres-init` | `zealot/postgres-init-job.yaml` | Creates the Zealot DB in existing Postgres |
| `10` | `Job/keycloak-bootstrap` | `keycloak/bootstrap-job.yaml` | Registers OIDC clients after Keycloak is up |
| `10` | `Deployment/grim-app` | `grim-app/deployment.yaml` | Starts after runtime Secrets are available |
| `10` | `Deployment/litellm` | `litellm/deployment.yaml` | Starts after DB init and `litellm-secret` |
| `10` | `Deployment/zealot` + PVCs | `zealot/deployment.yaml`, `zealot/pvc.yaml` | Starts after DB init and `zealot-secret`; PVCs share the wave to avoid the `WaitForFirstConsumer` deadlock |

## Verification

```sh
kubectl -n infra get vaultstaticsecret litellm-secret
kubectl -n infra get secret litellm-secret
kubectl -n infra rollout status deploy/litellm
curl -I https://litellm.lowjungxuan.dpdns.org/ui
curl -s https://litellm.lowjungxuan.dpdns.org/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

For SSO, open `https://litellm.lowjungxuan.dpdns.org/ui` and use the SSO login
button. Keycloak must allow redirect URI
`https://litellm.lowjungxuan.dpdns.org/sso/callback`.

### Zealot

```sh
kubectl -n infra get vaultstaticsecret zealot-secret
kubectl -n infra get secret zealot-secret
kubectl -n infra get job zealot-postgres-init
kubectl -n infra logs job/zealot-postgres-init
kubectl -n infra rollout status deploy/zealot
kubectl -n infra get pod -l app=zealot
kubectl -n infra logs deploy/zealot
curl -I https://zealot.lowjungxuan.dpdns.org
```

For SSO, open `https://zealot.lowjungxuan.dpdns.org` and use the Keycloak
button. Keycloak must allow redirect URI
`https://zealot.lowjungxuan.dpdns.org/users/auth/openid_connect/callback`.

## Re-runnable Jobs

`keycloak-bootstrap`, `litellm-postgres-init`, and `zealot-postgres-init` carry
`argocd.argoproj.io/sync-options: Force=true,Replace=true`, so ArgoCD
recreates them on each sync instead of failing on immutable `Job.spec.template`
changes.

LiteLLM intentionally does not use VSO rollout restarts. Its startup path runs
Prisma migrations, so repeated secret-refresh restarts can prevent the server
from reaching port `4000`.

## Tear-down Order

1. `kubectl delete -k argocd/applications`
2. `kubectl delete -k argocd`
3. `kubectl delete -k .`
4. Delete manually created runtime Secrets and namespaces if they are no
   longer needed.
