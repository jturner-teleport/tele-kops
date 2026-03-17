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

# Look up the NLB's canonical hosted zone ID (needed for ALIAS at the zone apex).
ELB_ZONE_ID=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?DNSName=='${ELB_HOSTNAME}'].CanonicalHostedZoneId" \
  --output text 2>/dev/null || true)

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

# ── Done ───────────────────────────────────────────────────────────────────────
log ""
unset AWS_CONFIG_FILE
log "Teleport is ready at: https://${TELEPORT_DOMAIN}"
log ""
log "Create your first admin user:"
log "  kubectl -n teleport exec deploy/teleport -- tctl users add admin --roles=access,editor,auditor"
log ""
log "kubectl is configured to use the NLB DNS directly."
log "To switch to the friendly hostname (requires k8s.${TELEPORT_DOMAIN} in cert SANs):"
log "  kubectl config set-cluster ${CLUSTER_NAME} --server=https://${K8S_API_DOMAIN}"
log ""
log "To pause (scale workers to 0):  make pause"
log "To tear down:                   make down"
