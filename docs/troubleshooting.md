# Troubleshooting

Read-only commands that don't change cluster state. The destructive remediation
is called out where relevant.

## Cheat sheet

```sh
kubectl get pods,ingress,certificate,vaultstaticsecret,application -A
kubectl -n infra  get vaultstaticsecret
kubectl -n argocd get vaultstaticsecret
kubectl -n infra  get secret server-secret grim-app-secret
kubectl -n argocd get application grim-k8s
```

Or run `bash scripts/troubleshoot-secrets.sh` to print the full diagnostic
bundle in one shot.

---

## Vault edit doesn't reach the pod

1. **Is VSO syncing?**
   ```sh
   kubectl -n infra describe vaultstaticsecret grim-app-secret
   ```
   Look at the `Status.Conditions` block. `SecretSynced=True` means the K8s
   Secret was last written successfully.
2. **Force sync now:**
   ```sh
   kubectl -n infra annotate vaultstaticsecret grim-app-secret \
     vso.hashicorp.com/force-sync="$(date +%s)" --overwrite
   ```
3. **Did the K8s Secret actually change?**
   ```sh
   kubectl -n infra get secret grim-app-secret -o jsonpath='{.metadata.resourceVersion}'
   ```
   The number should bump after a real change.
4. **Did VSO trigger a rollout?**
   ```sh
   kubectl -n infra rollout history deployment grim-app
   kubectl -n vault-secrets-operator logs deploy/vault-secrets-operator-controller-manager --tail=50
   ```
5. **Manual restart:**
   ```sh
   kubectl -n infra rollout restart deployment grim-app
   ```

## VaultStaticSecret stuck `SecretSynced=False`

Common causes:

| Symptom (`kubectl describe`)                                  | Fix                                                   |
|---------------------------------------------------------------|-------------------------------------------------------|
| `VaultClientError: permission denied`                          | The Vault Kubernetes auth role `vso-grim-k8s` is not bound to the VSO ServiceAccount or lacks the `grim-k8s-read` policy. Re-run the manual Vault auth setup (see `docs/architecture.md`). |
| `VaultClientError: ... no role found`                          | The Vault role `vso-grim-k8s` is missing entirely. Create it (see `docs/architecture.md`). |
| `Vault path not found`                                         | Vault path is missing — re-run the manual seed (see `docs/architecture.md` § Vault config). |
| `connection refused`                                           | Vault is sealed or pod restarting — check `vault status`. |
| `VaultConnection not found` / `VaultAuth not found`            | The CRs in `vault-secrets-operator/` haven't been applied yet. |

## Vault is sealed

```sh
kubectl exec -n infra vault-0 -- vault status
```

If `Sealed: true`, the auto-unseal CronJob runs every minute. Check it ran
recently:

```sh
kubectl -n infra get cronjob vault-auto-unseal
kubectl -n infra get jobs -l job-name --field-selector status.successful=1 --sort-by=.status.completionTime | tail -5
```

To unseal manually:

```sh
UNSEAL_KEY=$(kubectl get secret -n infra vault-bootstrap-secret \
  -o jsonpath='{.data.VAULT_UNSEAL_KEY}' | base64 -d)
kubectl exec -n infra vault-0 -- vault operator unseal "$UNSEAL_KEY"
```

## ArgoCD says `OutOfSync` on a Secret

VSO mutates `/data` on each Secret it manages, which would normally show as
drift. The grim-k8s Application has `ignoreDifferences` on
`kind: Secret, jsonPointers: [/data]` — if a Secret still appears OutOfSync,
check that the path lives under that Application (and not another one) and
that the JSON pointer matches.

## ArgoCD says `OutOfSync` (general)

```sh
kubectl -n argocd get application grim-k8s -o yaml | yq '.status.sync, .status.health'
kubectl -n argocd logs deploy/argocd-repo-server --tail=200
```

Common causes:

- **`must specify --enable-helm`** — `kustomize.buildOptions: --enable-helm`
  must be in `argocd-cm` (not `argocd-cmd-params-cm`). See
  `argocd/patches/config.yaml`.
- **VSO CRDs missing** — happens before the `vault-secrets-operator` Application
  (sync-wave `-1`) finishes installing the chart. Wait, or re-sync that
  Application first.

## ArgoCD login → `WRONGPASS`

Symptom: Keycloak OIDC login redirects back with a Redis password error.

Cause: ArgoCD pods cached the old Redis password before VSO synced the new
one. The `argocd-redis` VaultStaticSecret lists ArgoCD's server,
repo-server and application-controller in `rolloutRestartTargets`, so this
should self-heal. If it doesn't, restart manually:

```sh
kubectl -n argocd rollout restart deploy/argocd-server deploy/argocd-repo-server
kubectl -n argocd rollout restart statefulset/argocd-application-controller
```

## Pod still uses old env after Secret update

Pod env vars are baked at start time. Confirm:

1. The workload is listed in the VaultStaticSecret's `rolloutRestartTargets`.
2. The VSO operator pod is running:
   ```sh
   kubectl -n vault-secrets-operator get pods
   ```
3. Force a manual rollout:
   ```sh
   kubectl -n infra rollout restart deployment grim-app
   ```
