# Teleport k0ps cluster

Self-hosted [Teleport](https://goteleport.com) OSS on a cost-effective [k0ps](https://kops.sigs.k8s.io/getting_started/install/) Kubernetes cluster in AWS. Includes full lifecycle management — spin up, spin down, pause, resume — with optional GitHub Actions scheduling for automated 9am–7pm weekday operation.

## Contents

- [Cost Estimates](#cost-estimates)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Setup](#setup)
  - [1. Configure](#1-configure)
  - [2. Bootstrap](#2-bootstrap-one-time)
  - [3. Spin up](#3-spin-up)
  - [4. Create an admin user](#4-create-an-admin-user)
- [Daily Usage](#daily-usage)
  - [Pause / Resume](#pause-scale-workers-to-0)
  - [Tear down](#tear-down-full-delete)
  - [Refresh kubeconfig](#refresh-kubeconfig)
  - [Clean up orphaned resources](#clean-up-orphaned-resources)
- [GitHub Actions Scheduling](#github-actions-scheduling)
- [Repository Structure](#repository-structure)
- [Cluster Details](#cluster-details)
- [Troubleshooting](#troubleshooting)
- [Upgrading](#upgrading)

---

## Cost Estimates

22 working days/month, 10 hr/day active (220 active hours):

| Mode | Monthly | Notes |
|---|---|---|
| Scheduled (full spin-up/down) | ~$22 | ~$0.10/hr active, $0 when down |
| Pause/resume (master 24/7) | ~$41 | ~$1/day master idle cost |
| Always on | ~$75 | |
| **EKS equivalent** | **~$79–112** | $73/mo control plane fee alone |

### Active cost breakdown (~$0.10/hr)

| Resource | Spec | $/hr |
|---|---|---|
| Master EC2 | t3.medium, on-demand | ~$0.042 |
| Worker EC2 | t3.medium, spot | ~$0.008–0.015 |
| NLB | API server | ~$0.025 |
| EBS volumes | 128 GB etcd-main + 64 GB etcd-events + 2× 20 GB root (gp3) | ~$0.022 |

### Persistent cost (survives teardown)

| Resource | Cost |
|---|---|
| S3 — kops state + session recordings | ~$0.023/GB/mo |
| DynamoDB — cluster backend + audit log | Pay-per-request, ~$0 at low usage |
| Route53 — hosted zone | $0.50/mo (existing zone) |

Spot instances are used for worker nodes. The master runs on-demand (t3.medium, ~$0.042/hr).

---

## Architecture

```
  Users / Clients
        |
        | HTTPS / SSH / Kubernetes
        v
  Route53: teleport.yourdomain.com  (ALIAS A → NLB)
        |
        v
  AWS NLB (created by k0ps)
        |
        v
  ┌─────────────────────────────────────────┐
  │  kops cluster  (dev.k8s.local)          │
  │                                         │
  │  master: t3.medium (on-demand)          │
  │  nodes:  t3.medium (spot)               │
  │                                         │
  │  ┌──────────────────────────────────┐   │
  │  │  namespace: teleport             │   │
  │  │    - teleport pod (auth+proxy)   │   │
  │  │    - cert-manager (TLS/ACME)     │   │
  │  └──────────────────────────────────┘   │
  └─────────────────────────────────────────┘
        |                    |
        v                    v
  DynamoDB (2 tables)    S3 bucket
  - cluster backend      - session recordings
  - audit log
  (persist across teardowns)
```

**Gossip DNS** is used for the kops cluster itself (cluster name ends in `.k8s.local`) — no Route53 setup needed for the cluster. Route53 is only used for the public Teleport address and TLS cert DNS-01 challenges.

**Instance profile IAM** grants the Teleport pod access to DynamoDB and S3 via the node's EC2 role — no static credentials, no IRSA complexity.

---

## Prerequisites

| Tool | Install |
|---|---|
| [k0ps](https://kops.sigs.k8s.io/getting_started/install/) | `brew install kops` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | `brew install kubectl` |
| [helm](https://helm.sh/docs/intro/install/) | `brew install helm` |
| [aws CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) | `brew install awscli` |
| [envsubst](https://www.gnu.org/software/gettext/) | `brew install gettext` |

AWS credentials must be configured (`aws configure` or environment variables) with permissions to manage EC2, S3, DynamoDB, IAM, Route53, and VPC.

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
| `KOPS_STATE_BUCKET` | S3 bucket name for kops state | `jturner-kops-state` |
| `TELEPORT_DOMAIN` | Public hostname for Teleport | `teleport.example.com` |
| `TELEPORT_SESSIONS_BUCKET` | S3 bucket for session recordings | `jturner-teleport-sessions` |
| `ROUTE53_HOSTED_ZONE_ID` | Hosted zone ID for your domain | `Z1D633PJN98FT9` |
| `LETSENCRYPT_EMAIL` | Email for TLS cert expiry notifications | `you@example.com` |

> Find your hosted zone ID: `aws route53 list-hosted-zones --query 'HostedZones[*].[Name,Id]' --output table`

### 2. Bootstrap (one-time)

Creates the S3 buckets and DynamoDB tables that persist across cluster teardowns. Safe to re-run.

```bash
make bootstrap
```

This creates:
- **S3 bucket** — kops state store
- **S3 bucket** — Teleport session recordings (versioned + encrypted)
- **DynamoDB table** — `${PREFIX}-tele-backend` (cluster state, pay-per-request)
- **DynamoDB table** — `${PREFIX}-tele-events` (audit log, pay-per-request)
- **IAM role** — `${PREFIX}-kops-deployer` — dedicated automation role assumed before all kops operations

All resources are tagged with `teleport.dev/creator` and `KubernetesCluster`.

### 3. Spin up

```bash
make up
```

This takes ~15 minutes and:

1. Creates the k0ps cluster config in S3
2. Provisions EC2 instances, VPC, security groups, NLB
3. Waits for the cluster to be healthy
4. Installs cert-manager with a Let's Encrypt ClusterIssuer
5. Installs the `teleport-cluster` Helm chart
6. Creates Route53 records pointing to the Teleport NLB

When complete:

```
[spin-up] Teleport is ready at: https://teleport.yourdomain.com

[spin-up] Create your first admin user:
[spin-up]   kubectl -n teleport exec deploy/teleport -- tctl users add admin --roles=access,editor,auditor
```

> `make up` is idempotent — safe to re-run if interrupted. It detects a running cluster and skips provisioning.

### 4. Create an admin user

```bash
kubectl -n teleport exec deploy/teleport -- \
  tctl users add admin --roles=access,editor,auditor
```

Follow the printed link to set a password and configure MFA.

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

Deletes all EC2 resources. DynamoDB and S3 data is **preserved** — spin back up any time and pick up exactly where you left off.

```bash
make down
```

### Spin back up after teardown

```bash
make up
```

### Refresh kubeconfig

k0ps admin tokens expire after ~18 hours. Refresh with:

```bash
make kubeconfig
```

### Clean up orphaned resources

If `make up` fails partway through, EC2 resources may be left behind. Use this to delete them without touching DynamoDB or S3:

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
| `KOPS_STATE_BUCKET` | `jturner-kops-state` | S3 bucket for kops state |
| `TELEPORT_SESSIONS_BUCKET` | `jturner-teleport-sessions` | S3 bucket for session recordings |
| `TELEPORT_PROXY` | `teleport.example.com:443` | Your existing Teleport cluster proxy |
| `TELEPORT_BOT_TOKEN_NAME` | `github-actions-kops` | Join token name from Step 2 |
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::123456789:role/jturner-kops-deployer` | Role created by `make bootstrap` |
| `AWS_REGION` | `us-east-1` | AWS region |
| `AWS_AZ` | `us-east-1a` | AZ within the region; defaults to `${AWS_REGION}a` if unset |
| `CLUSTER_NAME` | `dev.k8s.local` | kops cluster name (must end in `.k8s.local`) |
| `WORKER_MIN` | `1` | Minimum worker nodes |
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

## Repository Structure

```
.
├── config.env.example          # Copy to config.env and fill in
├── Makefile                    # up / down / pause / resume / bootstrap / kubeconfig / clean-cluster
│
├── bootstrap/
│   └── bootstrap.sh            # One-time: create S3 buckets, DynamoDB tables, IAM role
│
├── kops/
│   └── cluster.yaml.tpl        # k0ps cluster manifest (envsubst template)
│
├── helm/
│   ├── teleport-values.yaml.tpl      # Teleport Helm values
│   └── cert-manager-issuer.yaml.tpl  # Let's Encrypt ClusterIssuer
│
├── scripts/
│   ├── spin-up.sh              # Create cluster + deploy Teleport
│   ├── spin-down.sh            # Delete cluster (preserves data)
│   ├── pause.sh                # Scale workers to 0 via ASG
│   ├── resume.sh               # Scale workers back up via ASG
│   ├── kubeconfig.sh           # Refresh kubectl credentials
│   └── clean-cluster.sh        # Delete orphaned EC2 resources
│
└── .github/workflows/
    ├── cluster-up.yml          # Scheduled/manual spin-up
    └── cluster-down.yml        # Scheduled/manual spin-down
```

---

## Cluster Details

| Component | Spec |
|---|---|
| Kubernetes | 1.30 |
| Master | 1× t3.medium, on-demand |
| Workers | 1–2× t3.medium/t3.large, Spot, capacity-optimized |
| API load balancer | NLB (Network Load Balancer) |
| Networking | Calico CNI, public topology (no NAT gateway) |
| DNS | Gossip (`.k8s.local`) — no Route53 for cluster itself |
| Teleport chart mode | `aws` (DynamoDB + S3 backend) |
| TLS | cert-manager + Let's Encrypt DNS-01 via Route53 |

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
