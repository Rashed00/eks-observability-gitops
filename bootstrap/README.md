# Bootstrap

Things you run **once** per cluster to give ArgoCD the keys to self-manage.

## Prerequisites

- `eks-observability-iac` already applied; `kubectl` configured.
- A release of `eks-observability-helm-charts` published to GitHub Pages
  (so ArgoCD has chart URLs to pull from).

## Steps

### 1. Install ArgoCD itself

ArgoCD has a chicken-and-egg problem: it can't deploy itself if it's not
already running. We install it with Helm directly the first time:

```bash
kubectl create namespace argocd
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd -f argocd-install-values.yaml \
  --version 8.2.2

# Wait for it to be ready
kubectl rollout status deployment/argocd-server -n argocd
```

### 2. Hand ArgoCD the keys to manage everything (including itself)

```bash
kubectl apply -f ../apps/root.yaml
```

This creates the **root Application** — an App-of-Apps that recurses
through every YAML under `apps/`, creating one `Application` per file.
ArgoCD now manages itself: any change in `apps/` (or any of the manifests
they reference) will sync to the cluster within ~3 minutes.

### 3. Watch sync progress

```bash
# In another terminal
watch kubectl get applications -n argocd
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

Total: ~15 minutes from a clean cluster.

### 4. After everything is Healthy, point DNS at the NLB

```bash
cd ../../eks-observability-iac
./scripts/update-dns.sh
```

### 5. Log in

The admin password is the value of `observability/grafana` in AWS Secrets
Manager (set by Terraform). Look up via AWS console or:

```bash
aws secretsmanager get-secret-value --secret-id observability/grafana \
  --query 'SecretString' --output text | jq -r '.admin_password'
```

ArgoCD default admin password lives in the `argocd-initial-admin-secret`
Kubernetes Secret (created by the chart). Retrieve once and change it.

## Why is this manual?

Because the very first ArgoCD pod doesn't have anything to sync from. After
this bootstrap, every subsequent change — including upgrades of ArgoCD
itself — flows through git.
