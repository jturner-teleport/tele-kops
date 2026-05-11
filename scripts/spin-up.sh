#!/usr/bin/env bash
# spin-up.sh — Create the kops cluster and deploy Teleport via Helm.
# Run: make up
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
source "${ROOT_DIR}/config.env"

log()  { echo "[spin-up] $*"; }
fail() { echo "[spin-up] ERROR: $*" >&2; exit 1; }

# The Go AWS SDK validates ALL profiles in ~/.aws/config on load, including
# [default], which may have a broken source_profile. Fix: export SSO credentials
# as env vars and set AWS_CONFIG_FILE=/dev/null so the SDK never reads the file.
if [[ -n "${AWS_PROFILE:-}" ]]; then
  CREDS=$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env 2>/dev/null) \
    || fail "AWS SSO session expired or invalid. Run: aws sso login --sso-session gravitational"
  eval "${CREDS}"
  unset AWS_PROFILE
  export AWS_CONFIG_FILE=/dev/null
fi

# ── Assume kops deployer role ──────────────────────────────────────────────────
# Avoids SCP restrictions on the human SSO role for automation operations.
if [[ -z "${AWS_ACCOUNT_ID:-}" ]]; then
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
fi
# Export so envsubst on cluster.yaml.tpl (IAC IAM ARNs) and
# access-graph-values.yaml.tpl picks it up.
export AWS_ACCOUNT_ID
KOPS_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PREFIX}-kops-deployer"
log "Assuming kops deployer role: ${KOPS_ROLE_ARN}"
read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN < <(
  aws sts assume-role \
    --role-arn "${KOPS_ROLE_ARN}" \
    --role-session-name "kops-${PREFIX}" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text
)
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# ── Preflight ──────────────────────────────────────────────────────────────────
for cmd in kops kubectl helm aws envsubst; do
  command -v "$cmd" &>/dev/null || fail "Missing required tool: ${cmd}"
done

[[ -f "${ROOT_DIR}/${TELEPORT_LICENSE_FILE:-license.pem}" ]] \
  || fail "Enterprise license not found: ${TELEPORT_LICENSE_FILE:-license.pem}"

AWS_AZ="${AWS_AZ:-${AWS_REGION}a}"
export AWS_AZ

K8S_API_DOMAIN="${K8S_API_DOMAIN:-k8s.${TELEPORT_DOMAIN}}"
export K8S_API_DOMAIN

log "Cluster : ${CLUSTER_NAME}"
log "Account : ${AWS_ACCOUNT_ID}"
log "Region  : ${AWS_REGION}"
log "Domain  : ${TELEPORT_DOMAIN}"

# ── Identity Activity Center (IAC) AWS infrastructure ────────────────────────
# Provisions the AWS resources TAG needs to persist Teleport audit events:
# KMS key, SQS main queue + DLQ, two S3 buckets (long-term + transient),
# Glue database + table, Athena workgroup. Mirrors the canonical Teleport
# terraform module:
#   gh api repos/gravitational/teleport/contents/examples/identity-activity-center/identity_activity_center.tf
#
# Done before kops envsubst so the new IAM-policy ARN substitutions in
# cluster.yaml.tpl resolve. Every step is idempotent (re-runs of make up
# are safe on an existing cluster).
log "Provisioning Identity Activity Center AWS resources..."

# 1. KMS key + alias. Everything else encrypts at rest with this key.
if EXISTING_KEY_ID=$(aws kms describe-key \
    --key-id "alias/${TELEPORT_IAC_KMS_ALIAS}" \
    --query 'KeyMetadata.KeyId' --output text 2>/dev/null) \
    && [[ -n "${EXISTING_KEY_ID}" ]]; then
  IAC_KMS_KEY_ID="${EXISTING_KEY_ID}"
  log "  KMS alias exists: alias/${TELEPORT_IAC_KMS_ALIAS} (key ${IAC_KMS_KEY_ID})"
else
  log "  Creating KMS key for IAC encryption..."
  IAC_KMS_KEY_ID=$(aws kms create-key \
    --description "Teleport Identity Activity Center encryption key" \
    --tags "TagKey=teleport.dev/creator,TagValue=${LETSENCRYPT_EMAIL}" \
           "TagKey=KubernetesCluster,TagValue=${CLUSTER_NAME}" \
    --query 'KeyMetadata.KeyId' --output text)
  aws kms enable-key-rotation --key-id "${IAC_KMS_KEY_ID}"
  aws kms create-alias \
    --alias-name "alias/${TELEPORT_IAC_KMS_ALIAS}" \
    --target-key-id "${IAC_KMS_KEY_ID}"
  log "  Created KMS key ${IAC_KMS_KEY_ID} (alias: ${TELEPORT_IAC_KMS_ALIAS})"
fi
IAC_KMS_KEY_ARN="arn:aws:kms:${AWS_REGION}:${AWS_ACCOUNT_ID}:key/${IAC_KMS_KEY_ID}"
export IAC_KMS_KEY_ARN

# 2. SQS DLQ — failed messages from main queue land here for 7-day retention.
# create-queue is idempotent: returns the existing URL when the queue exists
# with matching attributes.
log "  Creating SQS DLQ: ${TELEPORT_IAC_SQS_DLQ}"
IAC_SQS_DLQ_URL=$(aws sqs create-queue \
  --queue-name "${TELEPORT_IAC_SQS_DLQ}" \
  --attributes "KmsMasterKeyId=${IAC_KMS_KEY_ARN},KmsDataKeyReusePeriodSeconds=300,MessageRetentionPeriod=604800" \
  --query 'QueueUrl' --output text)
