#!/usr/bin/env bash
# spin-down.sh — Remove the kops cluster. S3 buckets are preserved so data
# survives and the cluster can be recreated with make up.
# Triggers a CNPG base backup before teardown so Postgres state is safe.
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

# ── Export kubeconfig (needed so kubectl/helm can reach the cluster) ───────────
log "Exporting kubeconfig..."
kops export kubeconfig \
  --name="${CLUSTER_NAME}" \
  --state="${KOPS_STATE_STORE}" \
  --admin 2>/dev/null || true

# ── Trigger CNPG base backup before cluster teardown ──────────────────────────
# This ensures the latest Postgres state is safely in S3 before we destroy nodes.
# spin-up.sh detects this backup on next run and bootstraps via recovery instead of initdb.
BACKUP_NAME="pre-teardown-$(date +%Y%m%d%H%M%S)"
if kubectl -n teleport get cluster teleport-postgres &>/dev/null 2>&1; then
  log "Triggering CNPG base backup: ${BACKUP_NAME}"
  kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${BACKUP_NAME}
  namespace: teleport
spec:
  method: barmanObjectStore
  cluster:
    name: teleport-postgres
EOF

  log "Waiting for backup to complete (up to 5 min)..."
  ATTEMPTS=0
  while true; do
    BACKUP_PHASE=$(kubectl -n teleport get backup "${BACKUP_NAME}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${BACKUP_PHASE}" == "completed" ]]; then
      log "Backup completed."
      break
    elif [[ "${BACKUP_PHASE}" == "failed" ]]; then
      log "WARNING: Backup entered failed state — data may not be in S3. Proceeding with teardown."
      break
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    if [[ $ATTEMPTS -ge 30 ]]; then
      log "WARNING: Backup timed out after 5 min — proceeding with teardown."
      break
    fi
    log "  (attempt ${ATTEMPTS}/30, retrying in 10s...)"
    sleep 10
  done
else
  log "No CNPG cluster found — skipping backup."
fi

# ── Remove K8S API Route53 record ──────────────────────────────────────────────
log "Removing Route53 record: ${K8S_API_DOMAIN}"
EXISTING=$(aws route53 list-resource-record-sets \
  --hosted-zone-id "${ROUTE53_HOSTED_ZONE_ID}" \
  --query "ResourceRecordSets[?Name=='${K8S_API_DOMAIN}.']" \
  --output json 2>/dev/null)
if [[ "${EXISTING}" != "[]" && -n "${EXISTING}" ]]; then
  CHANGE_BATCH=$(echo "${EXISTING}" | python3 -c '
import json, sys
records = json.load(sys.stdin)
print(json.dumps({"Changes": [{"Action": "DELETE", "ResourceRecordSet": r} for r in records]}))
')
  aws route53 change-resource-record-sets \
    --hosted-zone-id "${ROUTE53_HOSTED_ZONE_ID}" \
    --change-batch "${CHANGE_BATCH}" 2>/dev/null || true
fi

# ── Uninstall monitoring stack ────────────────────────────────────────────────
log "Uninstalling monitoring stack..."
helm uninstall monitoring --namespace monitoring 2>/dev/null || true
kubectl delete namespace monitoring --ignore-not-found --wait=false 2>/dev/null || true

# ── Uninstall Access Graph + Grafana app agent ───────────────────────────────
# These depend on the main teleport release (auth/proxy services), so uninstall
# first. Namespace deletion below would clean them up too, but explicit uninstall
# runs the chart's pre-delete hooks and lets connections drain.
log "Uninstalling teleport-access-graph..."
helm uninstall teleport-access-graph --namespace teleport 2>/dev/null || true
log "Uninstalling grafana-agent (teleport-kube-agent)..."
helm uninstall grafana-agent --namespace teleport 2>/dev/null || true
log "Uninstalling prometheus-agent (teleport-kube-agent)..."
helm uninstall prometheus-agent --namespace teleport 2>/dev/null || true
log "Removing SSH node deployment..."
kubectl -n teleport delete deployment/ssh-node configmap/ssh-node-config sa/ssh-node podmonitor/ssh-node --ignore-not-found 2>/dev/null || true

# ── Uninstall Teleport ────────────────────────────────────────────────────────
log "Uninstalling Teleport..."
helm uninstall teleport --namespace teleport 2>/dev/null || true

# ── Remove CNPG cluster CR ────────────────────────────────────────────────────
log "Removing CNPG cluster..."
kubectl -n teleport delete cluster teleport-postgres --ignore-not-found 2>/dev/null || true

# ── Uninstall CNPG operator ───────────────────────────────────────────────────
log "Uninstalling CloudNativePG operator..."
helm uninstall cnpg-operator --namespace cnpg-system 2>/dev/null || true

# ── Uninstall cert-manager ────────────────────────────────────────────────────
log "Uninstalling cert-manager..."
helm uninstall cert-manager --namespace cert-manager 2>/dev/null || true

log "Waiting for namespaces to terminate..."
kubectl delete namespace teleport --ignore-not-found --wait=true 2>/dev/null || true
kubectl delete namespace cnpg-system --ignore-not-found --wait=true 2>/dev/null || true
kubectl delete namespace cert-manager --ignore-not-found --wait=true 2>/dev/null || true

# ── Delete kops cluster ────────────────────────────────────────────────────────
log "Deleting kops cluster: ${CLUSTER_NAME}"
kops delete cluster \
  --name="${CLUSTER_NAME}" \
  --state="${KOPS_STATE_STORE}" \
  --yes

log ""
log "Cluster deleted."
log "Preserved: S3 buckets (${TELEPORT_SESSIONS_BUCKET}, ${TELEPORT_PG_WAL_BUCKET})"
log "  PostgreSQL state is safe in ${TELEPORT_PG_WAL_BUCKET}/cnpg/"
log ""
unset AWS_CONFIG_FILE
log "Spin back up any time with: make up"
