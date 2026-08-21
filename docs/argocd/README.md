# Argo CD Applications

What's in `argocd/applications/` and how each `Application` maps to a path
under `kubernetes/`. Everything here is reconciled automatically once
`bootstrap/root-application.yaml` exists — see `docs/bootstrap/README.md` for
the one-time manual steps that get to that point. This doc is the reference
for what happens *after* that: the steady-state shape of the app-of-apps tree.

This covers what's here today. It's expected to grow — see
[Status](#status) at the bottom.

## The app-of-apps tree

```
root-application.yaml (bootstrap/, applied manually)
  └─ watches argocd/applications/*.yaml
       ├─ namespaces.yaml                     → kubernetes/namespaces
       ├─ producer.yaml                       → kubernetes/producer/overlays/dev
       ├─ consumer.yaml                       → kubernetes/consumer/overlays/dev
       ├─ health-server.yaml                  → kubernetes/health-server/overlays/dev
       ├─ kafka.yaml                          → kubernetes/kafka/base
       ├─ clickhouse.yaml                     → kubernetes/clickhouse/base
       ├─ monitoring.yaml                     → kubernetes/monitoring
       ├─ ingress.yaml                        → kubernetes/ingress/base
       └─ aws-load-balancer-controller.yaml   → Helm chart (eks-charts, not this repo)
```

Nine files, nine `Application` objects, one per service. Each is independent
— Argo CD reconciles them in parallel, not in the order listed above (see
[Ordering](#ordering-within-an-application) for the one place ordering
actually matters).

## Shared shape

Every `Application` in this directory follows the same skeleton:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nyc-taxi-<service>
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: nyc-taxi
  source:
    repoURL: "https://github.com/tarique-iqbal/nyc-taxi-gitops.git"
    targetRevision: main
    path: kubernetes/<service>[/overlays/dev]
  destination:
    server: https://kubernetes.default.svc
    namespace: <target-namespace>
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- **`project: nyc-taxi`** — every Application is scoped by the AppProject in
  `bootstrap/project.yaml`; none use Argo CD's `default` project. See
  `docs/bootstrap/README.md#projectyaml-appproject`.
- **`finalizers`** — deleting an Application also deletes what it manages,
  rather than orphaning resources on the cluster.
- **`syncPolicy.automated: {prune: true, selfHeal: true}`** on every single
  one, no exceptions — a resource removed from git gets pruned from the
  cluster, and a manual `kubectl edit` against a live resource gets reverted
  on the next reconcile. This is what "GitOps" means concretely in this repo:
  the cluster is not a source of truth, only git is.
- **`syncOptions: [CreateNamespace=true]`** — every Application except
  `namespaces.yaml` itself has this, since `kubernetes/namespaces` is what
  actually creates the target namespaces; the others just need Argo CD to
  not fail if theirs doesn't exist yet on first sync. (In practice
  `namespaces.yaml` also has no ordering guarantee ahead of the others — see
  [Ordering](#ordering-within-an-application) below for why that's fine.)

## Per-Application notes

### `namespaces.yaml`

Points at `kubernetes/namespaces`, a Kustomization with no `namespace:`
field and four flat `Namespace` manifests (`etl`, `kafka`, `clickhouse`,
`monitoring`) as resources. Its own `destination.namespace` is set to
`argocd` — not because anything is deployed there, but because `Namespace`
objects are cluster-scoped and Argo CD still requires *some* value in that
field. `bootstrap/project.yaml`'s comment on the `argocd` destination entry
says the same thing.

### `producer.yaml`, `consumer.yaml`, `health-server.yaml`

All three point at `overlays/dev`, not `overlays/staging` or
`overlays/prod` — this repo currently deploys the dev overlay only, even
though staging/prod overlays are written and dry-run verified. There's no
staging/prod `Application` yet; promoting to another environment today would
mean adding e.g. `producer-staging.yaml` alongside `producer.yaml` (naming
not yet decided — see [Status](#status)).

All three share `destination.namespace: etl`.

### `kafka.yaml`, `clickhouse.yaml`

Point at `kubernetes/kafka/base` and `kubernetes/clickhouse/base` — `base/`
only, no dev/staging/prod split, since both are single-node and the same
everywhere they'd ever run on AWS (see [key design
decisions](../kubernetes/README.md#key-design-decisions) for why). Each has
exactly one sibling overlay, `overlays/local`, which exists purely for the
kind-only image tag override (both services' images are Kustomize `images:`
placeholders rewritten by CI, same as producer/consumer/health-server's
`app` image — see [`argocd/applications/local/`](#argocdapplicationslocal)
below), not for any AWS-facing environment split. Each of these two
services also owns a `sync-wave: "1"` Job (`topic-job.yaml`, `schema-job.yaml`
respectively) — see [Ordering](#ordering-within-an-application).

### `monitoring.yaml`

Points at `kubernetes/monitoring`, which itself is a Kustomization
aggregating the `prometheus/` and `grafana/` subdirectories.
`destination.namespace: monitoring`.

### `ingress.yaml`

Points at `kubernetes/ingress/base` (just `grafana-ingress.yaml`; the
`overlays/local` sibling swaps in ingress-nginx for kind — see
[`argocd/applications/local/`](#argocdapplicationslocal) below).
`destination.namespace: monitoring` — the same namespace as `monitoring.yaml`,
since the `Ingress` object routes to the Grafana `Service`, which lives
there. Depends on `ingressClassName: alb`, served by the
`aws-load-balancer-controller` Application below — if that controller isn't
running, this `Ingress` is accepted by the API server but never gets an ALB
provisioned for it.

### `aws-load-balancer-controller.yaml`

The one Application in this repo not sourced from `kubernetes/` in this
repo at all — `source.chart` pulls `aws-load-balancer-controller` directly
from AWS's `eks-charts` Helm repo. `destination.namespace: kube-system`,
matching where the chart's own defaults expect to run (it manages
cluster-scoped webhooks and a CRD, not namespace-scoped workload). Two Helm
values are placeholders until the EKS cluster actually exists:
`<CLUSTER_NAME>` and `<ALB_CONTROLLER_ROLE_ARN>`, both filled in from
`terraform output` in `nyc-taxi`'s `modules/eks`. See
`docs/bootstrap/README.md#status`.

Mixing a Helm source alongside eight Kustomize sources in the same
`argocd/applications/` directory is intentional, not an inconsistency — Argo
CD Applications are source-type-agnostic per-object, so there's no need for
every Application to agree on Kustomize vs Helm.

## Ordering within an Application

Argo CD applies all resources within a single `Application` in one sync, not
strictly in manifest order — except where `argocd.argoproj.io/sync-wave` says
otherwise. Two places in this repo use it:

- `kubernetes/kafka/topic-job.yaml` — `sync-wave: "1"`, so the topic-creation
  `Job` applies after the `kafka` `StatefulSet`/`Service`/`ConfigMap` (wave
  `0`, the default), giving Kafka a chance to come up before
  `kafka-topics.sh` tries to talk to it.
- `kubernetes/clickhouse/schema-job.yaml` — same pattern: the schema-apply
  `Job` waits for the ClickHouse `StatefulSet` to sync first.

Both Jobs also carry `argocd.argoproj.io/sync-options: Replace=true`, since
`Job` pod templates are immutable — a normal `kubectl apply` on a changed Job
spec fails, so Argo CD is told to delete-and-recreate instead.

There is **no** cross-Application ordering (e.g. nothing forces `kafka.yaml`
to sync before `consumer.yaml`, even though the consumer depends on Kafka
being reachable). Argo CD's `selfHeal` means a consumer Pod that starts
before Kafka exists will just crash-loop until Kafka comes up, then recover
on its own — acceptable for this project's scale, but worth knowing if a
sync ever looks "stuck": check Pod status, not Application sync status, when
diagnosing a startup-ordering issue.

## Verifying without a cluster

Same limitation as `bootstrap/`: applying an `Application` object for real
requires a live cluster with Argo CD's CRDs installed. What's checkable
offline is that each `source.path` actually renders, since the paths are
known and few:

```bash
kubectl kustomize kubernetes/namespaces
kubectl kustomize kubernetes/producer/overlays/dev
kubectl kustomize kubernetes/consumer/overlays/dev
kubectl kustomize kubernetes/health-server/overlays/dev
kubectl kustomize kubernetes/kafka/base
kubectl kustomize kubernetes/clickhouse/base
kubectl kustomize kubernetes/monitoring
kubectl kustomize kubernetes/ingress/base
```

(`aws-load-balancer-controller.yaml` has no local path to render — it's a
remote Helm chart, verified only by `helm template` against the pinned
chart version, or by Argo CD itself once applied.)

## `argocd/applications/local/`

A second, parallel set of eight Applications (no
`aws-load-balancer-controller` counterpart) for bootstrapping against a kind
cluster instead of EKS — see `docs/bootstrap/README.md#local-kind`. Applied
via `bootstrap/root-application-local.yaml`, not `root-application.yaml`.

This answers the naming question the [Status](#status) section used to leave
open ("a separate `argocd/applications/staging/` subdirectory?") — a
subdirectory turned out to be the right shape, just for a *local vs. cloud*
split rather than dev/staging/prod. Argo CD directory Applications are
non-recursive by default, so `path: argocd/applications` (used by
`root-application.yaml`) never sees `argocd/applications/local/`'s files, and
`path: argocd/applications/local` (used by `root-application-local.yaml`)
never sees the flat AWS-facing files one level up. The two root Applications
are meant to be applied to two different clusters, never the same one.

What differs from the AWS set:

- `producer.yaml`, `consumer.yaml`, `health-server.yaml` point at
  `overlays/local` instead of `overlays/dev` — same sizing as dev, plus an
  `images:` tag override (`app:local`) so kind uses the image loaded via
  `kind load docker-image` instead of trying to pull from a real registry.
- `kafka.yaml` points at `kubernetes/kafka/overlays/local` instead of
  `kubernetes/kafka/base` — the `StatefulSet` and topic Job both run the
  `kafka` image, another `images:` placeholder needing the same tag
  override.
- `clickhouse.yaml` points at `kubernetes/clickhouse/overlays/local` instead
  of `kubernetes/clickhouse/base`, for the same reason — the schema-apply
  Job runs the `app` image too.
- `ingress.yaml` points at `kubernetes/ingress/overlays/local`
  (`ingressClassName: nginx`, no ALB annotations) instead of
  `kubernetes/ingress/base`.
- `namespaces.yaml`, `monitoring.yaml` are identical to their AWS
  counterparts — no local-only concern for either.
- No `aws-load-balancer-controller.yaml` equivalent. ingress-nginx is
  installed by `bootstrap/install-ingress-nginx.sh` as a plain static
  manifest instead of an Argo CD Application, since it needs no IRSA/Helm
  values the way the ALB controller does.

## Status

- [x] All nine AWS-facing Applications written; all eight Kustomize-sourced
      `source.path` values (everything but the Helm-sourced
      `aws-load-balancer-controller.yaml`) render clean via
      `kubectl kustomize`.
- [x] `argocd/applications/local/` (eight Applications) written for the kind
      path, verified the same way.
- [x] `argocd/applications/local/` applied to and synced on a real kind
      cluster (via `root-application-local.yaml`), after pushing. First real
      run caught two genuine gaps, both fixed:
      1. `kafka.yaml` originally pointed at `kubernetes/kafka/base` like the
         AWS Application, but kafka's own broker image is a Kustomize
         `images:` placeholder too (`kafka:latest`) — without a local tag
         override it tried to pull from Docker Hub and failed
         (`ImagePullBackOff`). Fixed by giving kafka the same `base/` +
         `overlays/local` treatment as clickhouse.
      2. Kafka's pod also failed to start once the image pulled correctly —
         a real bug in `kubernetes/kafka/base/statefulset.yaml` unrelated to
         kind (would have broken EKS too), fixed with
         `enableServiceLinks: false`. See `docs/kubernetes/README.md#key-design-decisions`.
- [ ] Never applied to a real EKS cluster.
- [ ] `aws-load-balancer-controller.yaml`'s Helm values still have
      `<CLUSTER_NAME>` / `<ALB_CONTROLLER_ROLE_ARN>` placeholders.
- [ ] No staging/prod Applications yet — producer/consumer/health-server are
      pinned to `overlays/dev` (AWS) / `overlays/local` (kind). Decide naming
      (`producer-staging.yaml`? `argocd/applications/staging/`, mirroring the
      `local/` pattern above?) before adding a second cloud environment.
- [ ] No `ApplicationSet` — seventeen hand-written files across both sets is
      still manageable; revisit if per-environment duplication (previous
      bullet) makes that stop being true.

Keep this section current as those land — when staging/prod Applications are
added, record the naming decision actually made here, not just check the box.