IAC_SQS_DLQ_ARN=$(aws sqs get-queue-attributes \
  --queue-url "${IAC_SQS_DLQ_URL}" \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' --output text)

# 3. SQS main queue — wired to DLQ via redrive policy.
log "  Creating SQS main queue: ${TELEPORT_IAC_SQS_QUEUE}"
IAC_REDRIVE=$(printf '{"deadLetterTargetArn":"%s","maxReceiveCount":"20"}' "${IAC_SQS_DLQ_ARN}")
IAC_SQS_QUEUE_URL=$(aws sqs create-queue \
  --queue-name "${TELEPORT_IAC_SQS_QUEUE}" \
  --attributes "KmsMasterKeyId=${IAC_KMS_KEY_ARN},KmsDataKeyReusePeriodSeconds=300,RedrivePolicy=${IAC_REDRIVE}" \
  --query 'QueueUrl' --output text)
export IAC_SQS_QUEUE_URL

# 4. S3 long-term bucket — Parquet events partitioned by tenant_id/event_date.
_iac_create_bucket() {
  local bucket="$1"
  if aws s3api head-bucket --bucket "${bucket}" 2>/dev/null; then
    log "  S3 bucket exists: ${bucket}"
    return 0
  fi
  log "  Creating S3 bucket: ${bucket}"
  if [[ "${AWS_REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${bucket}" --region "${AWS_REGION}" >/dev/null
  else
    aws s3api create-bucket \
      --bucket "${bucket}" \
      --region "${AWS_REGION}" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi
}

_iac_secure_bucket() {
  # SSE-KMS + bucket-key (cuts KMS API costs ~100x for high-write workloads),
  # BucketOwnerEnforced ownership, versioning enabled, all public access blocked.
  local bucket="$1"
  aws s3api put-bucket-encryption \
    --bucket "${bucket}" \
    --server-side-encryption-configuration "$(cat <<EOF
{
  "Rules": [{
    "ApplyServerSideEncryptionByDefault": {
      "SSEAlgorithm": "aws:kms",
      "KMSMasterKeyID": "${IAC_KMS_KEY_ARN}"
    },
    "BucketKeyEnabled": true
  }]
}
EOF
)" >/dev/null
  aws s3api put-bucket-ownership-controls \
    --bucket "${bucket}" \
    --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]' >/dev/null
  aws s3api put-bucket-versioning \
    --bucket "${bucket}" \
    --versioning-configuration Status=Enabled >/dev/null
  aws s3api put-public-access-block \
    --bucket "${bucket}" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >/dev/null
}

_iac_create_bucket "${TELEPORT_IAC_LONG_TERM_BUCKET}"
_iac_secure_bucket "${TELEPORT_IAC_LONG_TERM_BUCKET}"

# 5. S3 transient bucket — Athena query results + large_files staging.
# Lifecycle: expire all objects after 60 days (query results have no long-term value).
_iac_create_bucket "${TELEPORT_IAC_TRANSIENT_BUCKET}"
_iac_secure_bucket "${TELEPORT_IAC_TRANSIENT_BUCKET}"
aws s3api put-bucket-lifecycle-configuration \
  --bucket "${TELEPORT_IAC_TRANSIENT_BUCKET}" \
  --lifecycle-configuration "$(cat <<'EOF'
{
  "Rules": [{
    "ID": "delete_after_60_days",
    "Status": "Enabled",
    "Filter": {},
    "Expiration": {"Days": 60}
  }]
}
EOF
)" >/dev/null

# 6. Glue database — logical catalog container for the events table.
log "  Creating Glue database: ${TELEPORT_IAC_GLUE_DB}"
aws glue create-database \
  --database-input "$(cat <<EOF
{
  "Name": "${TELEPORT_IAC_GLUE_DB}",
  "Description": "Teleport Identity Activity Center events"
}
EOF
)" 2>/dev/null || true

