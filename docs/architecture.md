# Architecture

Single-cluster GitOps stack. Application workloads live in `infra`; ArgoCD
lives in `argocd`. Vault is the source of truth for runtime secrets, and VSO
syncs selected values into Kubernetes Secrets.

## Components

| Layer | Component | Role |
|-------|-----------|------|
| Network | ingress-nginx | Cluster ingress, hostNetwork |
| TLS | Cloudflare proxy | Edge TLS + Origin Certificate |
| Data | postgres | Keycloak and LiteLLM database |
| Cache | redis | ArgoCD state cache and LiteLLM cache |
| Identity | keycloak | OIDC IdP for ArgoCD and MinIO |
| Secrets | Vault + VSO | Sync `secret/aireye-cluster` and app secrets into Kubernetes |
| Storage | minio | S3-compatible object store + console |
| GitOps | argocd | Reconciles this repo into the cluster |
| App | aireye-app | Backend service at `api.lowjungxuan.dpdns.org` |
| AI gateway | litellm | Central OpenAI-compatible gateway at `litellm.lowjungxuan.dpdns.org` |

## Trust Topology

```text
Vault secret/aireye-cluster
  |
  | VSO
  v
+----------------+------------------+
| server-secret  | litellm-secret   |
+----------------+------------------+
       |                  |
       v                  v
Postgres/Redis/Keycloak  LiteLLM -> Postgres + Redis + AI providers
```

`server-secret` holds shared platform values. `litellm-secret` contains only
LiteLLM runtime keys and provider API keys transformed from `secret/aireye-cluster`.
`aireye-app-secret` remains app-specific.

## LiteLLM

LiteLLM is the centralized AI API gateway.

- UI: `https://litellm.lowjungxuan.dpdns.org/ui`
- API: `https://litellm.lowjungxuan.dpdns.org/v1/chat/completions`
- Config: `litellm/configmap.yaml`
- Secrets: `VaultStaticSecret/litellm-secret`
- Database: existing Postgres, database `litellm`
- Cache: existing Redis

LiteLLM Admin UI SSO is not enabled by default because the open-source/enterprise
boundary can change. The base deployment works with `LITELLM_MASTER_KEY`.
Model aliases are defined in `litellm/configmap.yaml`; provider API keys stay in
Vault and are injected through `litellm-secret`.
The SSO wiring uses LiteLLM's generic OIDC provider variables and reuses the
existing Keycloak global client credentials.

## Bootstrap Order

1. Apply `ingress-nginx`.
2. Install Cloudflare Origin Cert TLS Secrets.
3. Ensure Vault path `secret/aireye-cluster` contains the required keys.
4. Apply the root kustomization.
5. Apply `argocd`.
6. Apply `argocd/applications`.
7. ArgoCD reconciles the root path from then on.

## Sync Waves

| Wave | Resource | Why |
|------|----------|-----|
| -1 | `Application/vault-secrets-operator` | VSO CRDs and controller before secret sync |
| 0 | `VaultStaticSecret/*` | Runtime Secrets before consumers |
| 0 | Infrastructure and Services | Default wave |
| 5 | `Job/litellm-postgres-init` | Creates DB in existing Postgres |
| 10 | `Job/keycloak-bootstrap` | Needs Keycloak running before registering clients |
| 10 | `Deployment/aireye-app` | Starts after runtime Secrets are present |
| 10 | `Deployment/litellm` | Starts after DB init and `litellm-secret` |
