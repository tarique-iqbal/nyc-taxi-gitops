# Local Development (kind)

How to run this repo's entire GitOps loop against a disposable local
[kind](https://kind.sigs.k8s.io/) cluster instead of EKS — no AWS account,
no cost, same Argo CD reconciliation behavior. `docs/bootstrap/README.md`,
`docs/argocd/README.md`, and `docs/kubernetes/README.md` each cover their
own directory's *why*; this doc is the practical, single-place walkthrough
for actually standing the kind path up, using it day to day, and recovering
when it breaks — written from three real runs against a live kind cluster,
including the bugs those runs caught.

kind is a parallel target, not a substitute for the EKS path: neither
`argocd/applications/local/` nor any `overlays/local` directory is ever
synced by the AWS root Application (see `CLAUDE.md`), and nothing here
touches the EKS-facing files.

## Prerequisites

- Docker, running.
- `kubectl` and `kind` on `PATH`.
- A local clone of [`nyc-taxi`](https://github.com/tarique-iqbal/nyc-taxi)
  alongside this repo — the images below are built from there, not here.
  This repo (`nyc-taxi-gitops`) only holds manifests.
- This repo's changes pushed to `origin` before syncing anything — Argo CD
  reads from the git remote, not your working tree. A local edit that isn't
  pushed yet will not show up on the cluster no matter how many times you
  resync.

## Order of operations

Run these in order from this repo's root, except the two `docker build`
steps which run from `nyc-taxi`'s root.

```bash
# 1. Cluster
kind create cluster --config bootstrap/kind-config.yaml

# 2. Images (from nyc-taxi's root, not this repo)
docker build -t app:local -f deployments/docker/app/Dockerfile .
docker build -t kafka:local -f deployments/docker/kafka/Dockerfile .

# 3. Load both into the kind cluster -- kind's own Docker daemon can't see
#    your host's image cache, so a build alone isn't enough
kind load docker-image app:local --name kind
kind load docker-image kafka:local --name kind

# 4. Argo CD + ingress-nginx (from this repo's root again)
bash bootstrap/install-argocd.sh
bash bootstrap/install-ingress-nginx.sh

# 5. AppProject, then the kind root Application
kubectl apply -f bootstrap/project.yaml
kubectl apply -f bootstrap/root-application-local.yaml
```

`--name kind` matches `kind-config.yaml`'s default cluster name; pass
`--name <cluster>` consistently to both `kind create cluster` and both
`kind load docker-image` calls if you named it something else.

Step 5 must be `root-application-local.yaml`, not `root-application.yaml`
— the latter points at `argocd/applications/` (the AWS-facing set, which
references `overlays/dev` and the ALB controller) and will fail to
reconcile against a kind cluster. See
`docs/argocd/README.md#argocdapplicationslocal` for exactly what differs
between the two Application sets.

`kafka` and `clickhouse` have no `overlays/dev`/`staging`/`prod` split (see
`docs/kubernetes/README.md#key-design-decisions` — both are single-node
everywhere), so their `overlays/local` layers directly on `../../base`
rather than on a `dev` sibling the way producer/consumer/health-server's
does.

## Verifying it worked

```bash
kubectl -n argocd get application nyc-taxi-root-local
kubectl get applications -n argocd   # every child Application should be Synced + Healthy
kubectl get pods -A
```

Then confirm the pipeline actually ran end to end:

```bash
kubectl -n etl logs job/producer         # should show batches published, then exit 0
kubectl -n etl logs deploy/consumer      # should show batches persisted to ClickHouse
```

Grafana is reachable at `http://localhost/` — `kind-config.yaml` maps the
kind node's container ports 80/443 to the host, and
`kubernetes/ingress/overlays/local` routes `/` to the `grafana` Service via
ingress-nginx (`ingressClassName: nginx`, no ALB annotations — see
`docs/kubernetes/README.md#ingress-kubernetesingress`). The dashboard should
show trip counts once the producer/consumer have both run.

## Iterating on a code change

Every rebuild-and-reload round trip (from `nyc-taxi`'s root, `app` shown —
same for `kafka` if that Dockerfile changed):

```bash
docker build -t app:local -f deployments/docker/app/Dockerfile .
kind load docker-image app:local --name kind
kubectl -n etl rollout restart deployment/consumer   # or delete the producer Job and let Argo CD's Replace=true recreate it
```

A non-`latest` tag (`local`) makes Kubernetes default to
`imagePullPolicy: IfNotPresent`, so kubelet uses the image just loaded
instead of trying to pull from a real registry — this is also exactly why
skipping the `kind load docker-image` step fails silently until a Pod
actually schedules (see [Troubleshooting](#troubleshooting) below).

## Teardown

```bash
kind delete cluster --name kind
```

Fully disposable — nothing kind-specific lives outside the cluster itself,
so there's no cleanup needed in this repo or in git.

## Troubleshooting

Three real, non-obvious failures were caught the first time this path was
run end to end against a live cluster (not hypothetical — see
`docs/argocd/README.md#status` and `docs/kubernetes/README.md#status` for
where each is also recorded against the manifest that owns the fix):

**`ImagePullBackOff` on the `kafka-0` pod.** Kafka's own broker image is a
Kustomize `images:` placeholder (`kafka:latest`) the same way `app` is —
easy to miss since only the app image looks like it needs a local build.
Without `kubernetes/kafka/overlays/local`'s tag override (and without
having run `kind load docker-image kafka:local`), kubelet tries to pull
`kafka:latest` from Docker Hub and fails, since no such public image
exists. Fix already applied in this repo (`kafka/base` + `overlays/local`);
if you see this, you skipped step 2 or 3 above for the kafka image.

**Kafka pod crashes immediately after the image pulls, with nothing useful
in `kubectl logs`.** Kubernetes auto-injects Docker-links-style env vars for
every Service in a pod's namespace; since the Service is named `kafka`,
every pod in the `kafka` namespace gets `KAFKA_PORT=tcp://<clusterIP>:9092`
injected automatically. The Confluent image's own `configure` script treats
a non-empty `KAFKA_PORT` as a fatal deprecated-input conflict and exits 1
before the JVM even starts — the log line about it scrolls past almost
instantly. Already fixed in `kubernetes/kafka/base/statefulset.yaml`
(`enableServiceLinks: false`); this was a real bug in the manifest for both
kind and EKS, just never exercised until something actually tried to boot
the cluster. If you ever rename the kafka Service, check this again — the
bug is triggered by the Service *name*, not anything kind-specific.

**Consumer pod OOMKilled (`exit 137`) roughly 30-40 seconds into a run.**
`overlays/dev`'s 128Mi memory limit isn't enough under real Kafka
throughput. `kubernetes/consumer/overlays/local` already re-patches
resources up to the `staging` tier's values (256Mi/512Mi) on top of the
image-tag override — see
`docs/kubernetes/README.md#resource-sizing-across-overlays`. If you still
see this, check that Argo CD actually synced the patched Deployment
(`kubectl -n etl get deploy consumer -o jsonpath='{.spec.template.spec.containers[0].resources}'`)
rather than an older Application definition.

**Argo CD Application stuck `Unknown` / "app path does not exist".** This
repo's changes weren't pushed to `origin` yet — see
[Prerequisites](#prerequisites). Push, then
`argocd app sync nyc-taxi-root-local` (or wait for the next automated poll).

**`kubectl apply --server-side` errors on the Argo CD CRDs.** Shouldn't
happen — `install-argocd.sh` already uses `--server-side --force-conflicts`
specifically because a plain `apply`'s `last-applied-configuration`
annotation is too small for `applicationsets.argoproj.io`'s schema. If it
still fails, you're likely running a modified copy of the script; diff it
against this repo's `bootstrap/install-argocd.sh`.

## Verifying without a cluster

Every kind-facing Kustomize path renders offline, no live cluster needed:

```bash
kubectl kustomize kubernetes/producer/overlays/local
kubectl kustomize kubernetes/consumer/overlays/local
kubectl kustomize kubernetes/health-server/overlays/local
kubectl kustomize kubernetes/kafka/overlays/local
kubectl kustomize kubernetes/clickhouse/overlays/local
kubectl kustomize kubernetes/ingress/overlays/local
```

`bootstrap/kind-config.yaml`, `bootstrap/root-application-local.yaml`, and
`argocd/applications/local/*.yaml` are plain YAML with no Kustomize
transform to verify — `kubectl apply --dry-run=client -f <file>` catches a
schema mistake given any reachable API server (does not need to be the kind
cluster itself).

## Status

- [x] Full path (cluster → images → Argo CD → ingress-nginx → project →
      root Application) run end to end against a real kind cluster:
      producer published, consumer persisted to ClickHouse, Grafana showed
      the result at `http://localhost/`.
- [x] All three bugs above found by that run, fixed, and reflected in the
      manifests this doc points at.
- [ ] No scripted teardown/reset beyond `kind delete cluster` — fine today,
      revisit only if the loop above gets tedious enough to script.