# 7. Glue table — schema mirrors gravitational/teleport's canonical IAC module
#    (29 columns + 2 partition keys, partition projection on tenant_id + event_date).
#    NOTE: $${tenant_id}/$${event_date} are LITERAL Athena partition projection
#    placeholders, not shell variables. Wrapped in single quotes to prevent bash
#    expansion. Idempotent: errors out silently if the table already exists.
log "  Creating Glue table: ${TELEPORT_IAC_GLUE_TABLE}"
IAC_TABLE_INPUT=$(cat <<EOF
{
  "Name": "${TELEPORT_IAC_GLUE_TABLE}",
  "Description": "Identity activity events table with partition projection for efficient querying",
  "TableType": "EXTERNAL_TABLE",
  "Parameters": {
    "EXTERNAL": "TRUE",
    "classification": "parquet",
    "parquet.compression": "SNAPPY",
    "projection.enabled": "true",
    "projection.tenant_id.type": "injected",
    "projection.event_date.type": "date",
    "projection.event_date.format": "yyyy-MM-dd",
    "projection.event_date.interval": "1",
    "projection.event_date.interval.unit": "DAYS",
    "projection.event_date.range": "NOW-4YEARS,NOW",
    "storage.location.template": "s3://${TELEPORT_IAC_LONG_TERM_BUCKET}/data/\${tenant_id}/\${event_date}/"
  },
  "StorageDescriptor": {
    "Location": "s3://${TELEPORT_IAC_LONG_TERM_BUCKET}/data/",
    "InputFormat": "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat",
    "OutputFormat": "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat",
    "SerdeInfo": {
      "Name": "identity-events-parquet-serde",
      "SerializationLibrary": "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe",
      "Parameters": {"serialization.format": "1"}
    },
    "Columns": [
      {"Name": "event_source",        "Type": "string"},
      {"Name": "identity",            "Type": "string"},
      {"Name": "identity_kind",       "Type": "string"},
      {"Name": "identity_id",         "Type": "string"},
      {"Name": "token",               "Type": "string"},
      {"Name": "action",              "Type": "string"},
      {"Name": "origin",              "Type": "string"},
      {"Name": "status",              "Type": "string"},
      {"Name": "ip",                  "Type": "string"},
      {"Name": "city",                "Type": "string"},
      {"Name": "country",             "Type": "string"},
      {"Name": "region",              "Type": "string"},
      {"Name": "latitude",            "Type": "double"},
      {"Name": "longitude",           "Type": "double"},
      {"Name": "target_resource",     "Type": "string"},
      {"Name": "target_kind",         "Type": "string"},
      {"Name": "target_location",     "Type": "string"},
      {"Name": "target_id",           "Type": "string"},
      {"Name": "user_agent",          "Type": "string"},
      {"Name": "event_type",          "Type": "string"},
      {"Name": "event_time",          "Type": "timestamp"},
      {"Name": "uid",                 "Type": "string"},
      {"Name": "event_data",          "Type": "string"},
      {"Name": "aws_account_id",      "Type": "string"},
      {"Name": "aws_service",         "Type": "string"},
      {"Name": "github_organization", "Type": "string"},
      {"Name": "github_repo",         "Type": "string"},
      {"Name": "okta_org",            "Type": "string"},
      {"Name": "teleport_cluster",    "Type": "string"}
    ]
  },
  "PartitionKeys": [
    {"Name": "tenant_id",  "Type": "string"},
    {"Name": "event_date", "Type": "date"}
  ]
}
EOF
)
aws glue create-table \
  --database-name "${TELEPORT_IAC_GLUE_DB}" \
  --table-input "${IAC_TABLE_INPUT}" 2>/dev/null \
  || aws glue update-table \
    --database-name "${TELEPORT_IAC_GLUE_DB}" \
    --table-input "${IAC_TABLE_INPUT}" >/dev/null 2>&1 || true

# 8. Athena workgroup — 20 GB scan cap per query, engine v3, encrypted results.
log "  Creating Athena workgroup: ${TELEPORT_IAC_WORKGROUP}"
IAC_WG_CONFIG=$(cat <<EOF
{
  "BytesScannedCutoffPerQuery": 21474836480,
  "EngineVersion": {"SelectedEngineVersion": "Athena engine version 3"},
  "ResultConfiguration": {
    "OutputLocation": "s3://${TELEPORT_IAC_TRANSIENT_BUCKET}/results/",
    "EncryptionConfiguration": {
      "EncryptionOption": "SSE_KMS",
      "KmsKey": "${IAC_KMS_KEY_ARN}"
    }
  }
}
EOF
)
aws athena create-work-group \
  --name "${TELEPORT_IAC_WORKGROUP}" \
  --description "Teleport Identity Activity Center analytics" \
  --configuration "${IAC_WG_CONFIG}" 2>/dev/null || true

log "Identity Activity Center resources ready."

# ── Temp files (cleaned up on exit) ───────────────────────────────────────────
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "${TMPDIR_WORK}"' EXIT

CLUSTER_MANIFEST="${TMPDIR_WORK}/cluster.yaml"
ISSUER_MANIFEST="${TMPDIR_WORK}/issuer.yaml"
CNPG_INITDB_MANIFEST="${TMPDIR_WORK}/cnpg-initdb.yaml"
CNPG_RECOVERY_MANIFEST="${TMPDIR_WORK}/cnpg-recovery.yaml"
# TELEPORT_VALUES is rendered AFTER CNPG is ready (requires CNPG_PASSWORD).
TELEPORT_VALUES="${TMPDIR_WORK}/teleport-values.yaml"

envsubst < "${ROOT_DIR}/kops/cluster.yaml.tpl"                  > "${CLUSTER_MANIFEST}"
envsubst < "${ROOT_DIR}/helm/cert-manager-issuer.yaml.tpl"      > "${ISSUER_MANIFEST}"
envsubst < "${ROOT_DIR}/helm/cnpg-cluster-initdb.yaml.tpl"      > "${CNPG_INITDB_MANIFEST}"
envsubst < "${ROOT_DIR}/helm/cnpg-cluster-recovery.yaml.tpl"    > "${CNPG_RECOVERY_MANIFEST}"

# ── Create or update kops cluster config in state store ───────────────────────
# Always replace (not just create) so that changes to cluster.yaml.tpl —
# especially additionalPolicies — are synced to the state store and applied
# by kops update. Without this, manually patched IAM policies get reverted.
if kops get cluster --name="${CLUSTER_NAME}" --state="${KOPS_STATE_STORE}" &>/dev/null; then
  log "Syncing cluster config to state store (kops replace)..."
  kops replace -f "${CLUSTER_MANIFEST}" --state="${KOPS_STATE_STORE}"
