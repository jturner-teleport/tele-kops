#!/usr/bin/env bash
# spin-down.sh — Remove the kops cluster. DynamoDB tables and S3 buckets are
# preserved so data survives and the cluster can be recreated with make up.
# Run: make down
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
source "${ROOT_DIR}/config.env"

log()  { echo "[spin-down] $*"; }
fail() { echo "[spin-down] ERROR: $*" >&2; exit 1; }

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

K8S_API_DOMAIN="${K8S_API_DOMAIN:-k8s.${TELEPORT_DOMAIN}}"

# ── Remove K8S API Route53 record ──────────────────────────────────────────────
log "Removing Route53 record: ${K8S_API_DOMAIN}"
EXISTING=$(aws route53 list-resource-record-sets \
  --hosted-zone-id "${ROUTE53_HOSTED_ZONE_ID}" \
  --query "ResourceRecordSets[?Name=='${K8S_API_DOMAIN}.']" \
  --output json 2>/dev/null)
if [[ "${EXISTING}" != "[]" && -n "${EXISTING}" ]]; then
  aws route53 change-resource-record-sets \
    --hosted-zone-id "${ROUTE53_HOSTED_ZONE_ID}" \
    --change-batch "$(echo "${EXISTING}" | python3 -c "
import json, sys
records = json.load(sys.stdin)
print(json.dumps({'Changes': [{'Action': 'DELETE', 'ResourceRecordSet': r} for r in records]}))
")" 2>/dev/null || true
fi

# ── Export kubeconfig (needed so helm/kubectl can reach the cluster) ───────────
log "Exporting kubeconfig..."
kops export kubeconfig \
  --name="${CLUSTER_NAME}" \
  --state="${KOPS_STATE_STORE}" \
  --admin 2>/dev/null || true

# ── Uninstall Helm releases ────────────────────────────────────────────────────
log "Uninstalling Teleport..."
helm uninstall teleport --namespace teleport 2>/dev/null || true

log "Uninstalling cert-manager..."
helm uninstall cert-manager --namespace cert-manager 2>/dev/null || true

log "Waiting for namespaces to terminate..."
kubectl delete namespace teleport --ignore-not-found --wait=true 2>/dev/null || true
kubectl delete namespace cert-manager --ignore-not-found --wait=true 2>/dev/null || true

# ── Delete kops cluster ────────────────────────────────────────────────────────
log "Deleting kops cluster: ${CLUSTER_NAME}"
kops delete cluster \
  --name="${CLUSTER_NAME}" \
  --state="${KOPS_STATE_STORE}" \
  --yes

log ""
log "Cluster deleted."
log "Preserved: DynamoDB tables (${TELEPORT_BACKEND_TABLE}, ${TELEPORT_EVENTS_TABLE})"
log "Preserved: S3 bucket (${TELEPORT_SESSIONS_BUCKET})"
log ""
unset AWS_CONFIG_FILE
log "Spin back up any time with: make up"
