# Teleport Grafana Dashboards (rev-tech)

Three Grafana dashboards for self-hosted Teleport (v18.x) when scraped by
kube-prometheus-stack. Templated on `$datasource`, `$namespace`, and
`$teleport_job` (derived from `label_values(teleport_build_info, job)`) so they
work against any cluster — `teleport`, `teleport-auth`, `teleport-proxy`, etc.
— without query edits.

| File | UID | Refresh | Default range |
|------|-----|---------|---------------|
| `teleport-ops-health.json` | `rev-tech-teleport-ops-health` | 30s | last 1h |
| `teleport-identity.json` | `rev-tech-teleport-identity` | 1m | last 24h |
| `teleport-overview.json` | `rev-tech-teleport-overview` | 30s | last 1h |

All dashboards are tagged `teleport`, `rev-tech` and use `schemaVersion: 39`.

## Dashboards

### `teleport-ops-health.json` — Ops Health

Audience: SREs / Ops running self-hosted Teleport in production. The "what
would page me at 2am?" board. Twelve panels grouped into four rows:

- **Cluster Health** — fraction of `up{}` targets, pod restart count (1h table).
- **Backend Performance** — P50/P95/P99 read & write latency from
  `backend_read_seconds_bucket` / `backend_write_seconds_bucket`, plus combined
  read/write ops-per-second.
- **Postgres (CNPG)** — replication lag (gauge, alert >10s), active backends
  per pod, and on-disk size of the `teleport` and `access_graph` databases.
- **Audit Pipeline** — emission rate (with failed-emit overlay) and 1h totals
  for `audit_failed_emit_events` and `teleport_incomplete_session_uploads_total`.
- **Resource Pressure** — per-pod CPU and memory from cAdvisor.

### `teleport-identity.json` — Identity & Access

Audience: Security teams plus customer-success / SE demos. "Who is accessing
what, and is anything anomalous?" Nine panels, 24h default window:

- **Authentication** — login rate (success vs failure) and a single-stat
  24h success ratio with red/orange/green thresholds at 90% / 95%.
- **Certificate Issuance** — user cert + `auth.Generate` request rates and
  P95/P99 issuance latency from `auth_generate_seconds_bucket`.
- **Sessions & Connections** — active SSH sessions and authenticated active
  connections stacked by `connection_type` (ssh / kube / app / db / web).
- **API (gRPC)** — top-10 gRPC methods by RPC/sec and a non-OK error-rate
  panel with thresholds at 1% / 5%.
- **Connected Resources** — `teleport_connected_resources` by type — useful
  for tracking node / app / kube / db agent inventory over time.

### `teleport-overview.json` — Overview (TV mode)

Audience: TV / ops huddle. Single-screen status board, no scrolling. Nine
single-stat / gauge tiles only, all background-coloured by threshold:

- Cluster status (% targets up), connected resources, active SSH sessions,
  worker nodes Ready.
- Logins today, failed logins today (red at >10), audit upload errors in
  the last hour (red at >0).
- Average CPU (gauge, orange/red at 0.5 / 0.9 cores) and average memory
  across teleport pods.

## How they are loaded in our cluster

Grafana is installed via `kube-prometheus-stack`, whose Grafana ships with
the `kiwigrid/k8s-sidecar` dashboard sidecar enabled. The sidecar watches
the cluster for `ConfigMap`s that carry a specific label and imports their
contents as Grafana dashboards on the fly.

Create one ConfigMap per dashboard (or a single ConfigMap with all three
JSON files as separate keys):

```bash
kubectl -n monitoring create configmap teleport-dashboards \
  --from-file=teleport-ops-health.json=helm/dashboards/teleport-ops-health.json \
  --from-file=teleport-identity.json=helm/dashboards/teleport-identity.json \
  --from-file=teleport-overview.json=helm/dashboards/teleport-overview.json \
  --dry-run=client -o yaml | \
  kubectl label -f - --local -o yaml grafana_dashboard=1 | \
  kubectl apply -f -
```

