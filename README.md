# grim-k8s

Single-cluster GitOps boilerplate for the `infra` namespace. ArgoCD reconciles
this repo from `main`; secrets land in Kubernetes via External Secrets Operator
pulling from Vault.

- Architecture overview → [docs/architecture.md](docs/architecture.md)
- Vault → Secret → Pod restart flow → [docs/secret-refresh-flow.md](docs/secret-refresh-flow.md)
- Diagnostic commands → [docs/troubleshooting.md](docs/troubleshooting.md)
- What changed in the last cleanup pass → [docs/refactor-summary.md](docs/refactor-summary.md)

## Stack

| Component       | Purpose                              | Source                                 |
|-----------------|--------------------------------------|----------------------------------------|
| ingress-nginx   | Cluster ingress (hostNetwork)        | Upstream baremetal manifest            |
| cert-manager    | Let's Encrypt TLS                    | Upstream + `ClusterIssuer`             |
| postgres        | DB for keycloak + vault              | `postgres:18-alpine`                   |
| redis           | Cache backend for ArgoCD             | `redis:8-alpine`                       |
| keycloak        | Identity provider (OIDC)             | `quay.io/keycloak/keycloak:26.6.1`     |
| vault           | Secrets backend (PostgreSQL storage) | Helm chart `hashicorp/vault@0.32.0`    |
| external-secrets| Sync secrets from Vault → k8s        | Operator (install separately)          |
| minio           | S3-compatible object storage         | `minio/minio` + standalone console     |
| argocd          | GitOps controller                    | Upstream manifest `v3.4.1`             |
| reloader        | Auto-restart pods on Secret change   | Stakater chart `2.2.11`                |
| grim-app        | Application backend                  | `ghcr.io/lowjungxuandev/grim/backend`  |

## Folder structure

```
.
├── README.md
├── kustomization.yaml         # ArgoCD entrypoint (path: .)
├── namespace.yaml             # the infra namespace
│
├── argocd/                    # ArgoCD itself (bootstrapped manually)
│   ├── applications/          # self-managed Application -> path: .
│   ├── patches/               # config + tolerations
│   ├── external-secrets.yaml  # argocd-redis + argocd-secret OIDC
│   └── ingress.yaml
├── cert-manager/              # operator (manual) + ClusterIssuer (GitOps)
├── external-secrets/          # ClusterSecretStore + ExternalSecrets
├── ingress-nginx/             # bootstrapped manually
├── keycloak/                  # Deployment + bootstrap-job (registers OIDC clients)
├── minio/                     # StatefulSet + console + ingress
├── postgres/                  # StatefulSet + init-configmap
├── redis/                     # StatefulSet + smoke-test job
├── reloader/                  # Stakater Reloader Helm chart
├── vault/                     # Helm chart + bootstrap/seed/oidc/auto-unseal jobs
├── grim-app/                  # the application
│
├── docs/                      # architecture, secret flow, troubleshooting
└── scripts/                   # validate.sh, troubleshoot-secrets.sh
```

## Bootstrap order

ArgoCD takes over after step 5. Steps 1–4 are one-time manual setup.

