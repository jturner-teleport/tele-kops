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

# ── Clean up orphaned EBS volumes from any previous failed run ────────────────
# If kops update was interrupted, etcd EBS volumes may be left in 'available'
# (detached) state. kops cannot change their encryption field on retry, causing
# "Field cannot be changed: Encrypted". Safe to delete: healthy clusters have
# their volumes in 'in-use' state (attached to the master).
ORPHANED_VOLS=$(aws ec2 describe-volumes \
  --filters \
    "Name=tag:KubernetesCluster,Values=${CLUSTER_NAME}" \
    "Name=status,Values=available" \
  --query 'Volumes[*].VolumeId' \
  --output text 2>/dev/null || true)
if [[ -n "${ORPHANED_VOLS}" ]]; then
  log "Found orphaned EBS volumes from a previous run — deleting before provisioning..."
  for vol in ${ORPHANED_VOLS}; do
    log "  Deleting volume: ${vol}"
    aws ec2 delete-volume --volume-id "${vol}"
  done
fi

# ── Provision AWS infrastructure ───────────────────────────────────────────────
log "Provisioning infrastructure (~5 min)..."
kops update cluster \
  --name="${CLUSTER_NAME}" \
  --state="${KOPS_STATE_STORE}" \
  --yes \
  --admin

# ── Fix ELB health check (SSL→TCP) ────────────────────────────────────────────
# kops creates the Classic ELB with an SSL:443 health check. Kubernetes 1.30+
# dropped support for the TLS ciphers/versions used by the Classic ELB health
# checker, so it never flips InService. TCP:443 just verifies TCP connectivity.
API_ELB_NAME=$(aws elb describe-load-balancers \
  --query "LoadBalancerDescriptions[?contains(LoadBalancerName,'api-${PREFIX}')].LoadBalancerName" \
  --output text 2>/dev/null || true)
if [[ -n "${API_ELB_NAME}" ]]; then
  log "Patching ELB health check to TCP:443 (SSL incompatible with k8s 1.30+)..."
  aws elb configure-health-check \
    --load-balancer-name "${API_ELB_NAME}" \
    --health-check "Target=TCP:443,Interval=10,Timeout=5,UnhealthyThreshold=2,HealthyThreshold=2" \
    > /dev/null
fi

# ── Wait for API ELB to be InService, then patch kubeconfig directly ───────────
# kops export kubeconfig checks for InService ELB instances but reliably fails
# to detect them from within this script. Instead, poll AWS directly and set
# the kubeconfig server ourselves — kops update already wrote the correct CA.
log "Waiting for API server ELB to be InService..."
ATTEMPTS=0
API_ELB_DNS=""
while true; do
  LB_INFO=$(aws elb describe-load-balancers \
    --query "LoadBalancerDescriptions[?contains(LoadBalancerName,'api-${PREFIX}')].[LoadBalancerName,DNSName]" \
    --output text 2>/dev/null || true)
  if [[ -n "${LB_INFO}" ]]; then
    API_ELB_NAME=$(echo "${LB_INFO}" | awk '{print $1}')
    API_ELB_DNS=$(echo "${LB_INFO}" | awk '{print $2}')
    HEALTHY=$(aws elb describe-instance-health \
      --load-balancer-name "${API_ELB_NAME}" \
      --query 'InstanceStates[?State==`InService`].InstanceId' \
      --output text 2>/dev/null || true)
    if [[ -n "${HEALTHY}" ]]; then
      log "API server ELB InService: ${API_ELB_DNS}"
      kubectl config set-cluster "${CLUSTER_NAME}" --server="https://${API_ELB_DNS}"
      break
    fi
  fi
  ATTEMPTS=$((ATTEMPTS + 1))
  [[ $ATTEMPTS -ge 36 ]] && fail "Timed out waiting for API server ELB to be InService (9 min)"
  log "  (attempt ${ATTEMPTS}/36, retrying in 15s...)"
  sleep 15
done

# ── K8S API custom domain ──────────────────────────────────────────────────────
# Extract the API ELB hostname from the kubeconfig, create the Route53 CNAME,
# then patch the kubeconfig to use the friendly hostname. Done before kubectl
# wait so all subsequent kubectl calls use the custom domain, not the raw ELB.
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

# Allow Route53 to propagate the new CNAME before kubectl tries to resolve it
log "Waiting 15s for DNS propagation..."
sleep 15

# ── Wait for cluster to be healthy ────────────────────────────────────────────
# Use kubectl directly — kops validate re-exports the kubeconfig internally and
# falls back to gossip DNS. kubectl wait uses the kubeconfig we just patched to
# use K8S_API_DOMAIN, so all validation traffic goes through the custom domain.
log "Waiting for nodes to be Ready (~10 min)..."
kubectl wait --for=condition=Ready nodes --all --timeout=10m
log "Cluster is healthy."

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
