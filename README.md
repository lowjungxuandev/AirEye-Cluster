# GRIM-K8S

Kustomize layout for the infra namespace services:

- `ingress-nginx/`: installs ingress-nginx and patches it to listen on node ports `80` and `443`
- `postgres/`: PostgreSQL stateful workload
- `redis/`: Redis stateful workload used by Argo CD
- `keycloak/`: Keycloak deployment, service, and public ingress
- `vault/`: Vault Helm values for Vault server, Vault Agent Injector, and public ingress
- `minio/`: MinIO object storage with Keycloak OIDC auth, secrets stored in Vault
- `cert-manager/`: Let's Encrypt `ClusterIssuer`
- `external-secrets/`: External Secrets resources that sync Kubernetes secrets from Vault KV
- `argocd/`: Argo CD install, Keycloak OIDC config, ingress, and the `grim-k8s` app

Apply order:

```sh
kubectl apply -k ingress-nginx
kubectl apply -k .
helm upgrade --install vault hashicorp/vault --version 0.32.0 --namespace infra -f vault/values.yaml
kubectl apply -k vault
kubectl apply -k argocd
kubectl apply -k argocd/applications
```

Why ingress-nginx is separate:

The root `kustomization.yaml` sets `namespace: infra` for app resources. The ingress
controller must stay in the `ingress-nginx` namespace, so it has its own kustomize
overlay.

Useful checks:

```sh
kubectl get pods -n ingress-nginx
kubectl get pods,ingress,certificate -n infra
kubectl get pods,ingress,externalsecret,application -n argocd
kubectl logs -n infra job/redis-smoke-test
curl -vL https://keycloak.lowjungxuan.dpdns.org/
curl -vL https://vault.lowjungxuan.dpdns.org/
curl -vL https://argocd.lowjungxuan.dpdns.org/
curl -vL https://minio.lowjungxuan.dpdns.org/
```
