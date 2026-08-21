# Bootstrap

How to take a fresh EKS cluster to a state where Argo CD is managing
everything else in this repo. Everything under `bootstrap/` is applied
**manually, once per cluster** — it is deliberately outside the GitOps loop,
because something has to exist before Argo CD can reconcile anything.

This doc covers what's in `bootstrap/` today. It's expected to grow as later
phases (Terraform, CI promotion, day-2 operations) land — see [Status](#status)
at the bottom.

## Why manual

Argo CD can only reconcile what it can already see. `bootstrap/` is the
chicken-and-egg part: installing Argo CD itself, and creating the one
`Application` (`root-application.yaml`) that lets it start watching this repo.
Once that's applied, everything else — namespaces, producer, consumer,
health-server, Kafka, ClickHouse, monitoring, ingress, the ALB controller —
is reconciled automatically from `argocd/applications/`. See the app-of-apps
pattern described in `CLAUDE.md`.

`bootstrap/project.yaml` is also applied manually and stays that way
permanently, not just for the initial bootstrap — see
[project.yaml](#projectyaml-appproject) below.

## Prerequisites

- An EKS cluster exists and `kubectl` is pointed at it (`kubectl config
  current-context` shows the right cluster). Per the standing constraint in
  `CLAUDE.md`, this repo's `kubernetes/` manifests must all be written and
  verified offline (`kubectl kustomize`, `kubectl apply --dry-run=client -k`)
  before the cluster is provisioned at all — bootstrap only starts after that.
- Just `kubectl` — no Helm needed. `install-argocd.sh` applies Argo CD's own
  release manifest directly.
- Cluster-admin access on the current context (installing CRDs, cluster
  roles, and a new namespace requires it).
- For the local (kind) path below instead: Docker and `kind` on `PATH`, in
  place of an EKS cluster.

## Order of operations

1. `./bootstrap/install-argocd.sh` — installs Argo CD into the `argocd`
   namespace.
2. `kubectl apply -f bootstrap/project.yaml` — creates the `nyc-taxi`
   `AppProject`, scoping what the Applications created in step 3 are allowed
   to touch.
3. `kubectl apply -f bootstrap/root-application.yaml` — creates the root
   `Application`. From here on, Argo CD takes over: it reads
   `argocd/applications/*.yaml` and creates/syncs every other `Application`
   itself.

`project.yaml` before `root-application.yaml` matters: the root Application
declares `spec.project: nyc-taxi`, which must already exist or the apply is
rejected.

## Local (kind)

A parallel path for smoke-testing this repo without AWS: `kind create
cluster --config bootstrap/kind-config.yaml` → build both the app and kafka
images and `kind load docker-image app:local --name <cluster>` /
`kind load docker-image kafka:local --name <cluster>` → `./bootstrap/install-argocd.sh`
→ `./bootstrap/install-ingress-nginx.sh` → `kubectl apply -f
bootstrap/project.yaml` → `kubectl apply -f
bootstrap/root-application-local.yaml` (not `root-application.yaml`). The
last step points at `argocd/applications/local/` instead of
`argocd/applications/`, which swaps out the AWS-only pieces (ALB ingress,
`aws-load-balancer-controller`) for kind-compatible ones. `project.yaml`
needs no changes for this — it's the same `AppProject` either way, since
`argocd/applications/local/` sources from the same repo.

Both image loads are easy to forget and both fail the same way if skipped —
kafka's own image is a Kustomize `images:` placeholder too, not just the
`app` one, and kubelet will happily try (and fail) to pull `kafka:local`
from Docker Hub if it was never loaded. First real run of this path caught
exactly that; see `docs/argocd/README.md#status`.

`install-ingress-nginx.sh` mirrors `install-argocd.sh`'s shape (pinned
version, context confirmation prompt, static upstream manifest) but is
kind-only: ingress-nginx has no IRSA/cloud dependency, so it doesn't need to
be an Argo CD Application the way `aws-load-balancer-controller` does — see
`docs/argocd/README.md`.

## What's in each file

### `install-argocd.sh`

Installs Argo CD itself by applying the upstream `install.yaml` for a pinned
version (`ARGOCD_VERSION`, default `v3.5.0` — pinned like every other image in
this repo, not tracking `stable`) into a namespace (`ARGOCD_NAMESPACE`,
default `argocd`). Prompts for confirmation against whatever
`kubectl config current-context` currently points at, since applying this to
the wrong cluster is exactly the kind of mistake that's easy to make and hard
to undo. Waits for `argocd-server` to become available, then prints the
generated initial admin password and the port-forward command needed to reach
the UI (`argocd-server` has no `Ingress`/`LoadBalancer` of its own — access is
via port-forward or a future addition, not yet scaffolded).

Applies with `kubectl apply --server-side --force-conflicts`, not a plain
`apply` — confirmed necessary the first time this was run for real: a normal
`apply` computes a `last-applied-configuration` annotation from the full
manifest, and `applicationsets.argoproj.io`'s CRD schema alone is large
enough to blow past the API server's 256KiB annotation limit
(`metadata.annotations: Too long`). Server-side apply tracks changes via
managed fields instead of that annotation, so it doesn't hit the limit.

Both `ARGOCD_NAMESPACE` and `ARGOCD_VERSION` are overridable env vars, so a
second cluster (e.g. a throwaway one for testing this doc) doesn't require
editing the script.

### `project.yaml` (AppProject)

Scopes what every `Application` under `argocd/applications/` is permitted to
do — narrower than Argo CD's built-in `default` project, which would allow
any repo, any destination, any resource kind. Three things it restricts:

- **`sourceRepos`** — only this repo's git URL and the AWS `eks-charts` Helm
  repo (needed for `aws-load-balancer-controller.yaml`, the one Application
  sourced from a Helm chart instead of a Kustomize path).
- **`destinations`** — only the six namespaces this project actually deploys
  into (`etl`, `kafka`, `clickhouse`, `monitoring`, `kube-system`, plus
  `argocd` itself for the `namespaces` Application's cluster-scoped
  `Namespace` objects).
- **`clusterResourceWhitelist`** — cluster-scoped kinds are denied by default
  in a scoped AppProject; this whitelists exactly the ones needed
  (`Namespace`, plus the ClusterRole/ClusterRoleBinding/webhook/CRD/
  IngressClass kinds the `aws-load-balancer-controller` chart installs).

This is why `project.yaml` is **not** watched by the root Application, unlike
everything else in this repo: scope/RBAC is a deliberate, reviewed action,
not something that should self-heal from a git push the way workload
manifests do. Changing it always means a conscious `kubectl apply
-f bootstrap/project.yaml`.

### `root-application.yaml`

The single Application that makes this an app-of-apps setup. Its `source`
points at the `argocd/applications` directory (not a Kustomize path — just a
directory of plain `Application` manifests), so Argo CD treats every file in
there as a resource to create and manage. `syncPolicy.automated: {prune:
true, selfHeal: true}` means adding a new file under `argocd/applications/`
and pushing it is the entire workflow for onboarding a new service — no
second manual `kubectl apply` needed once this root Application exists.

`finalizers: [resources-finalizer.argocd.argoproj.io]` ensures that deleting
this Application also cascades to delete everything it manages, rather than
orphaning the child Applications (and their resources) on the cluster.

## Verifying without a cluster

None of this can be dry-run in the way `kubectl kustomize` verifies
`kubernetes/`, since `install-argocd.sh` and the two `kubectl apply -f`
steps genuinely require a live API server. What *can* be checked offline:

```bash
# YAML is well-formed and matches the AppProject/Application CRD shape
kubectl apply --dry-run=client -f bootstrap/project.yaml
kubectl apply --dry-run=client -f bootstrap/root-application.yaml
```

These will fail with a connection error if no cluster is reachable at all
(expected, pre-EKS) but will still catch YAML/schema mistakes if run against
any reachable cluster with the Argo CD CRDs installed (e.g. a scratch kind
cluster).

## Status

- [x] `install-argocd.sh`, `project.yaml`, `root-application.yaml` written
      and reviewed.
- [x] `kind-config.yaml`, `install-ingress-nginx.sh`,
      `root-application-local.yaml` written for the local (kind) path.
- [x] All Kustomize paths under `kubernetes/` render and dry-run clean —
      the precondition for actually running bootstrap.
- [x] `install-argocd.sh` and `install-ingress-nginx.sh` run for real against
      a kind cluster — both succeeded (after the `--server-side` fix above).
      `project.yaml` applied cleanly too.
- [ ] `root-application-local.yaml` applied but not yet synced — Argo CD
      reads from the `origin` git remote, not the working tree, so it stays
      `Unknown`/errors with "app path does not exist" until this repo's kind
      work is actually pushed. Not a bootstrap defect, just sequencing.
- [ ] Never run against a real EKS cluster. Per `CLAUDE.md`'s standing
      constraint, `terraform apply` (EKS) hasn't happened yet.
- [ ] `<CLUSTER_NAME>` / `<ALB_CONTROLLER_ROLE_ARN>` placeholders in
      `argocd/applications/aws-load-balancer-controller.yaml` still need
      real values from `terraform output` once the EKS cluster exists.

This section should be kept current as those steps actually happen — once
the cluster is provisioned and bootstrap has been run for real, add a short
"first real run" note here (what version was installed, any deviation from
the steps above) rather than just flipping checkboxes silently.