The label key that kube-prometheus-stack watches for is `grafana_dashboard`
with value `1` (configurable via `grafana.sidecar.dashboards.label` and
`labelValue` in the chart values). The sidecar picks the ConfigMap up
within ~10s and the dashboards appear under the `teleport` / `rev-tech`
tags in Grafana.

If you want them in a specific folder, add the annotation
`grafana_folder: Teleport` to the ConfigMap.

## Metric assumptions

All queries use only metrics confirmed to exist in Teleport v18.x and in
the CNPG PodMonitor exporter:

- Teleport auth/proxy: `user_login_total`, `failed_login_attempts_total`,
  `auth_generate_requests_total`, `auth_generate_seconds_bucket`,
  `teleport_user_certificates_generated`, `proxy_ssh_sessions_total`,
  `teleport_connected_resources`, `teleport_authenticated_active_connections`,
  `backend_{read,write}_requests_total`, `backend_{read,write}_seconds_bucket`,
  `teleport_audit_emit_events` (no `_total` suffix on v18 — this is a real
  gotcha), `audit_failed_emit_events`,
  `teleport_incomplete_session_uploads_total`, `grpc_server_handled_total`,
  `teleport_build_info`.
- CNPG: `cnpg_pg_replication_lag`, `cnpg_pg_stat_activity_count`,
  `cnpg_pg_database_size_bytes{datname=...}`. Requires
  `spec.monitoring.enablePodMonitor: true` on the `Cluster` CR.
- kube-state-metrics & cAdvisor (default kube-prometheus-stack):
  `kube_node_status_condition`, `kube_pod_container_status_restarts_total`,
  `container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`,
  `up`.

No panels were dropped — every requested panel is in the output. The audit
emit metric is referenced as `teleport_audit_emit_events` (not
`_total`) per the v18 naming.

## Submitting to `gravitational/rev-tech`

Open the PR with a body along these lines:

```markdown
## Three Teleport Grafana dashboards for kube-prometheus-stack environments

Adds three polished, self-explanatory Grafana dashboards under
`grafana/teleport/` (or wherever fits the repo layout):

- **Teleport — Ops Health** (`rev-tech-teleport-ops-health`)
  SRE-focused: pod health, backend latency P50/P95/P99, CNPG Postgres health
  (replication lag, connection count, DB sizes), audit pipeline errors,
  per-pod CPU/memory.
- **Teleport — Identity & Access** (`rev-tech-teleport-identity`)
  Security + SE demo: login success/failure rate, 24h success ratio,
  certificate issuance rate and latency, active sessions, gRPC RPC mix and
  error rate, connected-resource inventory by type.
- **Teleport — Overview (TV)** (`rev-tech-teleport-overview`)
  Single-screen status board with big-number tiles for cluster status,
  resources, sessions, today's logins/failures, audit errors, CPU/memory.

### Portability

Every panel query is parameterised on three template variables:

- `$datasource` — Prometheus datasource picker.
- `$namespace` — derived from `label_values(teleport_build_info, namespace)`.
- `$teleport_job` — derived from `label_values(teleport_build_info, job)`.

That means the dashboards drop into **any** Teleport cluster scraped by
kube-prometheus-stack regardless of how the Helm chart labels the auth /
proxy jobs (`teleport`, `teleport-auth`, etc).

### Metrics used

All queries use only metrics that exist in OSS / Enterprise Teleport v15+
and standard kube-prometheus-stack scrapes. CNPG panels in the Ops Health
dashboard require `spec.monitoring.enablePodMonitor: true` on the cluster
CR (no-op for non-CNPG users — panels just show "No data").

Note: `teleport_audit_emit_events` is the correct name on v18 (no `_total`
suffix). Don't rename it on import.

### How to use

These are plain Grafana JSON exports (`schemaVersion: 39`). Import via the
Grafana UI, the Grafana provisioning directory, or — in
kube-prometheus-stack environments — a ConfigMap with
`grafana_dashboard=1` for the dashboards sidecar to pick up. Example
ConfigMap manifest is in the README.

### Screenshots
<!-- attach screenshots of each dashboard here -->
```

Once the rev-tech PR is open, link back to it from this repo's PR or the
phase/1 README so future readers can find the canonical, org-wide copy.
