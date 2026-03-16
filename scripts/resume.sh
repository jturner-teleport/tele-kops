#!/usr/bin/env bash
# resume.sh — Scale workers back up. Pods reschedule in ~2-3 minutes.
# Run: make resume
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
source "${ROOT_DIR}/config.env"

log()  { echo "[resume] $*"; }
fail() { echo "[resume] ERROR: $*" >&2; exit 1; }

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

AWS_AZ="${AWS_AZ:-${AWS_REGION}a}"

log "Scaling workers back to min=${WORKER_MIN} max=${WORKER_MAX}..."

TMPFILE=$(mktemp)
PATCHED=$(mktemp)
trap 'rm -f "${TMPFILE}" "${PATCHED}"' EXIT

kops get instancegroup "nodes-${AWS_AZ}" \
  --name="${CLUSTER_NAME}" \
  --state="${KOPS_STATE_STORE}" \
  -o yaml > "${TMPFILE}"

sed "s/minSize:.*/minSize: ${WORKER_MIN}/" "${TMPFILE}" \
  | sed "s/maxSize:.*/maxSize: ${WORKER_MAX}/" > "${PATCHED}"

kops replace --state="${KOPS_STATE_STORE}" -f "${PATCHED}"

kops update cluster \
  --name="${CLUSTER_NAME}" \
  --state="${KOPS_STATE_STORE}" \
  --yes

kops rolling-update cluster \
  --name="${CLUSTER_NAME}" \
  --state="${KOPS_STATE_STORE}" \
  --yes

unset AWS_CONFIG_FILE
log "Workers scaling up. Teleport pods will reschedule in ~2-3 minutes."
log "Check status: kubectl get pods -n teleport"
