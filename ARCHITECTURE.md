# Architecture

This document explains why the gitops repo is shaped this way.

## App-of-Apps

The root `Application` (`apps/root.yaml`) points at the `apps/` directory
itself and tells ArgoCD: "anything you find here is another Application."

ArgoCD recurses, finds `apps/projects/*.yaml` + `apps/infrastructure/*.yaml`
+ `apps/observability/*.yaml`, creates one `Application` (or `AppProject`)
per file. From that moment on, everything under `apps/` is managed from git.

ArgoCD itself is **not** one of those Applications. It is installed once
with Helm by `eks-observability-iac/scripts/spin-up.sh` (chart version
pinned there), and upgraded the same way.

The root Application uses the built-in `default` project, not
`infrastructure` or `observability`. Those two AppProjects are created by
the root app itself (wave -2/-1), so the root app cannot belong to either
of them.

Why this pattern?

- **One place to add a new app.** Drop a YAML in `apps/<group>/`, push.
- **Bootstrapping is one `kubectl apply -f apps/root.yaml`** (done by
  `spin-up.sh`).
- **Sync waves are explicit.** Each Application has an
  `argocd.argoproj.io/sync-wave` annotation; ArgoCD orders rollout
  globally.

Alternative considered: **ApplicationSet** (generator-based). More
powerful for templating across many clusters, but overkill for a single
cluster — App-of-Apps is simpler and obvious to a junior reading the YAMLs.

## Apps vs manifests

A common mistake is to put native Kubernetes resources inside `apps/`.
Don't. The split is:

- `apps/` → **ArgoCD's idea of the world**: `Application`, `AppProject`.
- `manifests/` → **The world**: `Gateway`, `HTTPRoute`, `PrometheusRule`,
  `GrafanaDashboard`, `ExternalSecret`, `Secret`, etc.

An ArgoCD `Application` in `apps/observability/grafana-dashboards.yaml`
says "deploy the resources under `manifests/grafana/dashboards/kubernetes/`."
The Application is the deployment unit; the manifests are the payload.

## Helm comes from a separate repo (eks-observability-helm-charts)

Every `Application` that deploys a Helm chart points its `repoURL` at the
helm-charts repo's GitHub Pages URL and pins a `targetRevision` (chart
version). The values file lives next to the chart, **not** in this repo
— see the helm-charts repo's `ARCHITECTURE.md`.

Nobody edits `targetRevision` by hand. When the helm-charts repo releases
a new chart version, it sends a `chart-released` event here. The
`bump-target-revision.yml` workflow waits until the version is in the
Helm repo index, runs `scripts/ci/set-target-revision.sh` to update every
Application that uses that chart (only the `targetRevision` line changes,
and it never goes backwards), and pushes to `main`. ArgoCD then deploys it.

Consequence: this repo is small. It only contains what's truly
declarative-Kubernetes — Application metadata, CRDs, and overlays.

## Sync waves, explicitly

```
wave -2: AppProject infrastructure
wave -1: AppProject observability
wave  0: CRDs + controllers       ← prometheus-operator-crds, envoy-gateway
wave  1: bootstrap operators      ← metrics-server, external-secrets
wave  2: heavy stack + secret stores + ops CRs
wave  3: storage backends         ← loki, tempo, thanos
wave  4: collectors               ← alloy
wave  5: visualization instance   ← grafana
wave  6: datasources + routes     ← needs Grafana + Gateway up
wave  7: dashboards + folders
wave  8: rules + alertmanager     ← needs Prometheus + Alertmanager up
```

Each wave waits for the previous wave's Applications to be Healthy before
syncing. If you add something new, give it a wave number that respects
its dependencies.

## Secrets stay out of git

The only place secrets exist in this platform is **AWS Secrets Manager**,
populated by Terraform (in the IaC repo). The gitops repo defines
`ExternalSecret` CRs (`manifests/external-secrets/secrets/`) that tell
the External Secrets Operator to fetch them and produce in-cluster
Kubernetes `Secret`s. The IRSA permissions are also in the IaC repo.

So:

- Adding a secret = (1) write it to Secrets Manager via Terraform; (2)
  add an `ExternalSecret` CR here.
- Rotating a secret = (1) update via Terraform; ESO syncs within
  `refreshInterval` (1h by default).

Never commit a secret value.

One exception that is **not** a secret: `thanos-objstore.yaml` is a plain
Kubernetes `Secret` in git. It holds only the bucket name, endpoint and
region; access comes from the Thanos IRSA role, so there are no
credentials in it. It is a plain Secret because an `ExternalSecret` with
nothing to fetch is rejected by the External Secrets webhook.

## Basic auth on the remote_write endpoints

Spoke clusters use HTTPS basic auth to push to the hub:

- `prometheus.<domain>/api/v1/write`
- `loki.<domain>/loki/api/v1/push`
- `tempo.<domain>` (OTLP)

The auth is enforced by an Envoy `SecurityPolicy`
(`manifests/gateway-api/securitypolicy-basic-auth.yaml`) that targets
those HTTPRoutes. The credentials come from Secrets Manager via External
Secrets (`manifests/external-secrets/secrets/remote-write-basic-auth.yaml`),
which writes the `basic-auth-observability` Secret.

The password hash must be in **`{SHA}` format** (`user:{SHA}<base64 SHA1>`).
Envoy Gateway does not accept bcrypt: with a bcrypt hash it rejects every
route update and all HTTPS routes return 500. Terraform builds the SHA
hash in `eks-observability-iac/environments/production/secrets.tf`.

`manifests/gateway-api/basic-auth-secret.yaml` only documents the shape of
that Secret. It is not in the kustomization, so it is never deployed.

Grafana and ArgoCD have their own login UIs — they are deliberately NOT
covered by basic auth.

## DNS

The NLB hostname is dynamic (AWS assigns it when the Service is created).
We deliberately don't manage DNS from Terraform because Terraform doesn't
know the NLB hostname until after ArgoCD has synced. Instead:

1. ArgoCD deploys Envoy Gateway → AWS provisions the NLB.
2. The `dns` step of `eks-observability-iac/scripts/spin-up.sh` waits for
   the Gateway address and runs `update-dns.sh`, which writes the wildcard
   CNAME in Route53. `destroy.sh` removes it again.

## The certificate ARN is the one value that changes per rebuild

`manifests/gateway-api/envoyproxy.yaml` carries the ACM certificate ARN for
the NLB's TLS listener. Terraform creates a new certificate on every
rebuild, so the ARN changes. The `cert` step of `spin-up.sh` writes the new
ARN into that file, commits and pushes it before ArgoCD is installed. That
is why the git history has many "set ACM certificate ARN" commits.

If we ever want this automated, the right answer is `external-dns` — a
controller that watches HTTPRoute resources and reconciles Route53 records.
Not done today to keep moving parts low.