```sh
# 1. Cluster ingress + TLS issuer + ESO operator must be in place first.
kubectl apply -k ingress-nginx
kubectl apply -k cert-manager
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace

# 2a. Pre-create secrets so postgres + vault can boot.
#     ESO takes ownership (creationPolicy: Owner) once Vault is seeded.
kubectl create namespace infra --dry-run=client -o yaml | kubectl apply -f -

kubectl -n infra create secret generic server-secret \
  --from-literal=POSTGRES_USER=<your-value> \
  --from-literal=POSTGRES_PASSWORD=<your-value> \
  --from-literal=POSTGRES_DB=<your-value> \
  --from-literal=KEYCLOAK_DB_PASSWORD=<your-value> \
  --from-literal=VAULT_DB_PASSWORD=<your-value> \
  --from-literal=VAULT_PG_CONNECTION_URL='postgres://<vault-user>:<vault-pass>@postgres.infra.svc.cluster.local:5432/vault?sslmode=disable' \
  --from-literal=KC_DB=postgres \
  --from-literal=KC_DB_URL='jdbc:postgresql://postgres.infra.svc.cluster.local:5432/keycloak' \
  --from-literal=KC_DB_USERNAME=<your-value> \
  --from-literal=KEYCLOAK_ADMIN=<your-value> \
  --from-literal=KEYCLOAK_ADMIN_PASSWORD=<your-value> \
  --from-literal=KEYCLOAK_USER_USERNAME=<your-value> \
  --from-literal=KEYCLOAK_USER_PASSWORD=<your-value> \
  --from-literal=KEYCLOAK_USER_EMAIL=<your-value> \
  --from-literal=OIDC_CLIENT_ID=vault \
  --from-literal=OIDC_CLIENT_SECRET=<your-value> \
  --from-literal=REDIS_PASSWORD=<your-value> \
  --from-literal=ARGOCD_OIDC_CLIENT_ID=argocd \
  --from-literal=ARGOCD_OIDC_CLIENT_SECRET=<your-value> \
  --from-literal=MINIO_ROOT_USER=<your-value> \
  --from-literal=MINIO_ROOT_PASSWORD=<your-value> \
  --from-literal=MINIO_OIDC_CLIENT_ID=minio \
  --from-literal=MINIO_OIDC_CLIENT_SECRET=<your-value> \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n infra create secret generic grim-app-secret \
  --from-literal=DEEPSEEK_API_KEY=<your-value> \
  --from-literal=DEEPSEEK_BASE_URL=<your-value> \
  --from-literal=DEEPSEEK_EXTRACT_MODEL=<your-value> \
  --from-literal=DEEPSEEK_FINAL_MODEL=<your-value> \
  --from-literal=DEV_FORCE_KILL_PORT=false \
  --from-literal=FIREBASE_DATABASE_URL=<your-value> \
  --from-literal=FIREBASE_PROJECT_ID=<your-value> \
  --from-literal=GOOGLE_APPLICATION_CREDENTIALS=<base64-encoded-service-account-json> \
  --from-literal=GRIM_FCM_TOPIC=<your-value> \
  --from-literal=NVIDIA_API_KEY=<your-value> \
  --from-literal=NVIDIA_BASE_URL=<your-value> \
  --from-literal=NVIDIA_EXTRACT_MODEL=<your-value> \
  --from-literal=NVIDIA_FINAL_MODEL=<your-value> \
  --from-literal=OPENAI_API_KEY=<your-value> \
  --from-literal=OPENAI_BASE_URL=https://api.openai.com/v1 \
  --from-literal=OPENAI_EXTRACT_MODEL=<your-value> \
  --from-literal=OPENAI_FINAL_MODEL=<your-value> \
  --from-literal=OPENROUTER_API_KEY=<your-value> \
  --from-literal=OPENROUTER_BASE_URL=https://openrouter.ai/api/v1 \
  --from-literal=OPENROUTER_EXTRACT_MODEL=<your-value> \
  --from-literal=OPENROUTER_FINAL_MODEL=<your-value> \
  --from-literal=PORT=3001 \
  --from-literal=S3_ACCESS_KEY_ID=<your-value> \
  --from-literal=S3_BUCKET_DEVELOPMENT=<your-value> \
  --from-literal=S3_BUCKET_PRODUCTION=<your-value> \
  --from-literal=S3_BUCKET_TESTING=<your-value> \
  --from-literal=S3_ENDPOINT=<your-value> \
  --from-literal=S3_PRESIGN_TTL_SECONDS=604800 \
  --from-literal=S3_REGION=us-east-1 \
  --from-literal=S3_SECRET_ACCESS_KEY=<your-value> \
  --dry-run=client -o yaml | kubectl apply -f -

# 2b. Stateful infra + ESO custom resources.
kubectl apply -k .

# 3. Vault (Helm chart inflated by kustomize) + bootstrap jobs.
#    vault-bootstrap initialises and unseals vault.
#    vault-seed-secrets populates secret/grim-k8s and secret/grim-app-secret.
#    vault-keycloak-oidc wires the OIDC auth method.
#    vault-auto-unseal CronJob keeps it unsealed every minute.
#    ESO then syncs both secrets back to Kubernetes within 5 minutes.
kubectl kustomize --enable-helm vault | kubectl apply -f -

# 4. ArgoCD itself.
kubectl apply -k argocd

# 5. The self-managed Application that points back at this repo (path: .).
kubectl apply -k argocd/applications
```

