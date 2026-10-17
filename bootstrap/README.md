# Bootstrap

Things that happen **once** per cluster to install ArgoCD and hand it this
repo.

**Normally you don't run these by hand.** `eks-observability-iac/scripts/spin-up.sh`
does every step below (its `cert`, `argocd`, `dns` and `verify` steps).
This page explains what those steps do, and is the manual fallback if you
need to redo one.

## Prerequisites

- The iac repo applied (`spin-up.sh` up to the `kubeconfig` step) and
  `kubectl` pointing at the hub cluster.
- The chart versions referenced in `apps/` published to the helm-charts
  repo's GitHub Pages.

## Steps

### 1. Put the new certificate ARN in git

Terraform creates a new ACM certificate on every rebuild, so its ARN
changes. The Gateway's load balancer reads it from
`manifests/gateway-api/envoyproxy.yaml`, so it must be in git **before**
ArgoCD syncs.

```bash
cd ../../eks-observability-iac
./scripts/spin-up.sh --from cert      # this step and every one after it
```

Skipping this gives a certificate error on every HTTPS URL.

### 2. Install ArgoCD itself

ArgoCD can't deploy itself before it's running, so the first install is a
plain Helm install. `spin-up.sh` runs:

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm repo add argo https://argoproj.github.io/argo-helm
helm upgrade --install argocd argo/argo-cd -n argocd \
  -f argocd-install-values.yaml --version 8.2.2
kubectl rollout status deployment/argocd-server -n argocd
```

`argocd-install-values.yaml` must **not** be wrapped in an `argo-cd:` key.
We install the argo-cd chart directly, so a wrapper key makes Helm ignore
every setting (including `server.insecure`), and the ArgoCD web page
redirects forever. `spin-up.sh` preflight fails if the wrapper is there.

### 3. Hand ArgoCD this repo

```bash
kubectl apply -f ../apps/root.yaml
```

This creates the **root Application** — an App-of-Apps that recurses
through every YAML under `apps/`, creating one `Application` per file.
From then on, any change in `apps/` (or the manifests they reference)
syncs to the cluster within ~3 minutes.

ArgoCD itself is not one of those Applications. To upgrade ArgoCD, change
the chart version in `spin-up.sh` (`ARGOCD_CHART_VERSION`) and rerun
`./scripts/spin-up.sh --from argocd` (which also reruns the `dns` and
`verify` steps; both are safe to repeat).

### 4. Watch sync progress

```bash
watch kubectl get applications -n argocd
```

Before DNS exists, open the ArgoCD UI with a port-forward:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
# browser: http://localhost:8080   user: admin
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Sync waves run in order: `-2 -> -1 -> 0 -> 1 -> ... -> 8`. Typical timeline:

| Wave | What | Time |
|---|---|---|
| -2 / -1 | AppProjects | < 30s |
| 0 | CRDs + envoy-gateway controller | 1-2 min |
| 1 | metrics-server + external-secrets | 1-2 min |
| 2 | kube-prometheus-stack + gateway-api + secrets stores | 3-5 min |
| 3 | Loki / Tempo / Thanos | 3-5 min |
| 4 | Alloy (DaemonSet) | 1-2 min |
| 5 | Grafana instance | 2-3 min |
| 6 | datasources + HTTPRoutes | < 1 min |
| 7 | dashboards + folders | < 1 min |
| 8 | rules + alertmanager config | < 1 min |

Total: about 15–25 minutes from a clean cluster. `prometheus-0` may stay
`Pending` for a few minutes while Karpenter starts a bigger node.

### 5. Point DNS at the load balancer

```bash
cd ../../eks-observability-iac
./scripts/spin-up.sh --from dns       # waits for the Gateway address, runs update-dns.sh, then verify
```

### 6. Log in

- **Grafana:** `https://grafana.monitoring.<domain>`, user `admin`. The
  password is in `terraform.tfvars`, or:

  ```bash
  aws secretsmanager get-secret-value --secret-id observability/grafana \
    --query 'SecretString' --output text | jq -r '.admin_password'
  ```

- **ArgoCD:** `https://argocd.monitoring.<domain>`, user `admin`, password
  from the `argocd-initial-admin-secret` (command above). Change it after
  the first login.

## Why is this not in git like everything else?

Because the very first ArgoCD pod has nothing to sync from, and the
certificate ARN does not exist until Terraform has run. After this
bootstrap, every change to the platform (except the ArgoCD install
itself) flows through git.