else
  log "Creating kops cluster configuration..."
  kops create -f "${CLUSTER_MANIFEST}" --state="${KOPS_STATE_STORE}"

  log "Adding SSH public key..."
  kops create secret sshpublickey admin \
    --name="${CLUSTER_NAME}" \
    --state="${KOPS_STATE_STORE}" \
    -i "${KOPS_SSH_PUBLIC_KEY}"
fi

# ── Check if cluster is already running ───────────────────────────────────────
RUNNING_MASTER=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:KubernetesCluster,Values=${CLUSTER_NAME}" \
    "Name=tag:Name,Values=master-*" \
    "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text 2>/dev/null || true)

if [[ -n "${RUNNING_MASTER}" && "${RUNNING_MASTER}" != "None" ]]; then
  log "Cluster already running (master: ${RUNNING_MASTER}) — skipping provisioning."
else
  # ── Clean up orphaned etcd EBS volumes from any previous failed run ──────────
  # kops cannot change the Encrypted field on existing volumes, causing
  # "Field cannot be changed: Encrypted" on retry. Safe to delete here because
  # no master is running — these are guaranteed to be from a previous failed run.
  ORPHANED_VOLS=$(aws ec2 describe-volumes \
    --filters "Name=tag:KubernetesCluster,Values=${CLUSTER_NAME}" \
    --query 'Volumes[?Tags[?Key==`Name`]|[?starts_with(Value,`a.etcd-`)]].VolumeId' \
    --output text 2>/dev/null || true)
  if [[ -n "${ORPHANED_VOLS}" ]]; then
    log "Found orphaned etcd volumes from a previous run — deleting before provisioning..."
    for vol in ${ORPHANED_VOLS}; do
      log "  Deleting volume: ${vol}"
      aws ec2 delete-volume --volume-id "${vol}"
    done
  fi

  # ── Provision AWS infrastructure ──────────────────────────────────────────
  log "Provisioning infrastructure (~5 min)..."
  kops update cluster \
    --name="${CLUSTER_NAME}" \
    --state="${KOPS_STATE_STORE}" \
    --yes \
    --admin

fi