After step 5, ArgoCD reconciles every resource listed in the root
`kustomization.yaml`.

## Sync waves

```
wave 0   ExternalSecret/grim-app-secret      (Secret must exist before pod)
wave 0   everything else (default)
wave 10  Job/keycloak-bootstrap              (Keycloak must be running)
wave 10  Deployment/grim-app                 (consumes grim-app-secret)
```

## Validation

Before pushing changes, render every entrypoint locally:

```sh
bash scripts/validate.sh
```

The script runs `kubectl kustomize --enable-helm` on each entrypoint and, if
installed, `yamllint` and `kubeconform`.

## Hosts

| Host                                      | Service           |
|-------------------------------------------|-------------------|
| `argocd.lowjungxuan.dpdns.org`            | ArgoCD UI         |
| `keycloak.lowjungxuan.dpdns.org`          | Keycloak          |
| `vault.lowjungxuan.dpdns.org`             | Vault UI          |
| `minio.lowjungxuan.dpdns.org`             | MinIO console     |
| `s3.lowjungxuan.dpdns.org`                | MinIO S3 API      |
| `api.lowjungxuan.dpdns.org`               | grim-app backend  |

## Health checks

```sh
kubectl get pods -A
kubectl get ingress,certificate,externalsecret,application -A
curl -vL https://argocd.lowjungxuan.dpdns.org/
```

Or:

```sh
bash scripts/troubleshoot-secrets.sh
```

## Manual secret refresh

When you edit a value in the Vault UI, ESO refreshes within 5 minutes and
Reloader restarts pods that consume the changed Secret. To force the chain
immediately:

```sh
# 1. Force ESO to resync from Vault now
kubectl -n infra annotate externalsecret grim-app-secret \
  force-sync="$(date +%s)" --overwrite

# 2. Restart grim-app (Reloader normally does this for you)
kubectl -n infra rollout restart deployment grim-app
kubectl -n infra rollout status  deployment grim-app
```

Full flow with diagrams: [docs/secret-refresh-flow.md](docs/secret-refresh-flow.md).

## Conventions

- **Namespace**: All workload resources land in `infra` (set by root `kustomization.yaml`); ArgoCD itself lives in `argocd`.
- **Common labels**: `app.kubernetes.io/part-of: grim-k8s`, `app.kubernetes.io/managed-by: argocd` — applied at root level via kustomize `labels` (with `includeSelectors: false`).
- **Tolerations**: Applied at root level via kustomize patches (no inline tolerations).
- **Secrets**: Single source of truth is Vault (`secret/grim-k8s`, `secret/grim-app-secret`). Real values never enter git.

## Upstream notes

- **MinIO open-source archived 2026-04-25.** Docker images stopped publishing after `RELEASE.2025-09-07T16-13-09Z`; this repo pins that release. Plan a migration (Chainguard image, build from source, or alternative S3-compatible backend) before relying on it long-term.
- **ingress-nginx** plans to archive after Kubecon 2026; consider Gateway API / `ingate` migration in the future.
- **ArgoCD v3.4** introduced an MS Teams Workflows breaking change — not applicable here (no Teams notifications configured).
- **cert-manager v1.19** bumped Go to fix DNS SAN validation CVEs; no API changes for our `ClusterIssuer`.
