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

if [[ -z "${AWS_ACCOUNT_ID:-}" ]]; then
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  export AWS_ACCOUNT_ID
fi

AWS_AZ="${AWS_AZ:-${AWS_REGION}a}"
export AWS_AZ

K8S_API_DOMAIN="${K8S_API_DOMAIN:-k8s.${TELEPORT_DOMAIN}}"
export K8S_API_DOMAIN

log "Cluster : ${CLUSTER_NAME}"
log "Account : ${AWS_ACCOUNT_ID}"
log "Region  : ${AWS_REGION}"
log "Domain  : ${TELEPORT_DOMAIN}"

# ── Temp files (cleaned up on exit) ───────────────────────────────────────────
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "${TMPDIR_WORK}"' EXIT

CLUSTER_MANIFEST="${TMPDIR_WORK}/cluster.yaml"
ISSUER_MANIFEST="${TMPDIR_WORK}/issuer.yaml"
TELEPORT_VALUES="${TMPDIR_WORK}/teleport-values.yaml"

envsubst < "${ROOT_DIR}/kops/cluster.yaml.tpl"                > "${CLUSTER_MANIFEST}"
envsubst < "${ROOT_DIR}/helm/cert-manager-issuer.yaml.tpl"    > "${ISSUER_MANIFEST}"
envsubst < "${ROOT_DIR}/helm/teleport-values.yaml.tpl"        > "${TELEPORT_VALUES}"

# ── Create kops cluster (skip if already exists) ───────────────────────────────
if kops get cluster --name="${CLUSTER_NAME}" --state="${KOPS_STATE_STORE}" &>/dev/null; then
  log "Cluster config already exists in state store, skipping create."
else
  log "Creating kops cluster configuration..."
  kops create -f "${CLUSTER_MANIFEST}" --state="${KOPS_STATE_STORE}"

  log "Adding SSH public key..."
  kops create secret sshpublickey admin \
    --name="${CLUSTER_NAME}" \
    --state="${KOPS_STATE_STORE}" \
    -i "${KOPS_SSH_PUBLIC_KEY}"
fi

# ── Provision AWS infrastructure ───────────────────────────────────────────────
log "Provisioning infrastructure (~5 min)..."
kops update cluster \
  --name="${CLUSTER_NAME}" \
  --state="${KOPS_STATE_STORE}" \
  --yes \
  --admin

# ── Re-export kubeconfig once the API server ELB endpoint is registered ────────
# kops update exports the kubeconfig immediately, before the ELB exists.
# With gossip DNS (.k8s.local) the fallback hostname doesn't resolve externally,
# so we poll until kops can write a kubeconfig with a real endpoint.
log "Waiting for API server endpoint to be registered..."
ATTEMPTS=0
until kops export kubeconfig \
    --name="${CLUSTER_NAME}" \
    --state="${KOPS_STATE_STORE}" \
    --admin 2>&1 | grep -qv "no external API endpoints"; do
  ATTEMPTS=$((ATTEMPTS + 1))
  [[ $ATTEMPTS -ge 24 ]] && fail "Timed out waiting for API server endpoint (6 min)"
  sleep 15
done

# ── Wait for cluster to be healthy ────────────────────────────────────────────
log "Waiting for cluster to be ready (~10 min)..."
kops validate cluster \
  --name="${CLUSTER_NAME}" \
  --state="${KOPS_STATE_STORE}" \
  --wait 15m

log "Cluster is healthy."

# ── K8S API custom domain ──────────────────────────────────────────────────────
# Extract the API ELB hostname from the kubeconfig, point the custom domain at
# it, then update the kubeconfig server so kubectl uses the friendly hostname.
API_ELB=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' \
  | sed 's|https://||; s|:443||')

log "Creating Route53 record: ${K8S_API_DOMAIN} → ${API_ELB}"
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
      "ResourceRecords": [{"Value": "${API_ELB}"}]
    }
  }]
}
EOF
)"

log "Updating kubeconfig to use ${K8S_API_DOMAIN}..."
kubectl config set-cluster "${CLUSTER_NAME}" --server="https://${K8S_API_DOMAIN}"

# ── cert-manager ──────────────────────────────────────────────────────────────
log "Installing cert-manager..."
helm repo add jetstack https://charts.jetstack.io --force-update &>/dev/null
helm repo update &>/dev/null

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --wait \
  --timeout 5m

log "Applying Let's Encrypt ClusterIssuer..."
# Wait briefly for cert-manager webhook to be ready
sleep 15
kubectl apply -f "${ISSUER_MANIFEST}"

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

# ── Update Route53 DNS ────────────────────────────────────────────────────────
log "Waiting for LoadBalancer hostname..."
ELB_HOSTNAME=""
ATTEMPTS=0
until [[ -n "${ELB_HOSTNAME}" ]]; do
  ELB_HOSTNAME=$(kubectl get svc teleport -n teleport \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -z "${ELB_HOSTNAME}" ]]; then
    ATTEMPTS=$((ATTEMPTS + 1))
    [[ $ATTEMPTS -ge 30 ]] && fail "Timed out waiting for LoadBalancer hostname"
    sleep 10
  fi
done

log "LoadBalancer: ${ELB_HOSTNAME}"
log "Updating Route53 records..."

for RECORD in "${TELEPORT_DOMAIN}" "*.${TELEPORT_DOMAIN}"; do
  aws route53 change-resource-record-sets \
    --hosted-zone-id "${ROUTE53_HOSTED_ZONE_ID}" \
    --change-batch "$(cat <<EOF
{
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "${RECORD}",
      "Type": "CNAME",
      "TTL": 60,
      "ResourceRecords": [{"Value": "${ELB_HOSTNAME}"}]
    }
  }]
}
EOF
)"
done

# ── Done ───────────────────────────────────────────────────────────────────────
log ""
unset AWS_CONFIG_FILE
log "Teleport is ready at: https://${TELEPORT_DOMAIN}"
log ""
log "Create your first admin user:"
log "  kubectl -n teleport exec deploy/teleport -- tctl users add admin --roles=access,editor,auditor"
log ""
log "To pause (scale workers to 0):  make pause"
log "To tear down:                   make down"
