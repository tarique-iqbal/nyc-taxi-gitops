# NYC Taxi ETL GitOps

Kubernetes manifests for the [`nyc-taxi`](https://github.com/tarique-iqbal/nyc-taxi) streaming ETL pipeline, deployed via Argo CD's app-of-apps pattern: a single root `Application` (`bootstrap/root-application.yaml`) watches `argocd/`, which holds one `Application` manifest per service (producer, consumer, health-server, Kafka, ClickHouse, monitoring), each pointing at its own `kubernetes/<service>/overlays/<env>` Kustomize path. Every Application runs with `automated: {prune: true, selfHeal: true}`, so the cluster continuously converges on whatever is committed here.

`nyc-taxi`'s CI (`release.yml`) never touches the cluster directly — it builds/pushes images to ECR, then promotes a release by bumping the image tag in this repo's Kustomize overlays and pushing a commit. Argo CD detects the commit and reconciles.

See [`nyc-taxi/docs/deployment.md`](https://github.com/tarique-iqbal/nyc-taxi/blob/main/docs/deployment.md) for the full repo-split rationale and [`nyc-taxi/docs/scaling_notes.md`](https://github.com/tarique-iqbal/nyc-taxi/blob/main/docs/scaling_notes.md) for why this targets self-hosted Kafka + ClickHouse on EKS rather than MSK + ClickHouse-on-EC2.

## Layout

```
.
├── bootstrap/          # one-time: install Argo CD, AppProject, root app-of-apps
├── argocd/             # one Argo CD Application per service
└── kubernetes/
    ├── namespaces/     # etl, kafka, clickhouse, monitoring
    ├── producer/       # base + overlays/{dev,staging,prod}
    ├── consumer/       # base + overlays/{dev,staging,prod} -- no HPA (see scaling_notes.md)
    ├── health-server/  # base + overlays/{dev,staging,prod}
    ├── kafka/          # KRaft StatefulSet + topic-creation Job
    ├── clickhouse/     # StatefulSet + schema-apply Job
    ├── monitoring/     # Prometheus + Grafana (ConfigMap-provisioned dashboards)
    └── ingress/
```

## Bootstrap (one-time, per cluster)

```bash
bash bootstrap/install-argocd.sh
kubectl apply -f bootstrap/project.yaml
kubectl apply -f bootstrap/root-application.yaml
```

After that, everything under `argocd/` and `kubernetes/` is reconciled
automatically by the root app-of-apps -- no further `kubectl apply` needed
for day-to-day changes.
