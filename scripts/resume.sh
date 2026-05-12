#!/usr/bin/env bash
# resume.sh — Scale workers back up. Pods reschedule in ~2-3 minutes.
# Uses the ASG directly — avoids kops update and the EBS Encrypted conflict.
# Run: make resume
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
source "${ROOT_DIR}/config.env"

log()  { echo "[resume] $*"; }
fail() { echo "[resume] ERROR: $*" >&2; exit 1; }

if [[ -n "${AWS_PROFILE:-}" ]]; then
  CREDS=$(aws configure export-credentials --profile "${AWS_PROFILE}" --format env 2>/dev/null) \
    || fail "AWS SSO session expired or invalid. Run: aws sso login --sso-session gravitational"
  eval "${CREDS}"
  unset AWS_PROFILE
  export AWS_CONFIG_FILE=/dev/null
fi

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

AWS_AZ="${AWS_AZ:-${AWS_REGION}a}"
IG_NAME="nodes-${AWS_AZ}"

# Find the worker ASG by its kops instance group tag.
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups \
  --filters "Name=tag:kops.k8s.io/instancegroup,Values=${IG_NAME}" \
            "Name=tag:KubernetesCluster,Values=${CLUSTER_NAME}" \
  --query 'AutoScalingGroups[0].AutoScalingGroupName' \
  --output text 2>/dev/null || true)

[[ -z "${ASG_NAME}" || "${ASG_NAME}" == "None" ]] \
  && fail "Could not find ASG for instance group ${IG_NAME} in cluster ${CLUSTER_NAME}"

log "Scaling ${ASG_NAME} to min=${WORKER_MIN} max=${WORKER_MAX}..."
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "${ASG_NAME}" \
  --min-size "${WORKER_MIN}" \
  --max-size "${WORKER_MAX}"

# Tag AFTER scaling so paused intent persists if the scale call fails.
log "Tagging ${ASG_NAME} teleport.dev/state=running..."
aws autoscaling create-or-update-tags --tags \
  "ResourceId=${ASG_NAME},ResourceType=auto-scaling-group,Key=teleport.dev/state,Value=running,PropagateAtLaunch=false"

unset AWS_CONFIG_FILE
log "Workers scaling up. Teleport pods will reschedule in ~2-3 minutes."
log "Check status: kubectl get pods -n teleport"
