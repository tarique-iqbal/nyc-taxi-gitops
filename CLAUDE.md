# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

GitOps manifests for the [`nyc-taxi`](https://github.com/tarique-iqbal/nyc-taxi) streaming ETL pipeline, deployed via Argo CD's app-of-apps pattern on EKS. `nyc-taxi`'s CI builds/pushes images and bumps tags here; Argo CD reconciles the cluster from whatever is committed. Full rationale: `nyc-taxi/docs/deployment.md` and `nyc-taxi/docs/scaling_notes.md`.

## Layout

```
.
├── bootstrap/            # one-time, applied manually: install-argocd.sh, project.yaml (AppProject), root-application.yaml
├── argocd/applications/  # one Argo CD Application per service, named without an "-application" suffix
└── kubernetes/
    ├── namespaces/       # etl, kafka, clickhouse, monitoring
    ├── producer/         # runs as a Job -- one-shot, exits once the Parquet file is ingested; base + overlays/{dev,staging,prod}
    ├── consumer/         # base + overlays/{dev,staging,prod} -- no HPA (see scaling_notes.md)
    ├── health-server/    # base + overlays/{dev,staging,prod}
    ├── kafka/            # KRaft StatefulSet + topic-creation Job
    ├── clickhouse/       # StatefulSet + schema-apply Job
    ├── monitoring/       # Prometheus + Grafana (ConfigMap-provisioned dashboards)
    └── ingress/          # Grafana Ingress (AWS ALB)
```

## Conventions

- Every `Application` in `argocd/applications/` sets `syncPolicy.automated: {prune: true, selfHeal: true}`   and points at a `kubernetes/<service>` (or `.../overlays/<env>`) Kustomize path.
- `bootstrap/project.yaml` (the `AppProject`) is applied manually and is **not** watched by the   root Application — scope/RBAC changes there require a deliberate `kubectl apply`, not an
  automatic sync.
- Overlays patch replica count and resource requests/limits only; shared spec/probes/ports stay   in `base/`.
- Verify offline before touching a cluster: `kubectl kustomize <path>` to render,   `kubectl apply --dry-run=client -k <path>` to validate. No live cluster required for either.
- `kubernetes/ingress/grafana-ingress.yaml` uses `ingressClassName: alb`, but `nyc-taxi`'s
  Terraform doesn't yet install the AWS Load Balancer Controller (only the subnet tags for
  it exist in `modules/networking`) -- the Ingress won't get an address until that's added.

## Standing constraint

Do not run `terraform apply` (EKS) or the Argo CD bootstrap (`bootstrap/install-argocd.sh`, applying `project.yaml`/`root-application.yaml`) until every manifest under `kubernetes/` is written and verified via the dry-run commands above. YAML can be authored and verified entirely offline; EKS is provisioned last since standing up the cluster starts incurring AWS charges.
