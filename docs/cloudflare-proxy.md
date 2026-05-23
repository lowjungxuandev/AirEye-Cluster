# Cloudflare proxy + Origin Certificates

How public TLS works in this repo: Cloudflare terminates TLS at its edge
with its own cert, and the origin (this cluster) presents a long-lived
**Cloudflare Origin Certificate** to Cloudflare. No cert-manager, no
Let's Encrypt, no ACME challenges.

## Why this setup

- Cloudflare's free Origin Cert is valid for **15 years** — manual install
  once, basically zero rotation overhead.
- HTTP-01 ACME breaks when a host is orange-clouded: Cloudflare intercepts
  `/.well-known/acme-challenge/...`, the origin never sees it, and the
  challenge fails.
- Edge TLS termination at Cloudflare gives free DDoS protection, caching,
  and WAF rules. The origin only ever talks to Cloudflare IPs.

## Architecture

```
Browser ──HTTPS (CF cert)──▶ Cloudflare edge
                                   │
                                   │ HTTPS (Origin Cert)
                                   ▼
                            ingress-nginx (origin)
                                   │
                                   ▼
                              cluster pods
```

Cloudflare SSL/TLS mode: **Full (Strict)**. Cloudflare validates the
origin cert against its own Origin CA root — self-signed certs are
rejected, public CAs are not required.

## DNS + proxy setup

In the Cloudflare dashboard for `lowjungxuan.dpdns.org`:

1. **SSL/TLS → Overview** → set to **Full (Strict)**.
2. **DNS** → each of the 6 hosts below must be an A/AAAA record pointed
   at the cluster's public IP with the **proxy toggle on** (orange cloud):
   - `argocd.lowjungxuan.dpdns.org`
   - `keycloak.lowjungxuan.dpdns.org`
   - `minio.lowjungxuan.dpdns.org`
   - `s3.lowjungxuan.dpdns.org`
   - `api.lowjungxuan.dpdns.org`
   - `litellm.lowjungxuan.dpdns.org`
3. **SSL/TLS → Edge Certificates** → confirm **Universal SSL** is Active.
   This is what visitors see.

## Generate the Origin Certificate

Cloudflare dashboard → **SSL/TLS → Origin Server → Create Certificate**.

- Key type: **ECDSA** (smaller, faster handshake) or RSA — either works.
- Hostnames: `*.lowjungxuan.dpdns.org` and `lowjungxuan.dpdns.org`.
  One cert covers all hosts because they share the apex.
- Validity: **15 years**.

Save the two PEM blobs locally — Cloudflare only shows the private key
once:

```
origin.crt   # the certificate block
origin.key   # the private key block
```

These files are credentials. Do **not** commit them. Keep them in a
password manager or wherever you keep the cluster's other root secrets.

## Install as Kubernetes TLS Secrets

Each ingress already references a `tls.secretName`. The Secret names are
fixed in YAML — create one Secret per name, in the right namespace:

| Namespace | Secret name | Used by |
|-----------|-------------|---------|
| `infra` | `aireye-app-tls` | `aireye-app` ingress (`api.…`) |
| `infra` | `keycloak-tls` | `keycloak` ingress (`keycloak.…`) |
| `infra` | `minio-tls` | `minio` ingress (`minio.…`, `s3.…`) |
| `infra` | `litellm-tls` | `litellm` ingress (`litellm.…`) |
| `argocd` | `argocd-tls` | `argocd-server` ingress (`argocd.…`) |

All infra TLS Secrets hold the same wildcard cert + key:

```sh
for name in aireye-app-tls keycloak-tls minio-tls litellm-tls; do
  kubectl -n infra create secret tls "$name" \
    --cert=origin.crt --key=origin.key \
    --dry-run=client -o yaml | kubectl apply -f -
done

kubectl -n argocd create secret tls argocd-tls \
  --cert=origin.crt --key=origin.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

ingress-nginx picks the Secret up automatically the next time the
ingress is reconciled. No pod restart needed.

## Rotate the cert

Origin Certs are valid for 15 years, so rotation is rare. When you do:

1. Generate a new Origin Cert in the Cloudflare dashboard.
2. Re-run the commands above (the `--dry-run=client | apply` form
   overwrites the existing Secrets idempotently).
3. ingress-nginx will pick up the new cert; clients of Cloudflare never
   see it (their connection terminates at the edge).

## Hardening: Authenticated Origin Pulls (optional)

The Origin Cert is only trusted by Cloudflare, so direct connections to
the origin already get a cert warning. To enforce that with an mTLS
check, enable **Authenticated Origin Pulls** in the Cloudflare
dashboard: Cloudflare presents a client cert when it hits the origin,
and ingress-nginx rejects requests without it.

Not wired in this pass — add the ingress annotation +
`auth-tls-secret` ConfigMap reference if you decide to enable it.

## Reverting to Let's Encrypt

If you ever need a host that browsers trust at the origin (e.g.,
grey-clouding a single record for debugging), revert the commit that
removed cert-manager:

```sh
git log --oneline -- cert-manager/
git revert <commit-sha>
```

That restores `cert-manager/`, the root kustomization entry, and the
ingress annotations. You'll also need to re-install the cert-manager
operator and pick an ACME challenge type — HTTP-01 only works when the
host is grey-clouded; DNS-01 (Cloudflare API token) works regardless of
proxy state.
