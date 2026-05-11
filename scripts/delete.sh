#!/usr/bin/env bash
# delete.sh — Nuclear teardown: removes the cluster AND all persistent data.
# This deletes all S3 buckets — all Teleport state, audit logs,
# and session recordings will be permanently lost.
# Run: make delete
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
source "${ROOT_DIR}/config.env"

log()  { echo "[delete] $*"; }
fail() { echo "[delete] ERROR: $*" >&2; exit 1; }

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
if [[ -z "${AWS_ACCOUNT_ID:-}" ]]; then
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
fi
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

# ── Confirmation prompt ────────────────────────────────────────────────────────
echo ""
echo "  ┌──────────────────────────────────────────────────────────────┐"
echo "  │  !! NUCLEAR TEARDOWN !!                                      │"
echo "  │                                                              │"
echo "  │  Permanently deletes:                                        │"
echo "  │    • kops cluster (EC2, VPC, NLB, security groups)          │"
echo "  │    • S3: ${KOPS_STATE_BUCKET}"
echo "  │    • S3: ${TELEPORT_SESSIONS_BUCKET}"
echo "  │    • S3: ${TELEPORT_PG_WAL_BUCKET}  (Postgres WAL + backups)"
echo "  │    • IAC: S3 ${TELEPORT_IAC_LONG_TERM_BUCKET}"
echo "  │    • IAC: S3 ${TELEPORT_IAC_TRANSIENT_BUCKET}"
echo "  │    • IAC: Glue, Athena WG, SQS, KMS (7-day delete window)   │"
echo "  │                                                              │"
echo "  │  All Teleport users, roles, audit logs, and session          │"
echo "  │  recordings will be PERMANENTLY lost.                        │"
echo "  └──────────────────────────────────────────────────────────────┘"
echo ""
read -r -p "  Type the cluster name to confirm (${CLUSTER_NAME}): " CONFIRM
echo ""

[[ "${CONFIRM}" == "${CLUSTER_NAME}" ]] || fail "Cluster name did not match. Aborting."