# ── Wait for API NLB to be healthy, then patch kubeconfig directly ─────────────
# kops export kubeconfig checks for healthy NLB targets but reliably fails to
# detect them from within this script. Instead, poll AWS directly via elbv2 and
# set the kubeconfig server ourselves — kops update already wrote the correct CA.
log "Waiting for API server NLB to be healthy..."
ATTEMPTS=0
API_ELB_DNS=""
while true; do
  NLB_INFO=$(aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?contains(LoadBalancerName,'api-${PREFIX}')].[LoadBalancerArn,DNSName]" \
    --output text 2>/dev/null || true)
  if [[ -n "${NLB_INFO}" ]]; then
    NLB_ARN=$(echo "${NLB_INFO}" | awk '{print $1}')
    API_ELB_DNS=$(echo "${NLB_INFO}" | awk '{print $2}')
    TG_ARN=$(aws elbv2 describe-target-groups \
      --load-balancer-arn "${NLB_ARN}" \
      --query 'TargetGroups[0].TargetGroupArn' \
      --output text 2>/dev/null || true)
    if [[ -n "${TG_ARN}" && "${TG_ARN}" != "None" ]]; then
      HEALTHY=$(aws elbv2 describe-target-health \
        --target-group-arn "${TG_ARN}" \
        --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`].Target.Id' \
        --output text 2>/dev/null || true)
      if [[ -n "${HEALTHY}" ]]; then
        log "API server NLB healthy: ${API_ELB_DNS}"
        kubectl config set-cluster "${CLUSTER_NAME}" --server="https://${API_ELB_DNS}"
        break
      fi
    fi
  fi
  ATTEMPTS=$((ATTEMPTS + 1))
  [[ $ATTEMPTS -ge 36 ]] && fail "Timed out waiting for API server NLB to be healthy (9 min)"
  log "  (attempt ${ATTEMPTS}/36, retrying in 15s...)"
  sleep 15
done

# ── K8S API custom domain ──────────────────────────────────────────────────────
# Create Route53 CNAME pointing to the ELB, then patch the kubeconfig to use
# the friendly hostname. Done before kubectl wait so all subsequent kubectl
# calls use the custom domain, not the raw ELB.
log "Creating Route53 record: ${K8S_API_DOMAIN} → ${API_ELB_DNS}"
aws route53 change-resource-record-sets \
  --hosted-zone-id "${ROUTE53_HOSTED_ZONE_ID}" \
  --change-batch "$(cat <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${K8S_API_DOMAIN}",
      "Type": "CNAME",
      "TTL": 60,
      "ResourceRecords": [{"Value": "${API_ELB_DNS}"}]
    }
  }]
}
EOF
)"

# Allow Route53 to propagate the new CNAME before the cluster is handed off
log "Waiting 15s for DNS propagation..."
sleep 15

# ── Wait for cluster to be healthy ────────────────────────────────────────────
# Use the raw NLB DNS here (not K8S_API_DOMAIN) — the API server cert SANs
# always include the NLB hostname, but only include K8S_API_DOMAIN if
# additionalSANs was applied correctly at cluster creation time.
#
# Two-stage wait:
# 1. Poll until the API server responds (NLB health check passes on TCP connect
#    before the API server has finished initializing TLS)
# 2. kubectl wait for nodes Ready (--all exits immediately if no nodes exist yet)
log "Waiting for API server to respond..."
ATTEMPTS=0
until kubectl get nodes &>/dev/null; do
  ATTEMPTS=$((ATTEMPTS + 1))
  [[ $ATTEMPTS -ge 40 ]] && fail "Timed out waiting for API server to respond (10 min)"
  sleep 15
done

log "Waiting for nodes to be Ready (~10 min)..."
# kubectl wait --all exits immediately with "no matching resources" if no nodes
# have registered yet. Poll until at least one node appears first.
ATTEMPTS=0
until kubectl get nodes --no-headers 2>/dev/null | grep -q .; do
  ATTEMPTS=$((ATTEMPTS + 1))
  [[ $ATTEMPTS -ge 40 ]] && fail "Timed out waiting for nodes to register (10 min)"
  sleep 15
done
kubectl wait --for=condition=Ready node --all --timeout=10m
log "Cluster is healthy."

# ── cert-manager ──────────────────────────────────────────────────────────────
log "Installing cert-manager..."
helm repo add jetstack https://charts.jetstack.io --force-update &>/dev/null
helm repo update &>/dev/null

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait \
  --timeout 5m

log "Applying Let's Encrypt ClusterIssuer..."
# Wait briefly for cert-manager webhook to be ready
sleep 15
kubectl apply -f "${ISSUER_MANIFEST}"

# ── CloudNativePG operator ────────────────────────────────────────────────────
log "Installing CloudNativePG operator..."
helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update &>/dev/null
helm repo update &>/dev/null

helm upgrade --install cnpg-operator cnpg/cloudnative-pg \
  --namespace cnpg-system \
  --create-namespace \
  --wait \
  --timeout 5m

# ── Create teleport namespace (needed for CNPG cluster CR) ────────────────────
kubectl create namespace teleport --dry-run=client -o yaml | kubectl apply -f -

# ── GHCR image pull secret ────────────────────────────────────────────────────
# postgres-wal2json is a private GHCR package; nodes need credentials to pull it.
# Uses the gh CLI token — refresh with: gh auth refresh --scopes write:packages
log "Creating GHCR pull secret..."
kubectl create secret docker-registry ghcr-pull-secret \
  --namespace teleport \
  --docker-server=ghcr.io \
  --docker-username=jturner-teleport \
  --docker-password="$(gh auth token)" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Access Graph: bootstrap in-cluster TLS via cert-manager self-signed CA ────
# Creates two secrets in the teleport namespace (asynchronously via cert-manager):
#   - access-graph-ca:  self-signed CA (mounted by teleport auth as ca.pem)
#   - access-graph-tls: TLS leaf for TAG's gRPC (mounted by TAG)
# We don't wait here; we'll poll for the secrets right before installing Teleport.
log "Bootstrapping Access Graph TLS via cert-manager self-signed Issuer..."
kubectl apply -f "${ROOT_DIR}/helm/access-graph-cert.yaml"

# ── Access Graph: Postgres credentials Secret for the 'access_graph' user ─────
# CNPG reads this Secret via spec.managed.roles[].passwordSecret to set the
# user's password on each cluster reconcile (including after recovery from S3
# backup, where the recovered DB has a stale hash). The same password is
# encoded in the access-graph-pg-uri Secret used by TAG.
#
# Idempotency: reuse the existing Secret's password if it's already there
# (e.g., on re-runs of `make up` or after a teleport namespace recovery).
# Generating a fresh password on every run would cause a window where TAG's
# in-flight uri Secret has a different password from the DB.
if EXISTING_PW=$(kubectl -n teleport get secret access-graph-pg-creds \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null) \
    && [[ -n "${EXISTING_PW}" ]]; then
  log "Reusing existing access-graph-pg-creds password."
  ACCESS_GRAPH_PG_PASSWORD="${EXISTING_PW}"
else
  log "Generating new access-graph-pg-creds password."
  ACCESS_GRAPH_PG_PASSWORD=$(openssl rand -hex 24)
fi
export ACCESS_GRAPH_PG_PASSWORD
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: access-graph-pg-creds
  namespace: teleport
  labels:
    cnpg.io/reload: "true"
type: kubernetes.io/basic-auth
stringData:
  username: access_graph
  password: "${ACCESS_GRAPH_PG_PASSWORD}"
EOF

# Grafana (in the monitoring namespace) needs the same credentials to mount the
# Access Graph Postgres datasource via envValueFrom — duplicate the secret there.
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: access-graph-pg-creds
  namespace: monitoring
type: kubernetes.io/basic-auth
stringData:
  username: access_graph
  password: "${ACCESS_GRAPH_PG_PASSWORD}"
EOF

# ── Detect CNPG bootstrap mode ────────────────────────────────────────────────
# If a base backup exists in S3 from a previous run, use recovery mode so
# Teleport's data (users, roles, audit events) is preserved across make down/up.
log "Checking S3 for existing CNPG base backup..."
BACKUP_EXISTS="false"
BACKUP_COUNT=$(aws s3 ls "s3://${TELEPORT_PG_WAL_BUCKET}/cnpg/teleport-postgres/base/" \
  --recursive 2>/dev/null | wc -l || echo "0")
BACKUP_COUNT="${BACKUP_COUNT//[[:space:]]/}"
if [[ "${BACKUP_COUNT:-0}" -gt 0 ]]; then
  BACKUP_EXISTS="true"
fi

if [[ "${BACKUP_EXISTS}" == "true" ]]; then
  log "Backup found (${BACKUP_COUNT} objects) — bootstrapping CNPG from S3 (recovery mode)..."
  kubectl apply -f "${CNPG_RECOVERY_MANIFEST}"
else
  log "No backup found — bootstrapping CNPG from scratch (initdb mode)..."
  kubectl apply -f "${CNPG_INITDB_MANIFEST}"
fi

# ── Wait for CNPG cluster to be ready ─────────────────────────────────────────
log "Waiting for PostgreSQL cluster to be ready (~5 min)..."
ATTEMPTS=0
until [[ "$(kubectl -n teleport get cluster teleport-postgres \
    -o jsonpath='{.status.readyInstances}' 2>/dev/null)" == "1" ]]; do
  ATTEMPTS=$((ATTEMPTS + 1))
  [[ $ATTEMPTS -ge 40 ]] && fail "Timed out waiting for CNPG cluster to be ready (10 min)"
  log "  (attempt ${ATTEMPTS}/40, retrying in 15s...)"
  sleep 15
done
log "PostgreSQL cluster is ready."

# ── Access Graph: create the access_graph database in CNPG ────────────────────
log "Creating access_graph database in CNPG..."
kubectl apply -f "${ROOT_DIR}/helm/cnpg-access-graph-db.yaml"
ATTEMPTS=0
until kubectl -n teleport get database/access-graph -o jsonpath='{.status.applied}' 2>/dev/null | grep -q true; do
  ATTEMPTS=$((ATTEMPTS + 1))
  [[ $ATTEMPTS -ge 24 ]] && fail "Timed out waiting for access-graph database to reconcile"
  sleep 5
done
log "access_graph database ready."

# ── Access Graph: postgres URI Secret used by TAG ─────────────────────────────
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: access-graph-pg-uri
  namespace: teleport
type: Opaque
stringData:
  uri: "postgres://access_graph:${ACCESS_GRAPH_PG_PASSWORD}@teleport-postgres-rw.teleport.svc.cluster.local:5432/access_graph?sslmode=require"
EOF

# ── Access Graph: wait for cert-manager to issue TLS secrets ──────────────────
log "Waiting for cert-manager to issue Access Graph TLS secrets..."
ATTEMPTS=0
until kubectl -n teleport get secret access-graph-ca >/dev/null 2>&1 && \
      kubectl -n teleport get secret access-graph-tls >/dev/null 2>&1; do
  ATTEMPTS=$((ATTEMPTS + 1))
  [[ $ATTEMPTS -ge 30 ]] && fail "Timed out waiting for Access Graph TLS secrets"
  sleep 5
done
log "Access Graph TLS secrets ready."

# ── Extract CNPG app password ──────────────────────────────────────────────────
# CNPG creates a secret named <cluster>-app containing the password for the
# app user (here: user 'teleport', db 'teleport'). This must be extracted
# before rendering teleport-values.yaml.tpl.
log "Extracting CNPG app password..."
CNPG_PASSWORD=$(kubectl -n teleport get secret teleport-postgres-app \
  -o jsonpath='{.data.password}' | base64 -d)
[[ -n "${CNPG_PASSWORD}" ]] || fail "Failed to extract CNPG password from teleport-postgres-app secret"
export CNPG_PASSWORD

# ── Render Teleport values (deferred: requires CNPG_PASSWORD) ─────────────────
envsubst < "${ROOT_DIR}/helm/teleport-values.yaml.tpl" > "${TELEPORT_VALUES}"

# ── Teleport Enterprise license ───────────────────────────────────────────────
log "Applying Enterprise license secret..."
LICENSE_FILE="${ROOT_DIR}/${TELEPORT_LICENSE_FILE:-license.pem}"
kubectl -n teleport create secret generic license \
  --from-file=license.pem="${LICENSE_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Google Workspace SA secret ────────────────────────────────────────────────
log "Creating Google SA secret..."
[[ -f "${ROOT_DIR}/${GOOGLE_SA_JSON_FILE}" ]] \
  || fail "Google SA JSON not found: ${GOOGLE_SA_JSON_FILE} — required for OIDC"
kubectl -n teleport create secret generic google-sa \
  --from-file=service-account.json="${ROOT_DIR}/${GOOGLE_SA_JSON_FILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Teleport ──────────────────────────────────────────────────────────────────
log "Installing Teleport..."
helm repo add teleport https://charts.releases.teleport.dev --force-update &>/dev/null
helm repo update &>/dev/null

helm upgrade --install teleport teleport/teleport-cluster \
  --namespace teleport \
  --create-namespace \
  --values "${TELEPORT_VALUES}" \
  --wait \
  --timeout 10m

unset CNPG_PASSWORD

# Defensive ClusterRoleBinding for the proxy pod's ServiceAccount.
# In standalone mode the auth pod runs kubernetes_service (not proxy), so the
# chart-managed binding is sufficient — this is kept for forward-compat.
kubectl apply -f "${ROOT_DIR}/helm/teleport-rbac.yaml"

# ── Demo namespaces ───────────────────────────────────────────────────────────
# Created to support RBAC role access via {{external.team}} trait.
for ns in admin engineering devops; do
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
done
log "Applying K8s RBAC bindings for team namespaces..."
kubectl apply -f "${ROOT_DIR}/teleport/k8s-rbac/namespace-bindings.yaml"

# ── Monitoring stack (kube-prometheus-stack) ──────────────────────────────────
log "Installing kube-prometheus-stack..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update &>/dev/null
helm repo update &>/dev/null

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --values "${ROOT_DIR}/helm/monitoring-values.yaml" \
  --wait \
  --timeout 10m

log "Applying Teleport ServiceMonitor..."
kubectl apply -f "${ROOT_DIR}/helm/teleport-servicemonitor.yaml"

log "Applying Teleport Grafana dashboards..."
# Upstream "Self-hosted Teleport Dashboard" (gravitational/teleport)
kubectl -n monitoring create configmap grafana-dashboard-teleport \
  --from-file=teleport-overview.json="${ROOT_DIR}/helm/grafana-dashboard-teleport.json" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring label configmap grafana-dashboard-teleport grafana_dashboard=1 --overwrite

# Custom dashboards (one ConfigMap per dashboard, picked up by Grafana sidecar
# via the grafana_dashboard=1 label). Submitted to gravitational/rev-tech.
for dash in "${ROOT_DIR}"/helm/dashboards/*.json; do
  [[ -f "${dash}" ]] || continue
  NAME="$(basename "${dash}" .json)"
  CM_NAME="grafana-dashboard-${NAME}"
  log "  Applying ${CM_NAME}..."
  kubectl -n monitoring create configmap "${CM_NAME}" \
    --from-file="${NAME}.json=${dash}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n monitoring label configmap "${CM_NAME}" grafana_dashboard=1 --overwrite >/dev/null
done

# ── Update Route53 DNS ────────────────────────────────────────────────────────
log "Waiting for LoadBalancer hostname..."
ELB_HOSTNAME=""
LB_ATTEMPTS=0
until [[ -n "${ELB_HOSTNAME}" ]]; do
  ELB_HOSTNAME=$(kubectl get svc teleport -n teleport \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -z "${ELB_HOSTNAME}" ]]; then
    LB_ATTEMPTS=$((LB_ATTEMPTS + 1))
    [[ $LB_ATTEMPTS -ge 30 ]] && fail "Timed out waiting for LoadBalancer hostname"
    sleep 10
  fi
done

log "LoadBalancer: ${ELB_HOSTNAME}"
log "Updating Route53 records..."

# Look up the ELB's canonical hosted zone ID (needed for ALIAS at the zone apex).
# Try ALB/NLB first, then fall back to Classic ELB.
ELB_ZONE_ID=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?DNSName=='${ELB_HOSTNAME}'].CanonicalHostedZoneId" \
  --output text 2>/dev/null || true)
if [[ -z "${ELB_ZONE_ID}" || "${ELB_ZONE_ID}" == "None" ]]; then
  ELB_ZONE_ID=$(aws elb describe-load-balancers \
    --query "LoadBalancerDescriptions[?DNSName=='${ELB_HOSTNAME}'].CanonicalHostedZoneNameID" \
    --output text 2>/dev/null || true)
fi

# Zone apex (TELEPORT_DOMAIN) cannot use CNAME — use Route53 ALIAS A record.
if [[ -n "${ELB_ZONE_ID}" && "${ELB_ZONE_ID}" != "None" ]]; then
  log "Creating ALIAS A record: ${TELEPORT_DOMAIN} → ${ELB_HOSTNAME} (zone ${ELB_ZONE_ID})"
  aws route53 change-resource-record-sets \
    --hosted-zone-id "${ROUTE53_HOSTED_ZONE_ID}" \
    --change-batch "$(cat <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${TELEPORT_DOMAIN}",
      "Type": "A",
      "AliasTarget": {
        "HostedZoneId": "${ELB_ZONE_ID}",
        "DNSName": "${ELB_HOSTNAME}",
        "EvaluateTargetHealth": false
      }
    }
  }]
}
EOF
)"
else
  log "WARNING: could not determine ELB hosted zone ID; skipping apex ALIAS record"
fi

# Wildcard subdomain can use a plain CNAME.
log "Creating CNAME: *.${TELEPORT_DOMAIN} → ${ELB_HOSTNAME}"
aws route53 change-resource-record-sets \
  --hosted-zone-id "${ROUTE53_HOSTED_ZONE_ID}" \
  --change-batch "$(cat <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "*.${TELEPORT_DOMAIN}",
      "Type": "CNAME",
      "TTL": 60,
      "ResourceRecords": [{"Value": "${ELB_HOSTNAME}"}]
    }
  }]
}
EOF
)"

# ── Apply Teleport config (SSO, RBAC, Login Rules) ────────────────────────────
log "Applying Teleport config..."
bash "${SCRIPT_DIR}/apply-teleport-config.sh"

# ── Access Graph (TAG) — Identity Security backend ────────────────────────────
# The auth pod's access_graph block (in helm/teleport-values.yaml.tpl) already
# points at the in-cluster TAG Service; auth was logging connection retries.
# Now extract Teleport's host CA, render TAG values, and helm-install TAG.
log "Extracting Teleport host CA for Access Graph trust..."
HOST_CA=$(kubectl -n teleport exec deploy/teleport-auth -c teleport -- \
  tctl get cert_authorities --format=json 2>/dev/null \
  | python3 -c '
import json, sys, base64
data = json.load(sys.stdin)
for ca in data:
    if ca.get("spec", {}).get("type") != "host":
        continue
    for keypair in ca["spec"].get("active_keys", {}).get("tls", []):
        cert_b64 = keypair.get("cert", "")
        if cert_b64:
            print(base64.b64decode(cert_b64).decode().rstrip())
            sys.exit(0)
')
[[ -n "${HOST_CA}" ]] || fail "Failed to extract Teleport host CA from auth pod"
# Indent each line by 4 spaces so it embeds cleanly under the YAML | block.
HOST_CA="$(echo "${HOST_CA}" | sed 's/^/    /')"
export HOST_CA

ACCESS_GRAPH_VALUES="${TMPDIR_WORK}/access-graph-values.yaml"
envsubst < "${ROOT_DIR}/helm/access-graph-values.yaml.tpl" > "${ACCESS_GRAPH_VALUES}"
unset HOST_CA ACCESS_GRAPH_PG_PASSWORD

log "Installing teleport-access-graph (Identity Security)..."
helm upgrade --install teleport-access-graph teleport/teleport-access-graph \
  --version 1.29.7 \
  --namespace teleport \
  --values "${ACCESS_GRAPH_VALUES}" \
  --wait \
  --timeout 5m

# ── Grafana app agent — registers Grafana behind Teleport's app_service ───────
# Apps appear at https://<app-name>.${TELEPORT_DOMAIN} after Google SSO.
log "Installing teleport-kube-agent (grafana-agent)..."
GRAFANA_AGENT_VALUES="${TMPDIR_WORK}/grafana-agent-values.yaml"
envsubst < "${ROOT_DIR}/helm/grafana-agent-values.yaml.tpl" > "${GRAFANA_AGENT_VALUES}"

helm upgrade --install grafana-agent teleport/teleport-kube-agent \
  --namespace teleport \
  --values "${GRAFANA_AGENT_VALUES}" \
  --wait \
  --timeout 5m

# ── Prometheus app agent — registers Prometheus UI behind Teleport's app_service ─
log "Installing teleport-kube-agent (prometheus-agent)..."
PROMETHEUS_AGENT_VALUES="${TMPDIR_WORK}/prometheus-agent-values.yaml"
envsubst < "${ROOT_DIR}/helm/prometheus-agent-values.yaml.tpl" > "${PROMETHEUS_AGENT_VALUES}"

helm upgrade --install prometheus-agent teleport/teleport-kube-agent \
  --namespace teleport \
  --values "${PROMETHEUS_AGENT_VALUES}" \
  --wait \
  --timeout 5m

# ── SSH node agent — Ubuntu container that joins as a Teleport SSH node ──────
# Demonstrates the role-ssh-access (auto-approved) + role-ssh-root-access
# (manual approval) escalation flow.
log "Deploying SSH node..."
envsubst < "${ROOT_DIR}/helm/ssh-node-deployment.yaml.tpl" | kubectl apply -f -

# ── tbot (Machine ID agent) ───────────────────────────────────────────────────
# tbot must be deployed before approval-bot: it creates the approval-bot-identity
# secret that the bot mounts. tbot renews the identity continuously so the bot
# never holds stale credentials.
log "Deploying tbot (Machine ID agent)..."
envsubst '${TELEPORT_DOMAIN} ${TELEPORT_VERSION}' \
  < "${ROOT_DIR}/helm/tbot-deployment.yaml" | kubectl apply -f -

# ── Approval bot ───────────────────────────────────────────────────────────────
log "Deploying approval bot..."
envsubst '${TELEPORT_DOMAIN}' < "${ROOT_DIR}/helm/approval-bot-deployment.yaml" | kubectl apply -f -

# ── Done ───────────────────────────────────────────────────────────────────────
log ""
unset AWS_CONFIG_FILE
log "Teleport is ready at: https://${TELEPORT_DOMAIN}"
log ""
log "Create your first admin user (1/2 — invitation + standard traits):"
log "  kubectl -n teleport exec deploy/teleport-auth -- tctl users add admin \\"
log "    --roles=access,editor,auditor \\"
log "    --logins=ubuntu,root \\"
log "    --kubernetes-groups=system:masters"
log ""
log "Create your first admin user (2/2 — add email trait for Grafana app SSO):"
log "  kubectl -n teleport exec deploy/teleport-auth -i -- tctl create -f - --force <<'EOF'"
log "    kind: user"
log "    version: v2"
log "    metadata: {name: admin}"
log "    spec:"
log "      roles: [access, editor, auditor]"
log "      traits:"
log "        logins: [ubuntu, root]"
log "        kubernetes_groups: [system:masters]"
log "        email: [admin@${TELEPORT_DOMAIN#teleport.}]"
log "  EOF"
log ""
log "  (logins + kubernetes-groups enable SSH + kubectl. email enables auto-SSO"
log "   into Grafana's app_service via X-WEBAUTH-USER={{external.email}}.)"
log ""
log "kubectl is configured to use the NLB DNS directly."
log "To switch to the friendly hostname (requires k8s.${TELEPORT_DOMAIN} in cert SANs):"
log "  kubectl config set-cluster ${CLUSTER_NAME} --server=https://${K8S_API_DOMAIN}"
log ""
log "To pause (scale workers to 0):  make pause"
log "To tear down:                   make down"
