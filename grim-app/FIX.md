# Fix: grim-app-tls Certificate Rate Limited

## Problem

`grim-app-tls` certificate stuck in `False` / `Issuing` state:

```
Failed to create Order: 429 urn:ietf:params:acme:error:rateLimited:
too many certificates (5) already issued for this exact set of
identifiers in the last 168h0m0s, retry after 2026-05-11 16:15:07 UTC
```

Let's Encrypt limits 5 duplicate certificates per domain set per week.
Repeated ArgoCD syncs + cluster re-bootstraps exhausted the quota for
`api.lowjungxuan.dpdns.org`.

## Fix

**1. Added `letsencrypt-staging` ClusterIssuer** (`cert-manager/cluster-issuer.yaml`)

Points to `https://acme-staging-v02.api.letsencrypt.org/directory` — no
rate limits, but issues untrusted certificates (for dev/testing only).

**2. Switched `grim-app` ingress to staging** (`grim-app/ingress.yaml`)

```diff
-    cert-manager.io/cluster-issuer: letsencrypt-prod
+    cert-manager.io/cluster-issuer: letsencrypt-staging
```

## To revert to production

Once the rate limit clears (after **2026-05-11 16:15 UTC**):

1. Delete the staging cert secret so cert-manager re-issues:
   ```bash
   kubectl delete secret grim-app-tls -n infra
   ```
2. Revert the ingress annotation back to `letsencrypt-prod`.
3. Commit and push — ArgoCD will apply automatically.
