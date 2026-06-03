# Teleport Grafana Dashboards (rev-tech)

Five Grafana dashboards for self-hosted Teleport (v18.x) when scraped by
kube-prometheus-stack. Templated on `$datasource`, `$namespace`, and
`$teleport_job` (derived from `label_values(teleport_build_info, job)`) so they
work against any cluster — `teleport`, `teleport-auth`, `teleport-proxy`, etc.
— without query edits.

| File | UID | Refresh | Default range |
|------|-----|---------|---------------|
| `teleport-ops-health.json` | `rev-tech-teleport-ops-health` | 30s | last 1h |
| `teleport-identity.json` | `rev-tech-teleport-identity` | 1m | last 24h |
| `teleport-overview.json` | `rev-tech-teleport-overview` | 30s | last 1h |
| `teleport-identity-security.json` | `teleport-identity-security` | — | — |
| `teleport-backend-cnpg.json` | `teleport-backend-cnpg` | 30s | last 1h |

All dashboards are tagged `teleport`, `rev-tech` and use `schemaVersion: 39`.

## Dashboards

### `teleport-ops-health.json` — Ops Health

Audience: SREs / Ops running self-hosted Teleport in production. The "what
would page me at 2am?" board. Backend-agnostic — every query relies only on
Teleport-emitted metrics plus K8s pod metrics, so it works regardless of
which backend (Postgres, DynamoDB, etcd, Firestore, SQLite) is in use.
Panels grouped into rows:

- **Cluster Health** — fraction of `up{}` targets, pod restart count (1h table).
- **Backend Performance** — P50/P95/P99 read & write latency from
  `backend_read_seconds_bucket` / `backend_write_seconds_bucket`, plus combined
  read/write ops-per-second.
- **Audit Pipeline** — emission rate (with failed-emit overlay) and 1h totals
  for `audit_failed_emit_events` and `teleport_incomplete_session_uploads_total`.
- **Resource Pressure** — per-pod CPU and memory from cAdvisor.

For CNPG-Postgres-specific backend health (replication lag, connection
count, database size) pair this with `teleport-backend-cnpg.json` below.

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

### `teleport-identity-security.json` — Identity Security

Audience: Security analysts. Pivots off the Teleport Access Graph plus the
Teleport audit-event stream to answer "who has what, what's risky, and what
just happened." Rows include Summary, Risk Indicators, Security Alerts,
**Session Activity**, User & Identity Details, Access Request & Reviewer
Topology, Resources & Blast Radius, and Policy Hygiene.

The Session Activity row surfaces Teleport's AI-generated
`session.summarized` audit events (risk_level + short_description per
session) as four analyst-targeted panels:

- **Risk Level Breakdown** — 4 stats (Critical / High / Medium / Low) with
  background colors red / orange / yellow / green.
- **High & Critical Risk Sessions** — table sorted CRITICAL > HIGH then by
  time DESC. Risk-level cells are color-mapped; username, hostname, and
  short_description columns deep-link into the Teleport Web UI (filter,
  resources page, session recording player respectively).
- **Recent Session Summaries** — same shape, no risk filter. Filter-aware
  on the existing `${user}` dropdown.
- **Session Activity Trend** — 30-day stacked bar chart by risk_level,
  mirroring the Alert Trend panel one section up.

**Second Postgres datasource required.** The Session Activity panels read
from `public.events` on the Teleport backend DB, which is a *different*
database from the Access Graph one the rest of the dashboard uses. The
dashboard ships with a second template-variable datasource named
`Teleport Backend`; `helm/monitoring-values.yaml` provisions it as an
`additionalDataSources` entry, and `scripts/spin-up.sh` mirrors the
CNPG-managed `teleport-postgres-app` secret from `teleport/` into
`monitoring/` so the Grafana pod can read the password via `envValueFrom`.

The datasource is portable across any **Postgres-backed** Teleport
deployment (CNPG, AWS RDS, self-hosted Postgres) — recipients just need to
point the datasource URL/credentials at their own Postgres. The row is
**not usable** for Teleport clusters running on DynamoDB, etcd, Firestore,
or SQLite backends, since `session.summarized` events land in whatever
audit-event storage the cluster uses and this dashboard only queries
Postgres. Those users should hide the row (collapse it) or drop the
datasource — the rest of the dashboard continues to work on the Access
Graph datasource alone.

Requires Teleport 17.0+ (when `session.summarized` audit events were
introduced). On older versions the Session Activity panels will be empty.

### `teleport-backend-cnpg.json` — Backend (CNPG Postgres)

