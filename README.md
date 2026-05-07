# Teleport k0ps cluster

Self-hosted [Teleport](https://goteleport.com) Enterprise on a cost-effective [k0ps](https://kops.sigs.k8s.io/getting_started/install/) Kubernetes cluster in AWS. Includes full lifecycle management — spin up, spin down, pause, resume — with optional GitHub Actions scheduling for automated 9am–7pm weekday operation.

**Stack:** kops · CloudNativePG (PostgreSQL backend) · Google Workspace OIDC · kube-prometheus-stack · Machine ID CI/CD · Access Graph · auto-approval bot

## Contents

- [Cost Estimates](#cost-estimates)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Setup](#setup)
  - [1. Configure](#1-configure)
  - [2. Bootstrap](#2-bootstrap-one-time)
  - [3. Build the Postgres image](#3-build-the-postgres-image-one-time)
  - [4. Spin up](#4-spin-up)
  - [5. Create an admin user](#5-create-an-admin-user)
- [Daily Usage](#daily-usage)
  - [Pause / Resume](#pause-scale-workers-to-0)
  - [Tear down](#tear-down-full-delete)
  - [Refresh kubeconfig](#refresh-kubeconfig)
  - [Clean up orphaned resources](#clean-up-orphaned-resources)
- [GitHub Actions Scheduling](#github-actions-scheduling)
- [Guides](#guides)
- [Repository Structure](#repository-structure)
- [Cluster Details](#cluster-details)
- [Troubleshooting](#troubleshooting)
- [Upgrading](#upgrading)

---

## Cost Estimates

22 working days/month, 10 hr/day active (220 active hours):

| Mode | Monthly | Notes |
|---|---|---|
| Scheduled (full spin-up/down) | ~$28 | ~$0.13/hr active, $0 when down |
| Pause/resume (master 24/7) | ~$47 | ~$1/day master idle cost |
| Always on | ~$90 | |
| **EKS equivalent** | **~$90–130** | $73/mo control plane fee alone |

### Active cost breakdown (~$0.13/hr)

| Resource | Spec | $/hr |
|---|---|---|
| Master EC2 | t3.medium, on-demand | ~$0.042 |
| Worker EC2 | t3.large, spot | ~$0.020–0.035 |
| NLB | API server | ~$0.025 |
| EBS volumes | 128 GB etcd-main + 64 GB etcd-events + 2× 20 GB root + 10 GB CNPG (gp3) | ~$0.030 |

### Persistent cost (survives teardown)

| Resource | Cost |
|---|---|
| S3 — kops state store | ~$0.023/GB/mo |
| S3 — Teleport session recordings | ~$0.023/GB/mo |
| S3 — CNPG WAL archive + base backups | ~$0.023/GB/mo |
| Route53 — hosted zone | $0.50/mo (existing zone) |

Postgres state (users, roles, audit events) is preserved across teardowns via CNPG WAL archiving to S3. No DynamoDB — no per-request charges.

Spot instances are used for worker nodes. The master runs on-demand (t3.medium, ~$0.042/hr).

---

## Architecture

```
  Users / Clients
        |
        | HTTPS / SSH / Kubernetes / Google OIDC
        v
  Route53: teleport.yourdomain.com  (ALIAS A → NLB)
        |
        v
  AWS NLB (created by k0ps)
        |
        v
  ┌─────────────────────────────────────────────────────┐
  │  kops cluster  (dev.k8s.local)                      │
  │                                                     │
  │  master: t3.medium (on-demand)                      │
  │  nodes:  t3.large (spot)                            │
  │                                                     │
  │  ┌──────────────────────────────────────────────┐   │
  │  │  namespace: teleport                         │   │
  │  │    - teleport pod (auth+proxy, chartMode:    │   │
  │  │        scratch, PostgreSQL backend)          │   │
  │  │    - approval-bot (auto-approves ssh-access) │   │
  │  │    - cert-manager (TLS/ACME)                 │   │
  │  ├──────────────────────────────────────────────┤   │
  │  │  namespace: teleport (CNPG)                  │   │
  │  │    - teleport-postgres (CloudNativePG)       │   │
  │  │      PostgreSQL 17 + wal2json                │   │
  │  ├──────────────────────────────────────────────┤   │
  │  │  namespace: monitoring                       │   │
  │  │    - kube-prometheus-stack                   │   │
  │  │    - Grafana + Teleport dashboard            │   │
  │  └──────────────────────────────────────────────┘   │
  └─────────────────────────────────────────────────────┘
        |                         |
        v                         v
  S3: session recordings    S3: CNPG WAL archive
  (audit_sessions_uri)      + base backups
                            (persists across teardowns)
```

**Gossip DNS** is used for the kops cluster itself (cluster name ends in `.k8s.local`) — no Route53 setup needed for the cluster. Route53 is only used for the public Teleport address and TLS cert DNS-01 challenges.

**Instance profile IAM** grants node pods access to S3 via the EC2 role — no static credentials, no IRSA complexity. CNPG uses `inheritFromIAMRole: true` for WAL archiving.

**PostgreSQL backend** (CloudNativePG) stores all Teleport state: cluster backend, audit events, access requests. On `make down`, a base backup is triggered before teardown. On `make up`, the presence of that backup is detected and the cluster bootstraps from recovery instead of initdb — all data is preserved.

---

## Prerequisites

| Tool | Install |
|---|---|
| [k0ps](https://kops.sigs.k8s.io/getting_started/install/) | `brew install kops` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | `brew install kubectl` |
| [helm](https://helm.sh/docs/intro/install/) | `brew install helm` |
| [aws CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) | `brew install awscli` |
| [envsubst](https://www.gnu.org/software/gettext/) | `brew install gettext` |

**AWS credentials** must be configured (`aws configure` or SSO) with permissions to manage EC2, S3, IAM, Route53, ELB, and VPC.

**Teleport Enterprise license** — required. Save as `license.pem` in the repo root (gitignored).

**Google Workspace service account** with domain-wide delegation — required for Google OIDC group fetching. Save as `.config/google-sa.json` (gitignored).

An SSH keypair is required for k0ps node access. Defaults to `~/.ssh/id_rsa.pub` — generate one with `ssh-keygen -t rsa -b 4096` if needed.

---

## Setup

### 1. Configure

```bash
cp config.env.example config.env
# Edit config.env with your values
```

Key values to fill in:

| Variable | Description | Example |
|---|---|---|
| `PREFIX` | Unique prefix for all resource names | `jturner` |
| `KOPS_STATE_BUCKET` | S3 bucket name for kops state | `jturner-tele-kops-state` |
| `K8S_API_DOMAIN` | Custom DNS for kubectl (CNAME → API ELB) | `k8s.teleport.example.com` |
| `TELEPORT_DOMAIN` | Public hostname for Teleport | `teleport.example.com` |
| `TELEPORT_SESSIONS_BUCKET` | S3 bucket for session recordings | `jturner-tele-sessions` |
| `TELEPORT_PG_WAL_BUCKET` | S3 bucket for CNPG WAL archive + base backups | `jturner-tele-pgwal` |
| `TELEPORT_LICENSE_FILE` | Path to Enterprise license (gitignored) | `license.pem` |
| `ROUTE53_HOSTED_ZONE_ID` | Hosted zone ID for your domain | `Z1D633PJN98FT9` |
| `LETSENCRYPT_EMAIL` | Email for TLS cert expiry notifications | `you@example.com` |
| `GOOGLE_SA_JSON_FILE` | Service account JSON with domain-wide delegation | `.config/google-sa.json` |
| `GOOGLE_ADMIN_EMAIL` | Google Workspace admin for group lookups | `admin@example.com` |
| `GOOGLE_OAUTH_CLIENT_ID` | OAuth2 client ID from Google Cloud Console | |
| `GOOGLE_OAUTH_CLIENT_SECRET` | OAuth2 client secret | |

> Find your hosted zone ID: `aws route53 list-hosted-zones --query 'HostedZones[*].[Name,Id]' --output table`

### 2. Bootstrap (one-time)

Creates the S3 buckets and IAM role that persist across cluster teardowns. Safe to re-run.

```bash
make bootstrap
```

This creates:
- **S3 bucket** — kops state store
- **S3 bucket** — Teleport session recordings (versioned + encrypted)
- **S3 bucket** — CNPG WAL archive + base backups (versioned + encrypted)
- **IAM role** — `${PREFIX}-kops-deployer` — dedicated automation role assumed before all kops operations

All resources are tagged with `teleport.dev/creator` and `KubernetesCluster`.

### 3. Build the Postgres image (one-time)

The cluster uses a custom PostgreSQL 17 image with `wal2json` installed (required for logical replication). Build it by pushing `docker/Dockerfile` to GitHub — the `build-postgres.yml` workflow publishes it to GHCR:

```bash
git push origin main   # triggers build-postgres.yml
```

Or trigger manually:

```bash
gh workflow run build-postgres.yml
```

The image must exist at `ghcr.io/<your-org>/postgres-wal2json:17` before running `make up`.

### 4. Spin up

```bash
make up
```

This takes ~20 minutes and:

1. Creates the kops cluster config in S3
2. Provisions EC2 instances, VPC, security groups, NLB
3. Waits for the cluster to be healthy
4. Installs cert-manager with a Let's Encrypt ClusterIssuer
5. Installs CloudNativePG operator and PostgreSQL cluster
   - First run: bootstraps from scratch (`initdb`)
   - Subsequent runs: recovers from S3 base backup (all data preserved)
6. Installs the `teleport-cluster` Helm chart (Enterprise, PostgreSQL backend)
7. Creates demo namespaces (`admin`, `engineering`, `devops`) and K8s RBAC bindings
8. Installs kube-prometheus-stack with Teleport ServiceMonitor + Grafana dashboard
9. Creates Route53 records pointing to the Teleport NLB
10. Applies Teleport RBAC roles, Login Rules, and Google OIDC connector via `tctl`
11. Deploys the access-request approval bot
12. Installs `teleport-access-graph` (Identity Security) with a CNPG-backed Postgres database and cert-manager-issued in-cluster TLS
13. Installs a `teleport-kube-agent` registering Grafana behind Teleport's `app_service` (accessible at `https://grafana.<TELEPORT_DOMAIN>`)

When complete:

```
[spin-up] Teleport is ready at: https://teleport.yourdomain.com

[spin-up] Create your first admin user:
[spin-up]   kubectl -n teleport exec deploy/teleport -- tctl users add admin --roles=access,editor,auditor
```

> `make up` is idempotent — safe to re-run if interrupted. It detects a running cluster and skips provisioning.

### 5. Create an admin user

```bash
kubectl -n teleport exec deploy/teleport -- \
  tctl users add admin --roles=access,editor,auditor
```

Follow the printed link to set a password and configure MFA.

**Set Google as the default SSO connector** (run once after first login):

```bash
kubectl -n teleport exec -it deploy/teleport -- tctl edit cap
# Set: spec.oidc.connector_name: google
```

---

## Daily Usage

### Pause (scale workers to 0)

Workers are terminated in seconds. The master keeps running at ~$1/day. Teleport becomes unavailable until resumed.

```bash
make pause
```

### Resume (~2-3 min)

Workers scale back up, Teleport pods reschedule automatically.

```bash
make resume
```

### Tear down (full delete)

Triggers a CNPG base backup to S3, then deletes all EC2 resources. All Teleport data is **preserved** in S3 — spin back up any time and pick up exactly where you left off.

```bash
make down
```

### Spin back up after teardown

```bash
make up
```

CNPG detects the existing base backup in S3 and recovers from it. No data loss.

### Refresh kubeconfig

k0ps admin tokens expire after ~18 hours. Refresh with:

```bash
make kubeconfig
```

### Clean up orphaned resources

If `make up` fails partway through, EC2 resources may be left behind. Use this to delete them without touching S3:

```bash
make clean-cluster
```

Then re-run `make up`.

---

## GitHub Actions Scheduling

Automate spin-up and spin-down on a weekday schedule. Authentication uses your existing Teleport cluster as an OIDC provider — no long-lived AWS keys stored in GitHub.

### Step 1: AWS — add a trust policy to the k0ps deployer role

`bootstrap.sh` creates the `${PREFIX}-kops-deployer` IAM role with a trust policy allowing any principal in your AWS account to assume it. To let GitHub Actions (via Teleport OIDC) assume it directly, add a trust statement for your Teleport cluster's OIDC provider:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TELEPORT_PROXY="teleport.example.com"   # your Teleport proxy address

aws iam update-assume-role-policy \
  --role-name "${PREFIX}-kops-deployer" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Principal\": { \"AWS\": \"arn:aws:iam::${ACCOUNT_ID}:root\" },
        \"Action\": \"sts:AssumeRole\"
      },
      {
        \"Effect\": \"Allow\",
        \"Principal\": { \"Federated\": \"arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${TELEPORT_PROXY}\" },
        \"Action\": \"sts:AssumeRoleWithWebIdentity\",
        \"Condition\": {
          \"StringEquals\": {
            \"${TELEPORT_PROXY}:sub\": \"bot-github-deploy\"
          }
        }
      }
    ]
  }"
```

Set `AWS_DEPLOY_ROLE_ARN` in GitHub to `arn:aws:iam::${ACCOUNT_ID}:role/${PREFIX}-kops-deployer`.

> Verify the OIDC provider exists: `aws iam list-open-id-connect-providers`

### Step 2: Teleport — create a GitHub Actions bot

On your existing Teleport cluster, create a bot with a GitHub join token:

```yaml
# bot.yaml
kind: bot
version: v1
metadata:
  name: github-deploy
spec:
  roles: []   # roles not needed — the bot only vends AWS credentials

---
kind: token
version: v2
metadata:
  name: github-actions-kops
spec:
  roles: [Bot]
  bot_name: github-deploy
  join_method: github
  github:
    allow:
      - repository: YOUR_GITHUB_ORG/kops-teleport-dev-cluster
```

```bash
tctl create -f bot.yaml
```

The `token` name (`github-actions-kops`) is what goes in `TELEPORT_BOT_TOKEN_NAME` below.

### Step 3: Repository secrets and variables

In your GitHub repo, go to **Settings → Secrets and variables → Actions**:

**Secrets** (sensitive):

| Secret | Value |
|---|---|
| `KOPS_SSH_PUBLIC_KEY` | Contents of `~/.ssh/id_rsa.pub` |

**Variables** (non-sensitive config):

| Variable | Example | Notes |
|---|---|---|
| `PREFIX` | `jturner` | Unique prefix for all resource names |
| `KOPS_STATE_BUCKET` | `jturner-tele-kops-state` | S3 bucket for kops state |
| `TELEPORT_SESSIONS_BUCKET` | `jturner-tele-sessions` | S3 bucket for session recordings |
| `TELEPORT_PG_WAL_BUCKET` | `jturner-tele-pgwal` | S3 bucket for CNPG WAL archive |
| `TELEPORT_PROXY` | `teleport.example.com:443` | Your existing Teleport cluster proxy |
| `TELEPORT_BOT_TOKEN_NAME` | `github-actions-kops` | Join token name from Step 2 |
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::123456789:role/jturner-kops-deployer` | Role created by `make bootstrap` |
| `AWS_REGION` | `us-east-1` | AWS region |
| `AWS_AZ` | `us-east-1a` | AZ within the region; defaults to `${AWS_REGION}a` if unset |
| `CLUSTER_NAME` | `dev.k8s.local` | kops cluster name (must end in `.k8s.local`) |
| `K8S_API_DOMAIN` | `k8s.teleport.example.com` | Custom DNS for kubectl API server |
| `WORKER_MIN` | `2` | Minimum worker nodes (min 2 for CNPG + Teleport headroom) |
| `WORKER_MAX` | `2` | Maximum worker nodes |
| `TELEPORT_VERSION` | `18` | Teleport major version to pin |
| `TELEPORT_DOMAIN` | `teleport.example.com` | Public hostname for Teleport |
| `ROUTE53_HOSTED_ZONE_ID` | `Z1D633PJN98FT9` | Hosted zone ID for `TELEPORT_DOMAIN` |
| `LETSENCRYPT_EMAIL` | `you@example.com` | Email for TLS cert expiry notifications |
| `SCHEDULE_TZ` | `America/New_York` | Timezone for up/down schedule (default: `America/New_York`) |
| `SCHEDULE_UP_HOUR` | `9` | Hour (0–23) to spin up (default: `9`) |
| `SCHEDULE_DOWN_HOUR` | `19` | Hour (0–23) to spin down (default: `19`) |

### Step 4: Workflows

The workflows are pre-configured in `.github/workflows/`:

| Workflow | Trigger | Default schedule |
|---|---|---|
| `cluster-up.yml` | Manual or cron | 9:00 AM `SCHEDULE_TZ` weekdays |
| `cluster-down.yml` | Manual or cron | 7:00 PM `SCHEDULE_TZ` weekdays |

The cron runs every hour on weekdays. A `check-schedule` job gates execution based on `SCHEDULE_TZ` + `SCHEDULE_UP_HOUR`/`SCHEDULE_DOWN_HOUR` — DST is handled automatically. To change the schedule, update the GitHub variables; no workflow edits needed.

**Manual trigger** (GitHub UI or CLI):

```bash
gh workflow run cluster-up.yml
gh workflow run cluster-down.yml
```

---

## Guides

| Guide | Description |
|---|---|
| [SMTP Email Notifications](docs/smtp-email-notifications.md) | Deploy Mailpit in-cluster and configure `teleport-plugin-email` for access request notifications |
| [Access Graph Queries](docs/access-graph-queries.md) | Example SQL queries for exploring identity relationships via Access Graph |

---

## Repository Structure

```
.
├── config.env.example          # Copy to config.env and fill in
├── Makefile                    # up / down / pause / resume / bootstrap / kubeconfig / clean-cluster
│
├── bootstrap/
│   └── bootstrap.sh            # One-time: create S3 buckets + IAM deployer role
│
├── docker/
│   └── Dockerfile              # PostgreSQL 17 + wal2json (built to GHCR by CI)
│
├── kops/
│   └── cluster.yaml.tpl        # k0ps cluster manifest (envsubst template)
│
├── helm/
│   ├── teleport-values.yaml.tpl      # Teleport Helm values (chartMode: standalone, PostgreSQL backend)
│   ├── cert-manager-issuer.yaml.tpl  # Let's Encrypt ClusterIssuer
│   ├── cnpg-cluster-initdb.yaml.tpl  # CloudNativePG cluster — first-run bootstrap
│   ├── cnpg-cluster-recovery.yaml.tpl  # CloudNativePG cluster — S3 recovery mode
│   ├── monitoring-values.yaml        # kube-prometheus-stack values
│   ├── teleport-servicemonitor.yaml  # Prometheus ServiceMonitor for Teleport /metrics
│   ├── grafana-dashboard-teleport.json  # Grafana dashboard: auth events, sessions, nodes
│   ├── tbot-deployment.yaml          # Machine ID agent: manages approval-bot-identity secret
│   └── approval-bot-deployment.yaml  # Approval bot Deployment + ServiceAccount
│
├── scripts/
│   ├── spin-up.sh              # Create cluster + deploy all components
│   ├── spin-down.sh            # Backup Postgres → delete cluster (preserves S3 data)
│   ├── apply-teleport-config.sh  # Apply RBAC roles, Login Rules, OIDC connector via tctl
│   ├── pause.sh                # Scale workers to 0 via ASG
│   ├── resume.sh               # Scale workers back up via ASG
│   ├── kubeconfig.sh           # Refresh kubectl credentials
│   └── clean-cluster.sh        # Delete orphaned EC2 resources
│
├── teleport/
│   ├── roles/                  # Teleport RBAC roles
│   │   ├── role-base.yaml          # All users: can request ssh-access + ssh-root-access
│   │   ├── role-kube-access.yaml   # K8s access scoped to {{external.team}} namespace
│   │   ├── role-ssh-access.yaml    # SSH to all nodes (low-risk, auto-approved)
│   │   ├── role-ssh-root-access.yaml  # Root SSH, 1h TTL (requires manual approval)
│   │   ├── role-ci-bot.yaml        # CI bot: apply roles/OIDC/login rules/tokens
│   │   └── role-approval-bot.yaml  # Approval bot: list/read/update access requests
│   ├── rules/
│   │   └── login-rule.yaml     # Google groups → team trait (used by role-kube-access)
│   ├── connectors/
│   │   └── google-oidc.yaml.tpl  # Google Workspace OIDC connector (envsubst template)
│   ├── bots/
│   │   ├── ci-bot.yaml         # Machine ID bot for GitHub Actions CI
│   │   └── approval-bot.yaml   # Machine ID bot for in-cluster approval bot
│   ├── tokens/
│   │   ├── github-token.yaml       # GitHub OIDC join token for ci-bot
│   │   └── approval-bot-token.yaml # Kubernetes join token for approval-bot
│   └── k8s-rbac/
│       └── namespace-bindings.yaml  # K8s RoleBindings granting team groups edit access
│
├── bot/
│   ├── main.go                 # Auto-approval bot (Go): watches access requests, approves role-ssh-access
│   ├── go.mod
│   └── Dockerfile
│
├── docs/
│   ├── smtp-email-notifications.md
│   └── access-graph-queries.md
│
└── .github/workflows/
    ├── cluster-up.yml          # Scheduled/manual spin-up
    ├── cluster-down.yml        # Scheduled/manual spin-down
    ├── teleport-apply.yml      # CI: apply teleport/ changes via Machine ID (tbot)
    ├── build-postgres.yml      # CI: build + push postgres-wal2json image to GHCR
    └── build-bot.yml           # CI: build + push approval-bot image to GHCR
```

---

## Cluster Details

| Component | Spec |
|---|---|
| Kubernetes | 1.30 |
| Master | 1× t3.medium, on-demand |
| Workers | 2× t3.large, Spot, capacity-optimized |
| API load balancer | NLB (Network Load Balancer) |
| Networking | Calico CNI, public topology (no NAT gateway) |
| DNS | Gossip (`.k8s.local`) — no Route53 for cluster itself |
| Teleport chart mode | `scratch` (full `teleportConfig:` YAML, PostgreSQL backend) |
| PostgreSQL | CloudNativePG 17 + wal2json, WAL-archived to S3 |
| TLS | cert-manager + Let's Encrypt DNS-01 via Route53 |
| Monitoring | kube-prometheus-stack, Teleport ServiceMonitor, Grafana dashboard |
| SSO | Google Workspace OIDC with service-account group fetching |
| Access Control | 4 RBAC roles, Login Rules mapping Google groups → team trait |
| CI/CD | Machine ID (tbot) — GitHub Actions applies `teleport/` changes via `tctl` |
| Auto-approval | Go bot watches access requests; auto-approves `role-ssh-access` only |
| Identity Security | Access Graph enabled + AI Summaries |

---

## Troubleshooting

### kubectl credentials expired

k0ps admin tokens expire after ~18 hours:

```bash
make kubeconfig
```

### Teleport pod not starting

```bash
kubectl describe pod -n teleport -l app=teleport
kubectl logs -n teleport -l app=teleport --previous
```

### CNPG cluster not becoming ready

```bash
kubectl describe cluster -n teleport teleport-postgres
kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg
```

Check that `ghcr.io/<your-org>/postgres-wal2json:17` exists in GHCR and the cluster has pull access.

### TLS cert not issuing

```bash
kubectl describe clusterissuer letsencrypt-production
kubectl describe certificate -n teleport
kubectl describe certificaterequest -n teleport
kubectl logs -n cert-manager -l app=cert-manager
```

cert-manager uses DNS-01 via Route53 — verify `ROUTE53_HOSTED_ZONE_ID` is correct and the node IAM policy has Route53 permissions.

### NLB hostname not appearing

The NLB can take 2–3 minutes to provision after Helm install. The spin-up script polls for up to 5 minutes.

### Orphaned EC2 resources after a failed `make up`

```bash
make clean-cluster
make up
```

### Cluster nodes not joining

SSH to the instance and check kubelet:

```bash
# Get the worker IP
aws ec2 describe-instances \
  --filters "Name=tag:KubernetesCluster,Values=${CLUSTER_NAME}" \
            "Name=tag:Name,Values=nodes-*" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].[InstanceId,PublicIpAddress]' \
  --output table

ssh -i ~/.ssh/id_rsa ubuntu@<PUBLIC_IP>
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 50 --no-pager
```

### Approval bot pod in CrashLoopBackOff

The `approval-bot` Deployment reads the `approval-bot-identity` secret, which is created by the `tbot` Deployment (Machine ID agent) on first join. If the approval bot starts before tbot has finished joining, it will restart and succeed once the secret exists. If it stays in CrashLoopBackOff, check tbot:

```bash
kubectl logs -n teleport deploy/tbot
kubectl describe deployment -n teleport tbot
```

Common causes: `approval-bot-join-token` not yet applied (run `scripts/apply-teleport-config.sh`), or the `approval-bot` ServiceAccount doesn't have the `tbot-secret-manager` RoleBinding.

---

## Upgrading

### Teleport

```bash
helm repo update
helm upgrade teleport teleport/teleport-cluster \
  --namespace teleport \
  --reuse-values
```

### Kubernetes

```bash
# Edit kubernetesVersion in kops/cluster.yaml.tpl, then:
kops edit cluster --name="${CLUSTER_NAME}" --state="${KOPS_STATE_STORE}"
kops update cluster --name="${CLUSTER_NAME}" --state="${KOPS_STATE_STORE}" --yes
kops rolling-update cluster --name="${CLUSTER_NAME}" --state="${KOPS_STATE_STORE}" --yes
```

### CloudNativePG operator

```bash
helm repo update
helm upgrade cnpg-operator cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --reuse-values
```
