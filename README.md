# eks-observability-gitops

**ArgoCD GitOps for the observability platform.**

This repo decides *what runs in the cluster*. The AWS infrastructure is
in [`eks-observability-iac`](https://github.com/Rashed00/eks-observability-iac),
the Helm chart definitions are in
[`eks-observability-helm-charts`](https://github.com/Rashed00/eks-observability-helm-charts),
and this repo wires them together with ArgoCD Applications + a handful
of native Kubernetes manifests (Gateway API resources, PrometheusRule,
GrafanaDashboard, ExternalSecret, ...).

> One of three repos. Clone all three side by side: the iac repo's
> `spin-up.sh` expects this repo at `../eks-observability-gitops`.

---

## The big picture

```
                                     ┌────────────────────────────────────┐
                                     │  helm-charts repo (GitHub Pages)   │
                                     │  https://rashed00.github.io/       │
                                     │        eks-observability-helm-charts│
                                     │  - kube-prometheus-stack, loki,    │
                                     │    tempo, thanos, alloy, ...       │
                                     └────────────────────────────────────┘
                                          ▲                  │
                         ArgoCD pulls     │                  │ "chart-released"
                         versioned charts │                  │ event → bot sets
                                          │                  ▼ targetRevision
   ┌──────────────────────────────────────┴───────────────────────────────┐
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
| `bootstrap/` | The ArgoCD install values (`argocd-install-values.yaml`), used by `spin-up.sh`. |
| `scripts/ci/` | `set-target-revision.sh`, used by the `bump-target-revision.yml` workflow. |
| `.github/workflows/` | CI: validate YAML, render kustomize, optionally `argocd app diff` on PR, and bump `targetRevision` when a chart is released. |

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

The root app itself is in the `default` project: the other two projects
are created by it, so it cannot belong to them.

End to end: about 15–25 minutes on a clean cluster.

---

## Prerequisites

- The helm-charts repo has the chart versions this repo references
  published to GitHub Pages.
- This repo and the helm-charts repo are **public**, so ArgoCD reads them
  without credentials.
- (Optional) `argocd` CLI for `argocd app diff` and manual sync triggers.

---

## First-time setup

You don't install ArgoCD by hand. From the iac repo:

```bash
cd ../eks-observability-iac
./scripts/spin-up.sh
```

After Terraform, `spin-up.sh` does everything this repo needs, in order:

1. **`cert`**: writes the new ACM certificate ARN into
   `manifests/gateway-api/envoyproxy.yaml`, commits and pushes it to `main`.
   The ARN changes on every rebuild, which is why the history has many
   "set ACM certificate ARN" commits.
2. **`argocd`**: installs ArgoCD with Helm using
   `bootstrap/argocd-install-values.yaml`, then applies `apps/root.yaml`.
3. **`dns`**: waits for the Gateway's load balancer and points
   `*.monitoring.<domain>` at it.
4. **`verify`**: waits for Grafana and lists any app that is not
   Synced + Healthy.

`spin-up.sh` pushes to this repo, so commit or stash your local changes
here before running it.

Details and the manual equivalent: [`bootstrap/README.md`](./bootstrap/README.md).

---

## Day-2 operations

### Change a manifest

1. Edit a file under `manifests/`.
2. Open a PR — CI runs `yamllint`, `kustomize build` + `kubeconform` on
   the affected overlay, and (if configured) `argocd app diff` against
   the live cluster.
3. Merge — ArgoCD picks up the change within ~3 minutes.

### Upgrade a chart

Happens automatically. Change the chart in `eks-observability-helm-charts`
and push. Its release workflow bumps and publishes the chart, then sends a
`chart-released` event here. The `bump-target-revision.yml` workflow:

1. waits until that version is in the Helm repo index,
2. sets `targetRevision` in every Application that uses the chart,
3. commits `chore(apps): bump <chart> targetRevision to <version>` to `main`.

ArgoCD upgrades the release. **Run `git pull` here** before your next
change, because the bot committed to `main`.

It skips Applications already on the same or a newer version, and a chart
that no Application uses.

To set a version by hand (or catch up a missed event): Actions →
"Bump targetRevision" → Run workflow, with the chart name and version.

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

1. Provision the spoke (in `eks-observability-iac/spokes/`, with its own
   Terraform state key — see the iac README).
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
| `bump-target-revision.yml` | `chart-released` event from the helm-charts repo, or manual run | Waits for the chart version in the Helm repo, updates `targetRevision`, pushes to `main`. |

`bump-target-revision.yml` needs, once: Settings → Actions → General →
Workflow permissions: **Read and write**. If `main` is protected, allow
GitHub Actions to push.

The diff workflow is the "dream" CI experience: you see exactly what a PR
will change in the live cluster before you merge it. Requires:

- `vars.ARGOCD_SERVER` — the ArgoCD server hostname.
- `vars.AWS_OIDC_ROLE_ARN`, `vars.AWS_REGION`, `vars.CLUSTER_NAME`.
- `secrets.ARGOCD_AUTH_TOKEN` — a token from `argocd account generate-token`.

---

## Environment values

The manifests hold the real values for our one environment (domain,
bucket names, account ID in role ARNs). There are no `<PLACEHOLDER>`
strings to replace. The one value that changes on every rebuild, the ACM
certificate ARN, is written by `spin-up.sh`.

No secret values are committed. Passwords live in AWS Secrets Manager and
are synced by External Secrets. `thanos-objstore.yaml` is a plain Secret
but holds only the bucket name and region (see
[`ARCHITECTURE.md`](./ARCHITECTURE.md)).

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| An Application says `chart not found` | Its `targetRevision` is not in the Helm repo index. Check the helm-charts release run, or the version in the Application. |
| Applications stuck in `OutOfSync` immediately after bootstrap | The helm-charts repo's GitHub Pages isn't serving yet. Wait for the release workflow to finish. |
| `kube-prometheus-stack` shows `ComparisonError` mentioning CRDs | The `prometheus-operator-crds` Application hasn't synced yet. Trigger a sync manually. |
| External Secrets stays Synced but the K8s Secret never appears | The IAM role lacks `secretsmanager:GetSecretValue`. Check IRSA in the IaC repo's `secrets.tf`. |
| Every HTTPS route returns 500 | Envoy rejected the basic-auth Secret. The hash must be `{SHA}`, not bcrypt. See `ARCHITECTURE.md`. |
| HTTPS gives a certificate error | `envoyproxy.yaml` still has the old ACM ARN. Run `spin-up.sh --from cert`. |
| ArgoCD web page redirects forever | `bootstrap/argocd-install-values.yaml` is wrapped in an `argo-cd:` key. Remove it; `spin-up.sh` preflight checks this. |
| Envoy NLB stays Pending | Check `kube-system / aws-load-balancer-controller` logs. The IAM role attached to its SA must allow ELB/VPC actions. |
| `Gateway observability-gateway` has no address | Wait. The NLB takes 2–4 minutes to provision the first time. |
| `git push` rejected | A bot pushed to `main` (a `targetRevision` bump or the cert ARN). Run `git pull`, then push again. |