# ── Helper: delete a versioned S3 bucket ──────────────────────────────────────
delete_bucket() {
  local bucket="$1"

  if ! aws s3api head-bucket --bucket "${bucket}" 2>/dev/null; then
    log "  Bucket not found, skipping: ${bucket}"
    return 0
  fi

  log "  Removing all versions from: ${bucket}"

  # Delete all object versions in batches of 500
  while true; do
    local versions
    versions=$(aws s3api list-object-versions \
      --bucket "${bucket}" --max-items 500 \
      --query 'Versions[].{Key:Key,VersionId:VersionId}' \
      --output json 2>/dev/null)
    [[ "${versions}" == "null" || "${versions}" == "[]" ]] && break
    aws s3api delete-objects \
      --bucket "${bucket}" \
      --delete "{\"Objects\":${versions}}" >/dev/null
  done

  # Delete all delete markers in batches of 500
  while true; do
    local markers
    markers=$(aws s3api list-object-versions \
      --bucket "${bucket}" --max-items 500 \
      --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' \
      --output json 2>/dev/null)
    [[ "${markers}" == "null" || "${markers}" == "[]" ]] && break
    aws s3api delete-objects \
      --bucket "${bucket}" \
      --delete "{\"Objects\":${markers}}" >/dev/null
  done

  log "  Deleting bucket: ${bucket}"
  aws s3api delete-bucket \
    --bucket "${bucket}" \
    --region "${AWS_REGION}" 2>/dev/null || true
}

# ── Step 1: Export kubeconfig and uninstall Helm releases ─────────────────────
log "Step 1/4: Removing Helm releases..."
kops export kubeconfig \
  --name="${CLUSTER_NAME}" \
  --state="${KOPS_STATE_STORE}" \
  --admin 2>/dev/null || true

helm uninstall teleport --namespace teleport 2>/dev/null || true
helm uninstall cnpg-operator --namespace cnpg-system 2>/dev/null || true
helm uninstall cert-manager --namespace cert-manager 2>/dev/null || true

kubectl delete namespace teleport --ignore-not-found --wait=true 2>/dev/null || true
kubectl delete namespace cnpg-system --ignore-not-found --wait=true 2>/dev/null || true
kubectl delete namespace cert-manager --ignore-not-found --wait=true 2>/dev/null || true

# ── Step 2: Tear down the kops cluster ────────────────────────────────────────
log "Step 2/4: Deleting kops cluster: ${CLUSTER_NAME}"
kops delete cluster \
  --name="${CLUSTER_NAME}" \
  --state="${KOPS_STATE_STORE}" \
  --yes || true

# ── Step 3: Delete S3 buckets ─────────────────────────────────────────────────
log "Step 3/4: Deleting S3 buckets..."
delete_bucket "${KOPS_STATE_BUCKET}"
delete_bucket "${TELEPORT_SESSIONS_BUCKET}"
delete_bucket "${TELEPORT_PG_WAL_BUCKET}"

# ── Step 4: Tear down Identity Activity Center resources ──────────────────────
# Order matters: empty + delete S3 buckets first, then table → database (can't
# drop a database that still has tables), then workgroup, then SQS, then KMS.
# Each step is best-effort: delete.sh is "nuke from orbit" — keep going on errors.
log "Step 4/4: Deleting Identity Activity Center resources..."
delete_bucket "${TELEPORT_IAC_LONG_TERM_BUCKET}"
delete_bucket "${TELEPORT_IAC_TRANSIENT_BUCKET}"

log "  Deleting Glue table: ${TELEPORT_IAC_GLUE_TABLE}"
aws glue delete-table \
  --database-name "${TELEPORT_IAC_GLUE_DB}" \
  --name "${TELEPORT_IAC_GLUE_TABLE}" 2>/dev/null || true

log "  Deleting Glue database: ${TELEPORT_IAC_GLUE_DB}"
aws glue delete-database --name "${TELEPORT_IAC_GLUE_DB}" 2>/dev/null || true

log "  Deleting Athena workgroup: ${TELEPORT_IAC_WORKGROUP}"
aws athena delete-work-group \
  --work-group "${TELEPORT_IAC_WORKGROUP}" \
  --recursive-delete-option 2>/dev/null || true

for q in "${TELEPORT_IAC_SQS_QUEUE}" "${TELEPORT_IAC_SQS_DLQ}"; do
  QUEUE_URL=$(aws sqs get-queue-url --queue-name "${q}" --query QueueUrl --output text 2>/dev/null || true)
  if [[ -n "${QUEUE_URL}" && "${QUEUE_URL}" != "None" ]]; then
    log "  Deleting SQS queue: ${q}"
    aws sqs delete-queue --queue-url "${QUEUE_URL}" 2>/dev/null || true
  fi
done

# KMS keys cannot be deleted immediately — schedule deletion with the minimum
# 7-day window. Alias must be removed before scheduling.
KMS_KEY_ID=$(aws kms describe-key \
  --key-id "alias/${TELEPORT_IAC_KMS_ALIAS}" \
  --query 'KeyMetadata.KeyId' --output text 2>/dev/null || true)
if [[ -n "${KMS_KEY_ID}" && "${KMS_KEY_ID}" != "None" ]]; then
  log "  Deleting KMS alias: ${TELEPORT_IAC_KMS_ALIAS}"
  aws kms delete-alias --alias-name "alias/${TELEPORT_IAC_KMS_ALIAS}" 2>/dev/null || true
  log "  Scheduling KMS key deletion (7-day window): ${KMS_KEY_ID}"
  aws kms schedule-key-deletion \
    --key-id "${KMS_KEY_ID}" \
    --pending-window-in-days 7 2>/dev/null || true
fi

# ── Done ───────────────────────────────────────────────────────────────────────
unset AWS_CONFIG_FILE
log ""
log "Nuclear teardown complete. All resources deleted."
log "  Deleted: S3 buckets (${KOPS_STATE_BUCKET}, ${TELEPORT_SESSIONS_BUCKET}, ${TELEPORT_PG_WAL_BUCKET})"
log "  Deleted IAC: S3 (${TELEPORT_IAC_LONG_TERM_BUCKET}, ${TELEPORT_IAC_TRANSIENT_BUCKET}),"
log "    Glue (${TELEPORT_IAC_GLUE_DB}.${TELEPORT_IAC_GLUE_TABLE}),"
log "    Athena workgroup (${TELEPORT_IAC_WORKGROUP}),"
log "    SQS (${TELEPORT_IAC_SQS_QUEUE}, ${TELEPORT_IAC_SQS_DLQ}),"
log "    KMS scheduled for deletion in 7 days (alias/${TELEPORT_IAC_KMS_ALIAS})"
log "To start fresh: make bootstrap && make up"
