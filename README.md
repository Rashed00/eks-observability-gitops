# eks-observability-gitops

**ArgoCD GitOps for the observability platform.**

This repo decides *what runs in the cluster*. The AWS infrastructure is
in [`eks-observability-iac`](../eks-observability-iac/), the Helm chart
definitions are in [`eks-observability-helm-charts`](../eks-observability-helm-charts/),
and this repo wires them together with ArgoCD Applications + a handful
of native Kubernetes manifests (Gateway API resources, PrometheusRule,
GrafanaDashboard, ExternalSecret, ...).

> One of three repos. See the [top-level README](../README.md) for how this
> repo fits with the other two.

---

## The big picture

```
                                     ┌────────────────────────────────────┐
                                     │  helm-charts repo (GitHub Pages)   │
                                     │  https://<you>.github.io/...       │
                                     │  - kube-prometheus-stack-1.0.0     │
                                     │  - loki-1.0.0                      │
                                     │  - tempo-1.0.0                     │
                                     │  - thanos-1.0.0                    │
                                     │  - ...                             │
                                     └────────────────────────────────────┘
                                                ▲
                                                │ ArgoCD pulls
                                                │ versioned charts
                                                │
   ┌────────────────────────────────────────────┴─────────────────────────┐
   │  THIS repo (eks-observability-gitops)                                │
   │                                                                      │
   │  ┌──────────────────────────────────────────────────────────────┐    │
   │  │ apps/                                                        │    │
   │  │   root.yaml                  ──── ArgoCD root App-of-Apps    │    │
   │  │   projects/                  ──── AppProjects (boundaries)   │    │
   │  │   infrastructure/*.yaml      ──── ArgoCD Applications (waves)│    │
   │  │   observability/*.yaml       ──── ArgoCD Applications        │    │
   │  └──────────────────────────────────────────────────────────────┘    │
   │                                                                      │
   │  ┌──────────────────────────────────────────────────────────────┐    │
   │  │ manifests/                                                   │    │
   │  │   gateway-api/               ──── Gateway, HTTPRoutes, Sec…  │    │
   │  │   external-secrets/          ──── ClusterSecretStore + ESec  │    │
   │  │   alertmanager/              ──── AlertmanagerConfig         │    │
   │  │   prometheus/rules/          ──── PrometheusRule CRs         │    │
   │  │   loki/rules/                ──── log-based alert rules      │    │
   │  │   grafana/                   ──── Grafana CR + datasources   │    │
   │  │                                   + folders + dashboards     │    │
   │  └──────────────────────────────────────────────────────────────┘    │
   └──────────────────────────────────────────────────────────────────────┘
                                                │
                                                ▼
                                       Kubernetes cluster
```

The split inside this repo:

| Directory | What lives here |
|---|---|
| `apps/` | ArgoCD `Application` and `AppProject` CRs — the "what runs where" decisions. |
| `manifests/` | Native Kubernetes resources (Gateway API, PrometheusRule, GrafanaDashboard, ExternalSecret, ...) referenced by Applications via `path: manifests/...`. |
| `bootstrap/` | The one-time install scripts to get ArgoCD running. |
| `.github/workflows/` | CI: validate YAML, render kustomize, optionally `argocd app diff` on PR. |

---

## Sync waves

ArgoCD's `sync-wave` annotation orders deployment so things land in
dependency order. Lower waves go first.

| Wave | What | Why |
|---|---|---|
| -2 | AppProject: `infrastructure` | Defines source repos / destinations |
| -1 | AppProject: `observability` | Same |
| 0 | prometheus-operator-crds, envoy-gateway | CRDs + the controller for `Gateway` |
| 1 | metrics-server, external-secrets | `kubectl top` and AWS Secrets Manager sync |
| 2 | kube-prometheus-stack, grafana-operator, gateway-api-resources, cluster-secret-store, observability-secrets | Prometheus, Operator CRs, Gateway/HTTPRoutes, secrets stores |
| 3 | loki, tempo, thanos | Long-term storage backends |
| 4 | alloy | Telemetry collector (depends on Loki/Tempo URLs existing) |
| 5 | grafana-instance | Provisioned by the operator |
| 6 | grafana-datasources, HTTPRoutes (in wave 6 inside kustomize) | Wired after Grafana exists |
| 7 | grafana-folders, grafana-dashboards-* | Reference folders + datasources |
| 8 | prometheus-rules-*, loki-rules, alertmanager-config | Alerts (need Prometheus + Alertmanager running) |

End to end: ~15 minutes on a clean cluster.

---

## Prerequisites

