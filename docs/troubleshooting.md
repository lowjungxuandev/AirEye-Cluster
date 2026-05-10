# Troubleshooting

Read-only commands that don't change cluster state. The destructive remediation
is called out where relevant.

## Cheat sheet

```sh
kubectl get pods,ingress,certificate,externalsecret,application -A
kubectl -n infra get externalsecret
kubectl -n argocd get externalsecret
kubectl -n infra get secret server-secret grim-app-secret
kubectl -n argocd get application grim-k8s
```

Or run `bash scripts/troubleshoot-secrets.sh` to print the full diagnostic
bundle in one shot.

---

## Vault edit doesn't reach the pod

1. **Is ESO syncing?**
   ```sh
   kubectl -n infra describe externalsecret grim-app-secret
   ```
   Look at the `Status.Conditions` block. `Ready=True` with reason
   `SecretSynced` means the K8s Secret was last written successfully.
2. **Force sync now:**
   ```sh
   kubectl -n infra annotate externalsecret grim-app-secret \
     force-sync="$(date +%s)" --overwrite
   ```
3. **Did the K8s Secret actually change?**
   ```sh
   kubectl -n infra get secret grim-app-secret -o jsonpath='{.metadata.resourceVersion}'
   ```
   The number should bump after a real change.
4. **Did Reloader trigger a rollout?**
   ```sh
   kubectl -n infra rollout history deployment grim-app
   kubectl -n infra logs -n infra -l app.kubernetes.io/name=reloader --tail=50
   ```
5. **Manual restart:**
   ```sh
   kubectl -n infra rollout restart deployment grim-app
   ```

## ExternalSecret stuck `Ready=False`

Common causes:

| Symptom (`kubectl describe`)                                   | Fix                                                   |
|----------------------------------------------------------------|-------------------------------------------------------|
| `unable to validate store: ... vault-bootstrap-secret not found` | Vault hasn't been bootstrapped yet. Apply `vault/`. |
| `permission denied` from Vault                                  | Token in `vault-bootstrap-secret` was rotated out — re-run vault bootstrap or restore the secret. |
| `Status: SecretSyncedError`                                     | Vault path is missing — re-run `vault-seed-secrets` Job. |
| `vault: connection refused`                                     | Vault is sealed or pod restarting — check `vault status`. |

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

## ArgoCD says `OutOfSync`

```sh
kubectl -n argocd get application grim-k8s -o yaml | yq '.status.sync, .status.health'
kubectl -n argocd logs deploy/argocd-repo-server --tail=200
```

Common causes:

- **`must specify --enable-helm`** — `kustomize.buildOptions: --enable-helm`
  must be in `argocd-cm` (not `argocd-cmd-params-cm`). See
  `argocd/patches/config.yaml`.
- **Webhook to a missing service** — happens when the ESO CRD is uninstalled
  while ExternalSecrets exist. Reinstall ESO before deleting CRs.

## ArgoCD login → `WRONGPASS`

Symptom: Keycloak OIDC login redirects back with a Redis password error.

Cause: ArgoCD pods cached the old Redis password before ESO synced the new
one. Restart server-side components:

```sh
kubectl -n argocd rollout restart deploy/argocd-server deploy/argocd-repo-server
kubectl -n argocd rollout restart statefulset/argocd-application-controller
```

## Wrong namespace for ExternalSecret

`ClusterSecretStore` is cluster-scoped, but `ExternalSecret` is namespaced.
The K8s Secret it creates lands in the **same namespace as the
ExternalSecret**. If `grim-app-secret` doesn't appear in `infra`, check
`metadata.namespace` on the ExternalSecret.

## Pod still uses old env after Secret update

Pod env vars are baked at start time. Confirm:

1. The Deployment annotation `secret.reloader.stakater.com/reload: <secret-name>` is present.
2. Reloader is actually running:
   ```sh
   kubectl -n infra get pods -l app.kubernetes.io/name=reloader
   ```
3. Force a manual rollout:
   ```sh
   kubectl -n infra rollout restart deployment grim-app
   ```

## Reloader didn't restart the deployment

```sh
kubectl -n infra logs deploy/reloader-reloader --tail=200 | grep grim-app
```

If the logs don't mention `grim-app`, either the annotation is wrong or
Reloader isn't watching `infra`. Check the chart values in
`reloader/kustomization.yaml`.
