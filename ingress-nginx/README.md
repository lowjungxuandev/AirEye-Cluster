# ingress-nginx

This overlay installs ingress-nginx for a single-node/bare-metal cluster where
DNS points directly at the node IP.

The important patch is:

- `hostNetwork: true`: makes nginx listen on the node's real ports `80` and `443`
- `dnsPolicy: ClusterFirstWithHostNet`: keeps Kubernetes DNS working for the pod
- control-plane toleration: allows scheduling on a single control-plane node

Apply it before the app manifests:

```sh
kubectl apply -k ingress-nginx
kubectl apply -k .
```

Check it:

```sh
kubectl get pods,svc -n ingress-nginx
ss -ltnp | rg ':(80|443)\s'
curl -vL https://keycloak.lowjungxuan.dpdns.org/
```