- The IaC repo applied; `kubectl` configured.
- The helm-charts repo has at least one release published to GitHub Pages.
- `helm` (>= 3.14) installed locally for the one-time ArgoCD install.
- (Optional) `argocd` CLI for `argocd app diff` and manual sync triggers.

---

## First-time setup

```bash
cd bootstrap
# Edit argocd-install-values.yaml to replace <OBSERVABILITY_DOMAIN>

# 1. Install ArgoCD itself
kubectl create namespace argocd
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd -f argocd-install-values.yaml --version 8.2.2

# 2. Hand it the keys
kubectl apply -f ../apps/root.yaml

# 3. Watch
watch kubectl get applications -n argocd

# 4. Once Healthy, point DNS at the NLB (run from the iac repo):
cd ../../eks-observability-iac && ./scripts/update-dns.sh
```

Full walkthrough in [`bootstrap/README.md`](./bootstrap/README.md).

---

## Day-2 operations

### Change a manifest

1. Edit a file under `manifests/`.
2. Open a PR — CI runs `yamllint`, `kustomize build` + `kubeconform` on
   the affected overlay, and (if configured) `argocd app diff` against
   the live cluster.
3. Merge — ArgoCD picks up the change within ~3 minutes.

### Upgrade a chart

The chart upgrade itself happens in `eks-observability-helm-charts`. Once
it's released (a new umbrella chart version):

1. In this repo, bump the `targetRevision:` field in the relevant
   `apps/*/<chart>.yaml` Application.
2. PR + merge.
3. ArgoCD upgrades the release.

### Add a Grafana dashboard

1. Create `manifests/grafana/dashboards/<folder>/<name>.yaml` with a
   `GrafanaDashboard` CR (use `grafanaCom.id` to reference a community
   dashboard, or paste in `json:` to vendor it).
2. Add the file to the matching `kustomization.yaml`.
3. PR + merge. The grafana-operator picks it up within `resyncPeriod`.

### Add a Prometheus alert

1. Create a `PrometheusRule` under `manifests/prometheus/rules/<group>/`.
2. Add to the matching `kustomization.yaml`.
3. PR + merge.

### Add a spoke cluster

1. Provision the spoke (in `eks-observability-iac/spokes/`).
2. Create `eks-observability-iac/spoke-alloy-values/<spoke-name>/alloy-values.yaml`.
3. Run `eks-observability-iac/scripts/install-spoke-alloy.sh <spoke-name>`.

The spoke is **not** an ArgoCD-managed cluster. Spokes are intentionally
hands-off — they push telemetry but nothing in this gitops repo deploys
to them.

---

## CI/CD

| Workflow | When | What |
|---|---|---|
| `pr-validate.yml` | PR opened / updated | yamllint + `kustomize build` (per overlay) + `kubeconform` + ArgoCD Application schema check |
| `argocd-diff.yml` | PR (optional) | Logs in to ArgoCD via OIDC + token, runs `argocd app diff` for changed apps, comments the diff on the PR. Skipped if not configured. |

The diff workflow is the "dream" CI experience: you see exactly what a PR
will change in the live cluster before you merge it. Requires:

- `vars.ARGOCD_SERVER` — the ArgoCD server hostname.
- `vars.AWS_OIDC_ROLE_ARN`, `vars.AWS_REGION`, `vars.CLUSTER_NAME`.
- `secrets.ARGOCD_AUTH_TOKEN` — a token from `argocd account generate-token`.

---

## Placeholders

The committed YAMLs contain `<AWS_REGION>`, `<OBSERVABILITY_DOMAIN>`,
`<THANOS_BUCKET>`, `<ACM_CERTIFICATE_ARN>`, `<your-org>`. These are
intentional — you replace them once when forking the repo.

`scripts/configure.sh` (not yet written; junior exercise) would automate
this with `sed`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Applications stuck in `OutOfSync` immediately after bootstrap | The helm-charts repo's GitHub Pages isn't serving yet. Wait for the release workflow to finish. |
| `kube-prometheus-stack` shows `ComparisonError` mentioning CRDs | The `prometheus-operator-crds` Application hasn't synced yet. Trigger a sync manually. |
| External Secrets stays Synced but the K8s Secret never appears | The IAM role lacks `secretsmanager:GetSecretValue`. Check IRSA in the IaC repo's `secrets.tf`. |
| Envoy NLB stays Pending | Check `kube-system / aws-load-balancer-controller` logs. The IAM role attached to its SA must allow ELB/VPC actions. |
| `Gateway observability-gateway` has no address | Wait. The NLB takes 2–4 minutes to provision the first time. |
