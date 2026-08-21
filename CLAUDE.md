# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

GitOps manifests for the [`nyc-taxi`](https://github.com/tarique-iqbal/nyc-taxi) streaming ETL pipeline, deployed via Argo CD's app-of-apps pattern on EKS. `nyc-taxi`'s CI builds/pushes images and bumps tags here; Argo CD reconciles the cluster from whatever is committed. Full rationale: `nyc-taxi/docs/deployment.md` and `nyc-taxi/docs/scaling_notes.md`.

## Layout

```
.
├── bootstrap/            # one-time, applied manually: install-argocd.sh, project.yaml (AppProject),
│                         # root-application.yaml (AWS) / root-application-local.yaml (kind), kind-config.yaml,
│                         # install-ingress-nginx.sh
├── argocd/applications/  # one Argo CD Application per service, named without an "-application" suffix
│   └── local/            # kind counterpart: same services, minus aws-load-balancer-controller, pointed at
│                         # overlays/local where one exists (see root-application-local.yaml)
└── kubernetes/
    ├── namespaces/       # etl, kafka, clickhouse, monitoring
    ├── producer/         # runs as a Job -- one-shot, exits once the Parquet file is ingested; base + overlays/{dev,staging,prod,local}
    ├── consumer/         # base + overlays/{dev,staging,prod,local} -- no HPA (see scaling_notes.md)
    ├── health-server/    # base + overlays/{dev,staging,prod,local}
    ├── kafka/            # KRaft StatefulSet + topic-creation Job; base + overlays/local
    ├── clickhouse/       # StatefulSet + schema-apply Job; base + overlays/local
    ├── monitoring/       # Prometheus + Grafana (ConfigMap-provisioned dashboards)
    └── ingress/          # Grafana Ingress; base (AWS ALB) + overlays/local (ingress-nginx)
```

## Conventions

- Every `Application` in `argocd/applications/` sets `syncPolicy.automated: {prune: true, selfHeal: true}`. All but one point at a `kubernetes/<service>` (or `.../overlays/<env>`) Kustomize path; `aws-load-balancer-controller.yaml` is Helm-sourced from AWS's own `eks-charts` repo instead, since that's the only way AWS ships it (no EKS-managed add-on, and installing it via `helm_release` from the same Terraform apply that creates the cluster hits a provider chicken-and-egg problem). Mixing source types per-Application like this is normal in Argo CD.
- `bootstrap/project.yaml` (the `AppProject`) is applied manually and is **not** watched by the root Application — scope/RBAC changes there require a deliberate `kubectl apply`, not an automatic sync.
- Overlays patch replica count and resource requests/limits only; shared spec/probes/ports stay in `base/`. The one exception is `overlays/local` (producer/consumer/health-server/clickhouse), which also overrides the `images:` transformer's tag to `local` — see "Local development (kind)" below for why.
- Verify offline before touching a cluster: `kubectl kustomize <path>` to render, `kubectl apply --dry-run=client -k <path>` to validate. No live cluster required for either.
- `kubernetes/ingress/base/grafana-ingress.yaml` uses `ingressClassName: alb`, served by `argocd/applications/aws-load-balancer-controller.yaml`. Its IRSA role is provisioned in `nyc-taxi`'s Terraform (`modules/eks/main.tf`, `alb_controller_role_arn` output) — after `terraform apply`, replace that Application's `<CLUSTER_NAME>`/`<ALB_CONTROLLER_ROLE_ARN>` placeholders with the real output values.

## Local development (kind)

A kind cluster is a parallel, disposable deployment target for smoke-testing this repo without AWS — it does not replace the EKS path above, and neither `argocd/applications/local/` nor the `overlays/local` directories are ever synced by the AWS root Application (Argo CD directory Applications are non-recursive, so `argocd/applications/local/` is invisible to `root-application.yaml`'s `path: argocd/applications`).

What's different from AWS:

- No ALB / IRSA: `aws-load-balancer-controller` has no local counterpart. `bootstrap/install-ingress-nginx.sh` installs ingress-nginx as a plain static manifest instead (kind-only, not Argo-managed, same reasoning as `install-argocd.sh` bootstrapping Argo CD itself before anything can reconcile). `kubernetes/ingress/overlays/local` swaps `ingressClassName: alb` for `nginx` and drops the ALB annotations.
- No registry: `producer`, `consumer`, `health-server`, and clickhouse's `schema-apply` Job all run the `app` image; kafka's `StatefulSet` and topic Job run the `kafka` image. Both are Kustomize `images:` placeholders normally rewritten to a real registry image by CI. Each service's `overlays/local` overrides its tag to `local` instead (layered on top of `overlays/dev` for producer/consumer/health-server, since local only needs to add the tag override, not different sizing). Build with `docker build -t app:local ...` / `docker build -t kafka:local -f deployments/docker/kafka/Dockerfile .` in `nyc-taxi` and run `kind load docker-image <image>:local --name <cluster>` for each before syncing — a non-`latest` tag makes Kubernetes default to `imagePullPolicy: IfNotPresent`, so kubelet uses the loaded image instead of trying to pull from a real registry.
- Storage: no `storageClassName` is set anywhere in `kubernetes/`, so kind's default `standard` StorageClass (local-path-provisioner) satisfies every PVC (Kafka, ClickHouse, Prometheus, Grafana) with no changes needed.

Order of operations: `kind create cluster --config bootstrap/kind-config.yaml` → build + `kind load docker-image` both `app:local` and `kafka:local` → `bootstrap/install-argocd.sh` → `bootstrap/install-ingress-nginx.sh` → `kubectl apply -f bootstrap/project.yaml` → `kubectl apply -f bootstrap/root-application-local.yaml`. Grafana is then reachable at `http://localhost/` (kind-config.yaml maps container port 80 to the host).

## Standing constraint

Do not run `terraform apply` (EKS) or the Argo CD bootstrap (`bootstrap/install-argocd.sh`, applying `project.yaml`/`root-application.yaml`) until every manifest under `kubernetes/` is written and verified via the dry-run commands above. YAML can be authored and verified entirely offline; EKS is provisioned last since standing up the cluster starts incurring AWS charges. This constraint is specific to EKS/AWS — it does not block the kind path above, which incurs no cloud cost.
