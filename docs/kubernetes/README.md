# Kubernetes Manifests

What's under `kubernetes/` — the actual workload manifests Argo CD applies.
`docs/argocd/README.md` covers *which* Application points at *which* path
here; this doc covers what's *inside* those paths: what each service looks
like, why it's shaped the way it is, and how the pieces talk to each other
over in-cluster DNS.

This covers what's here today. It's expected to grow — see
[Status](#status) at the bottom.

## Layout

```
kubernetes/
├── namespaces/       # etl, kafka, clickhouse, monitoring — flat, no base/overlays
├── producer/         # base + overlays/{dev,staging,prod,local}
├── consumer/         # base + overlays/{dev,staging,prod,local}
├── health-server/    # base + overlays/{dev,staging,prod,local}
├── kafka/            # base + overlays/local — see below
├── clickhouse/       # base + overlays/local — see below
├── monitoring/       # flat — prometheus/ + grafana/ subdirectories
└── ingress/          # base + overlays/local — see below
```

Three services (`producer`, `consumer`, `health-server`) get the
base/overlays treatment because they're where replica count and sizing
actually differ per environment. `monitoring` is flat because it's
single-instance infrastructure — nothing about it should differ between
dev/staging/prod at this project's scale. `kafka`, `clickhouse`, and
`ingress` are *mostly* flat the same way (single-node, same everywhere
they'd run on AWS — see [Key design decisions](#key-design-decisions) for
the fuller rationale on single-node Kafka specifically), but each grew one
`overlays/local` for a kind-only concern (an image tag override for `kafka`
and `clickhouse`, an ingress-class swap for `ingress`) — see their sections
under [Service inventory](#service-inventory) and `CLAUDE.md`'s "Local
development (kind)".

## Namespaces

`kubernetes/namespaces/` — four flat `Namespace` manifests
(`etl.yaml`, `kafka.yaml`, `clickhouse.yaml`, `monitoring.yaml`), one
Kustomization aggregating them, no `namespace:` field of its own (a
`Namespace` object can't be namespaced). Mapping:

| Namespace    | What lives there                                  |
|--------------|-----------------------------------------------------|
| `etl`        | producer (Job), consumer, health-server             |
| `kafka`      | kafka (StatefulSet), topic-creation Job              |
| `clickhouse` | clickhouse (StatefulSet), schema-apply Job           |
| `monitoring` | prometheus, grafana, the Grafana Ingress             |

There's no `argocd` namespace manifest here — that one is created by
`bootstrap/install-argocd.sh`, not reconciled from this directory (see
`docs/bootstrap/README.md`).

## Environment overlays: dev / staging / prod / local

Applies to `producer`, `consumer`, `health-server` only. Convention (stated
in `CLAUDE.md`): overlays patch **replica count and resource
requests/limits only** — shared spec, probes, ports, command, env stay in
`base/`. Concretely, an overlay's `kustomization.yaml` does at most two
things: a top-level `replicas:` entry, and a JSON 6902 `patches:` block
replacing `.../containers/0/resources` wholesale (never a partial merge —
each overlay states the full requests/limits block so there's no ambiguity
about what "inherited from base" means).

`overlays/local` layers on top of `overlays/dev` (`resources: [../dev]`, not
`../../base`) and adds an `images:` tag override to `local` — a kind-only
concern (see `CLAUDE.md`'s "Local development (kind)"), not a precedent for
overlays patching other fields. For producer and health-server that's all it
does, inheriting dev's sizing unchanged. `consumer`'s `overlays/local` also
re-patches `resources` on top, bumping memory to 256Mi/512Mi (dev's
128Mi/256Mi OOMKilled it under real throughput the first time this was
actually run — exit 137, ~30-40s in). That's a real resources-only patch, so
it doesn't violate the "overlays patch replica count and resources only"
rule — it's just a second one, stacked after the tag override.

`overlays/dev` is wired to the AWS-facing Applications, `overlays/local` to
the kind-facing ones under `argocd/applications/local/` — see
`docs/argocd/README.md#produceryaml-consumeryaml-health-serveryaml`.
`staging`/`prod` exist and are dry-run verified but nothing deploys them
yet.

### Resource sizing across overlays

| Service | Overlay | CPU req/limit | Mem req/limit | Replicas |
|---|---|---|---|---|
| producer | dev | 100m / 500m | 128Mi / 256Mi | n/a (Job) |
| producer | staging | 250m / 1000m | 256Mi / 512Mi | n/a (Job) |
| producer | prod | 500m / 2000m | 512Mi / 1Gi | n/a (Job) |
| producer | local | *(same as dev)* | *(same as dev)* | n/a (Job) |
| consumer | dev | 100m / 500m | 128Mi / 256Mi | 1 |
| consumer | staging | 250m / 1000m | 256Mi / 512Mi | 2 |
| consumer | prod | 500m / 2000m | 512Mi / 1Gi | 4 |
| consumer | local | 250m / 1000m | 256Mi / 512Mi | 1 |
| health-server | dev | 100m / 500m | 128Mi / 256Mi *(base default)* | HPA 1–3 |
| health-server | staging | 100m / 500m | 128Mi / 256Mi | HPA 1–2 |
| health-server | prod | 200m / 1000m | 256Mi / 512Mi | HPA 2–4 |
| health-server | local | *(same as dev)* | *(same as dev)* | HPA 1–3 |

Consumer's `local` row is not "same as dev" like the other two — dev's
128Mi/256Mi limit OOMKilled it under real throughput (exit 137) the first
time this was actually run against kind, so `overlays/local` re-patches
resources on top of the tag override, up to the `staging` tier's values.
See [Environment overlays](#environment-overlays-dev--staging--prod--local)
above.

Consumer's prod replica count (4) is not an arbitrary "prod is bigger"
choice — it matches `nyc-taxi-trips`' partition count in `kafka-topics.sh`.
One consumer per partition is the ceiling for useful parallelism; the
`overlays/prod/kustomization.yaml` comment is explicit that an HPA must
**not** be added here, since a mid-run scale event triggers a Kafka
consumer-group rebalance and stalls consumption (`scaling_notes.md` has the
full argument). `health-server` is the opposite case — it's a stateless
HTTP endpoint with no rebalance risk, so it's the one service in this repo
with an `HorizontalPodAutoscaler` (CPU target 70%, patched per overlay).

## Key design decisions

The reasoning behind the shape of the manifests, gathered in one place
rather than scattered across each service's section:

- **Producer is a `Job`, not a `Deployment`.** `producer.py` reads the
  Parquet file to EOF and exits — there's no long-running process for a
  Deployment to keep alive, and a Deployment would just restart it forever
  on a loop that was never meant to loop.
- **No HPA on consumer; replicas are set explicitly per overlay instead.**
  Consumer count is locked to `nyc-taxi-trips`' Kafka partition count (one
  consumer per partition is the ceiling for useful parallelism). An HPA
  here would risk scaling mid-run, which triggers a Kafka consumer-group
  rebalance and stalls consumption — see `scaling_notes.md` for the full
  argument. `health-server` has no such constraint (stateless HTTP, no
  Kafka group membership), so it's the one service that *does* get an HPA.
- **Overlays patch replica count and resource requests/limits only.**
  Shared spec, probes, ports, command, and env stay in `base/` — an overlay
  should never need to know what command a container runs, only how big it
  should be and how many of it there should be.
- **Kafka is single-node KRaft, not a multi-broker quorum.**
  `kafka-topics.sh` creates every topic with `replication-factor 1`, so a
  multi-broker quorum would add operational complexity (leader election,
  quorum voters, more StatefulSet replicas) without adding any durability
  this pipeline actually uses. The KRaft node-ID-from-pod-ordinal wrapper in
  `statefulset.yaml` is still written to generalize to multiple brokers
  later, even though nothing today exercises that path.
- **Kafka's StatefulSet sets `enableServiceLinks: false`.** Kubernetes
  auto-injects Docker-links-style env vars for every Service in a pod's
  namespace; because the Service here is named `kafka`, that includes
  `KAFKA_PORT=tcp://<clusterIP>:9092`, which the Confluent image's own
  startup script treats as a fatal deprecated-input conflict and refuses to
  start over. Caught during the first real run against kind — this bug was
  latent in the manifest for both AWS and kind the whole time, just never
  exercised until something actually tried to boot the cluster.
- **ClickHouse is single-node, no cluster/replication.** Same reasoning as
  Kafka — one StatefulSet replica is sufficient for this pipeline's scale,
  and adding ClickHouse Keeper/replication would be complexity with no
  present payoff.
- **Prometheus and Grafana use stock images, provisioned entirely via
  ConfigMaps** (scrape config, datasources, dashboard provider, dashboard
  JSON) rather than custom-built images baking that content in. Keeps the
  monitoring stack on upstream `prom/prometheus` and `grafana/grafana`
  releases directly, with no image-build step of its own to maintain.
- **ClickHouse's `config.xml`/`users.xml` are ConfigMap-mounted, not
  baked into the image either** — same rationale, and it reuses the exact
  file contents from `nyc-taxi`'s `deployments/docker/clickhouse/config/`
  rather than duplicating them in a Dockerfile `COPY`.
- **Only `overlays/dev` and `overlays/local` are wired to an Argo CD
  Application today**, for the AWS and kind paths respectively.
  `staging`/`prod` overlays exist and are dry-run verified, but promoting to
  either is a deliberate next step (a new Application per environment), not
  something that happens automatically — see `docs/argocd/README.md`.

## Service inventory

### producer (`kubernetes/producer/`)

A `batch/v1` **Job**, not a Deployment — `producer.py` reads the Parquet
file to EOF and exits; there's no long-running process to keep alive, so a
Deployment (which would just restart it forever) is the wrong primitive.

- `initContainer download-data` (`curlimages/curl:8.11.0`) pulls
  `yellow_tripdata_2024-01.parquet` from CloudFront into an `emptyDir`
  mounted at `/data`, shared with the main container. Keeps the app image
  free of a baked-in data file.
- Main container: `python -m etl.entrypoints.producer`, env from the
  `producer` ConfigMap (Kafka bootstrap/topic/DLQ/batching settings) plus
  two path env vars pointing at the initContainer's `emptyDir`.
  `metrics` port `9100`, no Service in front of it — nothing scrapes a Job
  continuously (see the Prometheus config note below).
- `argocd.argoproj.io/sync-options: Replace=true` — Job pod templates are
  immutable, so a plain `kubectl apply` after an image-tag bump fails; this
  tells Argo CD to `kubectl replace` (delete+recreate) instead. The same
  annotation appears on every Job in this repo (`kafka-topics`,
  `schema-apply`).
- No Service, Secret, or HPA — no HTTP server to expose, no ClickHouse
  credentials needed (producer only talks to Kafka), and autoscaling a
  one-shot Job makes no sense.

### consumer (`kubernetes/consumer/`)

A `Deployment`, `replicas: 1` in base (overlays override). Pulls from
Kafka, writes to ClickHouse — env from the `consumer` ConfigMap
(bootstrap servers, topic, consumer group, ClickHouse host/port/db/user,
async-insert settings) plus a `consumer` Secret for `CLICKHOUSE_PASSWORD`.
`metrics` port `9101`, exposed via a `ClusterIP` Service and scraped both by
Prometheus's static config and by pod-level `prometheus.io/scrape`
annotations (belt-and-suspenders — the Prometheus job actually used is the
static one; the annotations are there for tooling that discovers targets
that way instead). `startupProbe`/`livenessProbe`/`readinessProbe` all hit
`GET /metrics` on the `metrics` port — there's no separate health endpoint,
so "the metrics server answers" is standing in for "the process is alive."

### health-server (`kubernetes/health-server/`)

A `Deployment` fronting a small HTTP server (`python -m
etl.entrypoints.health_server`) on port `8000`. The one service in this
repo with distinct liveness vs. readiness checks: `livenessProbe` hits
`/ready`, `readinessProbe` hits `/health` — i.e. "is the process alive" is
answered by the readiness-style endpoint and "is it ready to serve" by the
health-style one, which reads backwards from typical naming. This mirrors
`health_server.py`'s actual route semantics as implemented in `nyc-taxi`,
not a copy-paste mistake — worth double-checking against that source if the
routes ever change. Has the repo's only `HorizontalPodAutoscaler` (see
[above](#resource-sizing-across-overlays)).

### kafka (`kubernetes/kafka/`)

Single-node **KRaft** (`KAFKA_PROCESS_ROLES: "broker,controller"` — no
ZooKeeper, and no separate controller-only node). This is a cluster-only
deviation: `docker-compose.yml` in `nyc-taxi` stays ZooKeeper-based for
local dev, unaffected.

- `statefulset.yaml`: `serviceName: kafka-headless`, `replicas: 1`.
  Container command is a shell wrapper —
  `export KAFKA_NODE_ID=$((${HOSTNAME##*-} + 1)); exec /etc/confluent/docker/run`
  — deriving the KRaft node ID from the pod's ordinal suffix (`kafka-0` →
  `1`) instead of hardcoding it, so the manifest doesn't need editing if
  this is ever scaled to multiple brokers later, even though nothing today
  exercises that path. `volumeClaimTemplates`: 10Gi at
  `/var/lib/kafka/data`. Sets `enableServiceLinks: false` on the pod spec —
  without it, kubelet auto-injects a `KAFKA_PORT=tcp://<clusterIP>:9092` env
  var into the pod (legacy Docker-links behavior, triggered by the `kafka`
  Service sharing a name prefix with the app), and the Confluent image's own
  `configure` script treats a non-empty `KAFKA_PORT` as a deprecated,
  conflicting input and exits 1 immediately — a real bug, not a kind-only
  one, caught only because this repo had never actually been run against a
  live cluster before the kind path existed. See [Key design
  decisions](#key-design-decisions).
- `configmap.yaml`: `CLUSTER_ID` (fixed, generated once), controller quorum
  voters pointing at `kafka-0.kafka-headless...:9093`, advertised listener
  at the plain `kafka` Service DNS name, `KAFKA_AUTO_CREATE_TOPICS_ENABLE:
  "false"` (topics are created explicitly by the Job below, not
  implicitly on first produce), 168h log retention.
- `topic-job.yaml`: `sync-wave: "1"` so it applies after the StatefulSet
  (wave `0`, the default) reaches Healthy; runs `/opt/kafka-topics.sh`
  baked into the `kafka:latest` image, pointed at the `kafka` Service.
- Two Services: `kafka-headless` (`clusterIP: None`, gives the StatefulSet
  pod stable per-ordinal DNS — required for `controller.quorum.voters` to
  resolve) and `kafka` (normal `ClusterIP`, what every other service's
  `KAFKA_BOOTSTRAP_SERVERS` actually points at).

Everything above lives under `base/` — like `clickhouse`, `kubernetes/kafka/`
also has an `overlays/local`, overriding the `images:` transformer's tag to
`local` for both the StatefulSet and `topic-job.yaml` (both use the `kafka`
placeholder image, normally rewritten to a real registry image by CI, same
as `app` for producer/consumer/health-server/schema-apply). Missing this the
first time was a real bug caught by actually running the kind path: without
the override, kubelet tries to pull `kafka:latest` from Docker Hub and fails
— see `docs/argocd/README.md#status`.

### clickhouse (`kubernetes/clickhouse/`)

Single-node `StatefulSet`, `clickhouse/clickhouse-server:24.4`. Config is
delivered via a `ConfigMap` mounted with `subPath` into
`config.d/custom.xml` and `users.d/custom.xml` — verbatim contents of
`nyc-taxi`'s `deployments/docker/clickhouse/config/{config.xml,users.xml}`,
just delivered by ConfigMap instead of `COPY` in a Dockerfile. Three ports:
`native` (`9000`, what the consumer and Grafana's ClickHouse datasource
both use), `http` (`8123`, used for the `/ping` health checks), `metrics`
(`9363`, ClickHouse's built-in Prometheus exporter, enabled by the mounted
`config.xml`'s `<prometheus>` block). `volumeClaimTemplates`: 20Gi at
`/var/lib/clickhouse`.

`schema-job.yaml` — same `sync-wave: "1"` / `Replace=true` pattern as
Kafka's topic Job, runs `python -m etl.entrypoints.schema_apply` (the app
image, not a ClickHouse image) against `schema-apply` ConfigMap/Secret
(host/port/db/user, plus a password Secret). This is the migration
mechanism: `SchemaManager.apply_all()` from `nyc-taxi`, invoked as a
`kubectl`-native Job instead of `scripts/apply_schema.sh`'s
`docker compose exec` (which has no cluster equivalent).

Everything above lives under `base/` — `kubernetes/clickhouse/` also has an
`overlays/local`, whose only job is overriding the `images:` transformer's
tag to `local` for `schema-job.yaml`'s container (the StatefulSet's own
`clickhouse/clickhouse-server:24.4` image is untouched). See "Local
development (kind)" in `CLAUDE.md`.

### monitoring (`kubernetes/monitoring/`)

Two Deployments under one namespace-scoping Kustomization:

- **prometheus/** — `prom/prometheus:v2.52.0`, `strategy: Recreate` (not
  `RollingUpdate` — it mounts a single `ReadWriteOnce` PVC, so two Pods
  briefly co-existing during a rolling update would fail to schedule the
  new one). Scrape config (`prometheus.yml`, ConfigMap-mounted) has two
  external targets: `consumer.etl.svc.cluster.local:9101` and
  `clickhouse.clickhouse.svc.cluster.local:9363`, both cross-namespace via
  each Service's fully-qualified in-cluster DNS name. No producer scrape
  target — a one-shot Job has nothing to scrape continuously, so its
  `metrics` port on `9100` is reachable only for the duration of a run, if
  at all port-forwarded manually. `--storage.tsdb.retention.time=15d`,
  backed by a 10Gi `ReadWriteOnce` PVC (`prometheus-data`).
- **grafana/** — `grafana/grafana:10.4.2`, same `Recreate` reasoning as
  Prometheus (also a single `ReadWriteOnce` PVC). Provisioned entirely via
  ConfigMaps — datasources (Prometheus + a ClickHouse plugin datasource
  pointed at `clickhouse.clickhouse.svc.cluster.local:9000` with a
  `readonly_user`), a dashboard provider, and the dashboard JSON itself —
  no custom Grafana image — see [Key design
  decisions](#key-design-decisions) for why. Backed by a 1Gi
  `ReadWriteOnce` PVC (`grafana-data`) — small, since only Grafana's own
  SQLite state (users, sessions, dashboard edits) lives there; dashboard
  definitions themselves are ConfigMap-provisioned, not stored on disk. One
  thing worth flagging precisely: the ClickHouse datasource's `secureJsonData.password` is a
  literal value (`grafana_readonly`) sitting in a **ConfigMap**, not a
  Secret — acceptable for a portfolio/learning deployment where that
  `readonly_user` has no write access and the value isn't a real credential,
  but not a pattern to copy if this ever handles anything sensitive.

### ingress (`kubernetes/ingress/`)

`base/grafana-ingress.yaml`: `ingressClassName: alb`,
`alb.ingress.kubernetes.io/scheme: internet-facing`,
`target-type: ip`, HTTP-only on port 80 (no TLS/ACM cert wired up yet — see
[Status](#status)), no `host:` rule since no domain is provisioned, so it
matches any hostname routed to the ALB. Routes `/` straight to the
`grafana` Service on port `3000`. Depends entirely on the
`aws-load-balancer-controller` Application (see `docs/argocd/README.md`) —
without that controller running, this `Ingress` is accepted by the API
server but no ALB is ever provisioned for it.

`overlays/local` patches this for kind: `ingressClassName: nginx`, ALB
annotations replaced with an empty map, served by ingress-nginx (installed
by `bootstrap/install-ingress-nginx.sh`, not Argo-managed) instead of the
ALB controller.

## Cross-service DNS reference

Every in-cluster hostname referenced by the manifests above, gathered in
one place since chasing them individually across ConfigMaps is tedious:

| From (namespace) | To | DNS name | Port |
|---|---|---|---|
| etl (producer, consumer) | kafka | `kafka.kafka.svc.cluster.local` | 9092 |
| kafka (internal, StatefulSet only) | kafka-0 | `kafka-0.kafka-headless.kafka.svc.cluster.local` | 9093 |
| etl (consumer), clickhouse (schema-apply) | clickhouse | `clickhouse.clickhouse.svc.cluster.local` | 9000 (native), 8123 (http) |
| monitoring (prometheus) | consumer | `consumer.etl.svc.cluster.local` | 9101 |
| monitoring (prometheus) | clickhouse | `clickhouse.clickhouse.svc.cluster.local` | 9363 (metrics) |
| monitoring (grafana) | prometheus | `prometheus` *(same-namespace, short name)* | 9090 |
| monitoring (grafana) | clickhouse | `clickhouse.clickhouse.svc.cluster.local` | 9000 |
| monitoring (ingress) | grafana | `grafana` *(same-namespace, short name)* | 3000 |

Same-namespace references use the short Service name (`prometheus`,
`grafana`); cross-namespace references always use the fully-qualified
`<service>.<namespace>.svc.cluster.local` form. Consistent throughout — a
short name used cross-namespace, or a fully-qualified name used
same-namespace, is very likely a typo if one ever shows up in a diff.

## Verifying without a cluster

Every path below renders with `kubectl kustomize <path>` and passes
`kubectl apply --dry-run=client -k <path>` given any reachable API server
with no CRDs required (everything here is core/apps/batch/autoscaling
built-ins, nothing custom):

```bash
kubectl kustomize kubernetes/namespaces
kubectl kustomize kubernetes/producer/overlays/dev
kubectl kustomize kubernetes/producer/overlays/staging
kubectl kustomize kubernetes/producer/overlays/prod
kubectl kustomize kubernetes/producer/overlays/local
kubectl kustomize kubernetes/consumer/overlays/dev
kubectl kustomize kubernetes/consumer/overlays/staging
kubectl kustomize kubernetes/consumer/overlays/prod
kubectl kustomize kubernetes/consumer/overlays/local
kubectl kustomize kubernetes/health-server/overlays/dev
kubectl kustomize kubernetes/health-server/overlays/staging
kubectl kustomize kubernetes/health-server/overlays/prod
kubectl kustomize kubernetes/health-server/overlays/local
kubectl kustomize kubernetes/kafka/base
kubectl kustomize kubernetes/kafka/overlays/local
kubectl kustomize kubernetes/clickhouse/base
kubectl kustomize kubernetes/clickhouse/overlays/local
kubectl kustomize kubernetes/monitoring
kubectl kustomize kubernetes/ingress/base
kubectl kustomize kubernetes/ingress/overlays/local
```

Twenty paths total. This is the same sweep referenced in
`docs/argocd/README.md` and `docs/bootstrap/README.md` — worth turning into
a single script once there are enough of them to make typing this out by
hand annoying (see [Status](#status)).

## Status

- [x] All twenty Kustomize paths written and dry-run verified (client-side
      render; `apply --dry-run=client` itself needs a reachable API server
      for schema validation, so it's only exercised once a cluster exists).
- [x] `producer`/`consumer`/`health-server` dev/staging/prod/local overlays
      exist; `dev` is wired to the AWS Applications, `local` to the kind ones
      (`docs/argocd/README.md`).
- [x] `kubernetes/kafka/overlays/local`, `kubernetes/clickhouse/overlays/local`,
      and `kubernetes/ingress/overlays/local` written for the kind path.
      `kubectl kustomize` output for all three AWS-facing `base/` paths
      verified byte-identical to their pre-restructure flat layout.
- [ ] No TLS on the Grafana Ingress — HTTP-only, no ACM cert / `host:` rule,
      since no Route53 domain is provisioned. Revisit once one exists.
      (Doesn't apply to the kind path, which uses ingress-nginx over plain
      HTTP on `localhost` by design.)
- [ ] No verify-all script yet — the 20-command block above is run by hand.
      A `scripts/verify-kustomize.sh` (or similar) looping over every
      Kustomize path would remove the copy-paste risk of the list here
      drifting from the actual directory tree.
- [x] Applied to a real kind cluster via `argocd/applications/local/` and
      run end-to-end for real: producer published, consumer persisted to
      ClickHouse, Grafana showed the result. Along the way, caught and fixed
      the kafka image/`enableServiceLinks` bugs above plus one more: `dev`'s
      128Mi memory limit OOMKilled the consumer under actual throughput
      (`consumer/overlays/local` now patches its own sizing — see
      [Resource sizing across overlays](#resource-sizing-across-overlays)).
      Never applied to a real EKS cluster.

Keep this section current as those land — when a fourth namespace or
service is added, add it to the layout tree, the sizing table, and the DNS
reference table above, not just the Status checklist.
