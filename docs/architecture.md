# Architecture

Single-cluster GitOps stack. All workloads live in the `infra` namespace
except ArgoCD (in `argocd`) and the Vault Secrets Operator (in
`vault-secrets-operator`).

## Components

| Layer        | Component                | Role                                                  |
|--------------|--------------------------|-------------------------------------------------------|
| Network      | ingress-nginx            | Cluster ingress (hostNetwork)                         |
| TLS          | cert-manager             | Let's Encrypt issuer (HTTP-01)                        |
| Data         | postgres                 | DB for keycloak + vault                               |
| Cache        | redis                    | ArgoCD session/state cache                            |
| Identity     | keycloak                 | OIDC IdP for ArgoCD, MinIO, Vault UI                  |
| Secrets      | vault                    | KV-v2 backend (`secret/grim-k8s`, `secret/grim-app-secret`) |
| Sync         | vault-secrets-operator   | Pulls Vault secrets into Kubernetes Secrets (VSO)     |
| Storage      | minio                    | S3-compatible object store + standalone console       |
| GitOps       | argocd                   | Reconciles this repo into the cluster                 |
| App          | grim-app                 | Backend service (`api.lowjungxuan.dpdns.org`)         |

## Trust topology

```
              Keycloak (OIDC IdP)
              /      |      \
           argocd  minio   vault-ui
              \      |      /
               server-secret (K8s Secret)
                     |
              VaultStaticSecret
                     |
                Vault: secret/grim-k8s
```

`grim-app` consumes `grim-app-secret` (a separate Vault path) via `envFrom`.

## Secret flow

See [secret-refresh-flow.md](secret-refresh-flow.md). One-line summary:

```
Vault KV  →  VSO (refreshAfter: 30s)  →  K8s Secret  →  rolloutRestartTargets  →  Pod restart
```

## Bootstrap order

Resources marked **manual** must be applied before ArgoCD takes over.

1. **manual** — `ingress-nginx`, `cert-manager`
2. **manual** — pre-create `server-secret` and `grim-app-secret` (placeholder values)
3. **manual** — `kubectl apply -k .` (postgres, redis, keycloak, minio, grim-app,
   ClusterIssuer, plus VSO CRs in `vault-secrets-operator/`)
4. **manual** — `kubectl kustomize --enable-helm vault | kubectl apply -f -`
   - `vault-bootstrap` initialises + unseals Vault (one-shot Job)
   - `vault-auto-unseal` CronJob keeps it unsealed
