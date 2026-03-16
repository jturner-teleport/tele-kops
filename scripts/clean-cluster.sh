#!/usr/bin/env bash
# clean-cluster.sh — Force-delete kops cluster EC2 resources without touching
# DynamoDB or S3. Use when orphaned EBS volumes or other AWS state prevent
# make up from completing cleanly. Safe to re-run; make up works afterwards.
# Run: make clean-cluster
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
source "${ROOT_DIR}/config.env"

log()  { echo "[clean-cluster] $*"; }
fail() { echo "[clean-cluster] ERROR: $*" >&2; exit 1; }

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

# ── Delete kops cluster (EC2 resources only) ───────────────────────────────────
log "Deleting kops cluster: ${CLUSTER_NAME}"
log "DynamoDB and S3 data will be preserved."
kops delete cluster \
  --name="${CLUSTER_NAME}" \
  --state="${KOPS_STATE_STORE}" \
  --yes

log ""
unset AWS_CONFIG_FILE
log "Cluster resources deleted. Run: make up"