Audience: SREs running Teleport on the [CloudNativePG](https://cloudnative-pg.io/)
Postgres backend. Three panels covering the Postgres-side health signals
that complement the backend-agnostic latency/ops panels in
`teleport-ops-health.json`:

- **Postgres Replication Lag** — gauge over `cnpg_pg_replication_lag`,
  green/orange/red at 0 / 5s / 10s. Sustained lag above 10s warrants a
  pager.
- **Postgres Active Connections** — `sum by (state) (cnpg_backends_total)`
  to watch for connection-count blowups (idle-in-transaction storms,
  leaked clients, etc).
- **Postgres Database Size** — `cnpg_pg_database_size_bytes` for the
  `teleport` and `access_graph` databases over time.

**Backend-specific.** This dashboard is intentionally scoped to CNPG.
Recipients running Teleport on a different backend (DynamoDB, RDS,
Firestore, etcd, …) should ignore or delete it and pair
`teleport-ops-health.json` with their backend vendor's own observability
(AWS CloudWatch RDS / DynamoDB dashboards, etc).

Requires the following metrics, which CNPG exposes when
`spec.monitoring.enablePodMonitor: true` is set on the `Cluster` CR:

- `cnpg_pg_replication_lag`
- `cnpg_backends_total`
- `cnpg_pg_database_size_bytes`

## Portability: `${teleport_url}` and `${teleport_cluster}` constants

`teleport-identity-security.json` deep-links into the Teleport Web UI (user
pages, role pages, Access Graph, resource search). Those URLs depend on the
cluster being viewed, so the dashboard ships as `.json.tpl` and uses a
layered substitution pattern:

1. **Two Grafana `constant` template variables** — `teleport_url` and
   `teleport_cluster` — drive all 18 data-link URLs and the dashboard-level
   "Teleport Access Graph ↗" link. They are `hide: 2` (hidden from the UI),
   but recipients can still override them through Grafana's Variables editor
   or via URL params (`?var-teleport_url=https://their-teleport.example.com`).
2. **Default values are envsubst placeholders.** The constants ship with
   `${TELEPORT_URL}` and `${TELEPORT_CLUSTER}` as their defaults. When
   `scripts/spin-up.sh` renders `helm/dashboards/*.json.tpl` it pipes them
   through `envsubst '${TELEPORT_URL} ${TELEPORT_CLUSTER}'` — an explicit
   allow-list so Grafana's own `${tenant}`, `${user}`, `${role}`,
   `${DS_ACCESS_GRAPH}`, `${__value.text:percentencode}` references pass
   through untouched. On our deploy the constants end up baked with the
   live cluster's hostname.
3. **Recipients without our tooling.** Anyone importing the rendered JSON
   into their own Grafana can either edit the constants in the Variables UI
   ("Make editable" + override `teleport_url` to e.g.
   `https://teleport.example.com` and `teleport_cluster` to
   `teleport.example.com`), or pass `?var-teleport_url=...&var-teleport_cluster=...`
   in the dashboard URL. The deep-links then route to their cluster.

`config.env` / `config.env.example` define both variables (defaulted from
`TELEPORT_DOMAIN`). Nothing else in the repo currently uses them.

## How they are loaded in our cluster

Grafana is installed via `kube-prometheus-stack`, whose Grafana ships with
the `kiwigrid/k8s-sidecar` dashboard sidecar enabled. The sidecar watches
the cluster for `ConfigMap`s that carry a specific label and imports their
contents as Grafana dashboards on the fly.

Create one ConfigMap per dashboard (or a single ConfigMap with all five
JSON files as separate keys):

```bash
kubectl -n monitoring create configmap teleport-dashboards \
  --from-file=teleport-ops-health.json=helm/dashboards/teleport-ops-health.json \
  --from-file=teleport-identity.json=helm/dashboards/teleport-identity.json \
  --from-file=teleport-overview.json=helm/dashboards/teleport-overview.json \
  --from-file=teleport-identity-security.json=helm/dashboards/teleport-identity-security.json \
  --from-file=teleport-backend-cnpg.json=helm/dashboards/teleport-backend-cnpg.json \
  --dry-run=client -o yaml | \
  kubectl label -f - --local -o yaml grafana_dashboard=1 | \
  kubectl apply -f -
```

Note: `teleport-identity-security.json` is rendered from
`teleport-identity-security.json.tpl` — `scripts/spin-up.sh` does this
automatically, or by hand:
`envsubst '${TELEPORT_URL} ${TELEPORT_CLUSTER}' < helm/dashboards/teleport-identity-security.json.tpl > helm/dashboards/teleport-identity-security.json`.
See the "Portability" section above for what those constants control.

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

- **Teleport — Overview (TV)** (`rev-tech-teleport-overview`)
  Single-screen status board with big-number tiles for cluster status,
  resources, sessions, today's logins/failures, audit errors, CPU/memory.
- **Teleport — Ops Health** (`rev-tech-teleport-ops-health`)
  SRE-focused: pod health, backend latency P50/P95/P99, audit pipeline
  errors, per-pod CPU/memory. Backend-agnostic — no CNPG/Postgres queries.
- **Teleport — Identity & Access** (`rev-tech-teleport-identity`)
  Security + SE demo: login success/failure rate, 24h success ratio,
  certificate issuance rate and latency, active sessions, gRPC RPC mix and
  error rate, connected-resource inventory by type.

The repo also ships two additional dashboards that are **deployment-specific
and not part of this submission**:

- `teleport-identity-security.json` — Access Graph + audit-event analytics.
  Ships as a `.json.tpl` because all deep-links into the Teleport Web UI
  are baked in via `envsubst` on `${TELEPORT_URL}` / `${TELEPORT_CLUSTER}`
  at render time. Also requires a second Postgres datasource pointed at
  the Teleport backend DB for the Session Activity panels. Could be
  upstreamed later as a separate, more carefully templatised submission.
- `teleport-backend-cnpg.json` — CloudNativePG-only (`cnpg_pg_replication_lag`,
  `cnpg_backends_total`, `cnpg_pg_database_size_bytes`). Not appropriate
  for a generic rev-tech dashboard set, since most Teleport deployments
  use a different backend (DynamoDB, RDS, Firestore, etc).

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
and standard kube-prometheus-stack scrapes. No backend-specific metrics —
the Ops Health backend panels use the Teleport-emitted
`backend_{read,write}_seconds_bucket` / `backend_{read,write}_requests_total`
series, which exist regardless of which backend (Postgres, DynamoDB, etcd,
Firestore, SQLite) is in use.

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