5. **manual** — configure Vault: seed KV data, write policy, enable auth
   backends and bind roles. See [Vault config (manual)](#vault-config-manual).
6. **manual** — `kubectl apply -k argocd`
7. **manual** — `kubectl apply -k argocd/applications` — self-managed Application
   and the standalone `vault-secrets-operator` Application (installs VSO).
8. **GitOps** — ArgoCD reconciles everything in step 3 from then on.

## Sync waves

ArgoCD applies resources in ascending wave order:

| Wave | Resource                                     | Why                                                |
|------|----------------------------------------------|----------------------------------------------------|
| -1   | `Application/vault-secrets-operator`         | VSO must be running before any VaultStaticSecret   |
| 0    | `VaultStaticSecret/grim-app-secret`          | K8s Secret must exist before consumer pods         |
| 10   | `Job/keycloak-bootstrap`                     | Needs Keycloak running to register clients         |
| 10   | `Deployment/grim-app`                        | Consumes `grim-app-secret` via envFrom             |

Resources without a wave default to wave 0. If a Pod starts before its
Secret exists, Kubernetes restarts the Pod automatically once the Secret
appears.

## Vault config (manual)

Per the GitOps policy of this repo, `vault kv put`, policies, and auth
backend configuration are **not** managed by kustomize. Run the following
once after the `vault-bootstrap` Job finishes (or run them again any time
they need to change). Substitute real values for every `<placeholder>`.

```sh
ROOT_TOKEN=$(kubectl get secret -n infra vault-bootstrap-secret \
  -o jsonpath='{.data.VAULT_ROOT_TOKEN}' | base64 -d)

ve() { kubectl exec -n infra vault-0 -- sh -ec "VAULT_TOKEN='$ROOT_TOKEN' $*"; }

# --- 1. Enable the KV-v2 backend (idempotent) ---
ve "vault secrets enable -path=secret kv-v2 || true"

# --- 2. Seed the shared infrastructure secret ---
ve "vault kv put secret/grim-k8s \
  POSTGRES_USER='<...>' POSTGRES_PASSWORD='<...>' POSTGRES_DB='<...>' \
  KEYCLOAK_DB_PASSWORD='<...>' \
  VAULT_DB_PASSWORD='<...>' \
  VAULT_PG_CONNECTION_URL='postgres://<user>:<pass>@postgres.infra.svc.cluster.local:5432/vault?sslmode=disable' \
  KC_DB=postgres \
  KC_DB_URL='jdbc:postgresql://postgres.infra.svc.cluster.local:5432/keycloak' \
  KC_DB_USERNAME='<...>' \
  KEYCLOAK_ADMIN='<...>' KEYCLOAK_ADMIN_PASSWORD='<...>' \
  KEYCLOAK_USER_USERNAME='<...>' KEYCLOAK_USER_PASSWORD='<...>' KEYCLOAK_USER_EMAIL='<...>' \
  OIDC_CLIENT_ID=vault OIDC_CLIENT_SECRET='<...>' \
  REDIS_PASSWORD='<...>' \
  ARGOCD_OIDC_CLIENT_ID=argocd ARGOCD_OIDC_CLIENT_SECRET='<...>' \
  MINIO_ROOT_USER='<...>' MINIO_ROOT_PASSWORD='<...>' \
  MINIO_OIDC_CLIENT_ID=minio MINIO_OIDC_CLIENT_SECRET='<...>'"

# --- 3. Seed the application-specific secret (do once; edit via Vault UI later) ---
ve "vault kv put secret/grim-app-secret \
  DEEPSEEK_API_KEY='<...>' OPENAI_API_KEY='<...>' \
  S3_ACCESS_KEY_ID='<...>' S3_SECRET_ACCESS_KEY='<...>' \
  PORT=3001 ..."

# --- 4. Write the read policy used by VSO + Vault-UI OIDC users ---
ve "cat > /tmp/policy.hcl <<'EOF'
path \"secret/metadata\"                  { capabilities = [\"list\"] }
path \"secret/metadata/grim-k8s\"          { capabilities = [\"list\", \"read\"] }
path \"secret/metadata/grim-k8s/*\"        { capabilities = [\"list\", \"read\"] }
path \"secret/metadata/grim-app-secret\"   { capabilities = [\"list\", \"read\"] }
path \"secret/data/grim-k8s\"              { capabilities = [\"read\"] }
path \"secret/data/grim-k8s/*\"            { capabilities = [\"read\"] }
path \"secret/data/grim-app-secret\"       { capabilities = [\"create\", \"read\", \"update\"] }
EOF
vault policy write grim-k8s-read /tmp/policy.hcl"

# --- 5. Enable the Kubernetes auth method for VSO ---
ve "vault auth enable kubernetes || true"
ve "vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc"
ve "vault write auth/kubernetes/role/vso-grim-k8s \
  bound_service_account_names=vault-secrets-operator \
  bound_service_account_namespaces=infra,argocd \
  policies=grim-k8s-read \
  audience=vault \
  ttl=1h"

# --- 6. Enable the OIDC auth method for the Vault UI (optional but used here) ---
ve "vault auth enable oidc || true"
ve "vault write auth/oidc/config \
  oidc_discovery_url='https://keycloak.lowjungxuan.dpdns.org/realms/master' \
  oidc_client_id='<OIDC_CLIENT_ID>' \
  oidc_client_secret='<OIDC_CLIENT_SECRET>' \
  default_role=keycloak"
ve "vault write auth/oidc/role/keycloak \
  user_claim=preferred_username \
  oidc_scopes='openid,email,profile' \
  allowed_redirect_uris='https://vault.lowjungxuan.dpdns.org/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback' \
  policies='default,grim-k8s-read' \
  ttl=1h"
```

These commands replace the deleted `vault-seed-secrets` and
`vault-keycloak-oidc` Jobs. Pull them into Terraform if you'd rather not
run them by hand.
