# NYC Taxi ETL GitOps

Kubernetes manifests for the [`nyc-taxi`](https://github.com/tarique-iqbal/nyc-taxi) streaming ETL pipeline, deployed via Argo CD's app-of-apps pattern. Two deployment targets, both reconciled from this same repo: EKS (the real target) and a local [kind](https://kind.sigs.k8s.io/) cluster (for smoke-testing without AWS) — see [Bootstrap](#bootstrap-one-time-per-cluster) below for both.

For EKS, a single root `Application` (`bootstrap/root-application.yaml`) watches `argocd/applications/`, which holds one `Application` manifest per service (namespaces, producer, consumer, health-server, Kafka, ClickHouse, monitoring, ingress, plus the Helm-sourced `aws-load-balancer-controller`). For kind, a second root `Application` (`bootstrap/root-application-local.yaml`) watches `argocd/applications/local/` instead — the same services minus the AWS-only controller, pointed at kind-compatible paths where one exists. Producer/consumer/health-server point at `kubernetes/<service>/overlays/<env>`; kafka, clickhouse, and ingress point at `kubernetes/<service>/base` (each with one `overlays/local` for the kind-only bits); the rest (namespaces, monitoring) have no overlays at all and point straight at `kubernetes/<service>`. Every Application runs with `automated: {prune: true, selfHeal: true}`, so each cluster continuously converges on whatever is committed here.

`nyc-taxi`'s CI (`release.yml`) never touches the cluster directly — it builds/pushes images to ECR, then promotes a release by bumping the image tag in the affected service's base `kustomization.yaml` here and pushing a commit. Argo CD detects the commit and reconciles.

See [`nyc-taxi/docs/deployment.md`](https://github.com/tarique-iqbal/nyc-taxi/blob/main/docs/deployment.md) for the full repo-split rationale and [`nyc-taxi/docs/scaling_notes.md`](https://github.com/tarique-iqbal/nyc-taxi/blob/main/docs/scaling_notes.md) for why this targets self-hosted Kafka + ClickHouse on EKS rather than MSK + ClickHouse-on-EC2.

## Layout

```
nyc-taxi-gitops/
├── bootstrap/            # one-time: install Argo CD, AppProject, root app-of-apps
│                         # (root-application.yaml for EKS, root-application-local.yaml
│                         # for kind), plus kind-config.yaml / install-ingress-nginx.sh
├── argocd/
│   └── applications/     # one Argo CD Application per service
│       └── local/        # kind counterpart, applied instead of (not alongside) the above
└── kubernetes/
    ├── namespaces/       # etl, kafka, clickhouse, monitoring
    ├── producer/         # base + overlays/{dev,staging,prod,local}
    ├── consumer/         # base + overlays/{dev,staging,prod,local} -- no HPA (see scaling_notes.md)
    ├── health-server/    # base + overlays/{dev,staging,prod,local}
    ├── kafka/            # KRaft StatefulSet + topic-creation Job; base + overlays/local
    ├── clickhouse/       # StatefulSet + schema-apply Job; base + overlays/local
    ├── monitoring/       # Prometheus + Grafana (ConfigMap-provisioned dashboards)
    └── ingress/          # Grafana Ingress; base (AWS ALB) + overlays/local (ingress-nginx)
```

Full reference docs, one per top-level directory: [`docs/bootstrap/README.md`](docs/bootstrap/README.md), [`docs/argocd/README.md`](docs/argocd/README.md), [`docs/kubernetes/README.md`](docs/kubernetes/README.md). This top-level README is the quick-start; those cover the *why* behind each manifest.

## Bootstrap (one-time, per cluster)

### EKS

```bash
bash bootstrap/install-argocd.sh
kubectl apply -f bootstrap/project.yaml
kubectl apply -f bootstrap/root-application.yaml
```

### Local (kind)

```bash
kind create cluster --config bootstrap/kind-config.yaml
# build the app and kafka images in nyc-taxi (deployments/docker/{app,kafka}/Dockerfile), then:
kind load docker-image app:local --name <cluster>
kind load docker-image kafka:local --name <cluster>
bash bootstrap/install-argocd.sh
bash bootstrap/install-ingress-nginx.sh
kubectl apply -f bootstrap/project.yaml
kubectl apply -f bootstrap/root-application-local.yaml
```

Grafana is then reachable at `http://localhost/` (`kind-config.yaml` maps container ports 80/443 to the host). Full detail on what differs from EKS: `docs/bootstrap/README.md#local-kind`.

After either bootstrap, everything under `argocd/` and `kubernetes/` is reconciled
automatically by the root app-of-apps — no further `kubectl apply` needed
for day-to-day changes.
