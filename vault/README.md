# Vault

Vault is installed with the official HashiCorp Helm chart.

It uses:

- `hashicorp/vault` Helm chart `0.32.0`
- `hashicorp/vault-k8s` injector from that chart
- PostgreSQL storage via `VAULT_PG_CONNECTION_URL` from `server-secret`
- bootstrap and auto-unseal jobs in `vault/`
- nginx ingress at `https://vault.lowjungxuan.dpdns.org/`

Deploy:

```sh
helm upgrade --install vault hashicorp/vault \
  --version 0.32.0 \
  --namespace infra \
  -f vault/values.yaml

kubectl apply -k vault
```

Check:

```sh
kubectl get pods,svc,ingress,certificate -n infra | rg 'vault|NAME'
curl -kI https://vault.lowjungxuan.dpdns.org/
```
