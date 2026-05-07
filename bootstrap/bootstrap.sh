#!/usr/bin/env bash
# bootstrap.sh — Run once to create persistent AWS resources.
# Safe to re-run; all commands are idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

log()  { echo "[bootstrap] $*"; }
fail() { echo "[bootstrap] ERROR: $*" >&2; exit 1; }

command -v aws &>/dev/null || fail "aws CLI not found"

if [[ -z "${AWS_ACCOUNT_ID:-}" ]]; then
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  export AWS_ACCOUNT_ID
fi

log "Account: ${AWS_ACCOUNT_ID} | Region: ${AWS_REGION}"

# ── Helper: create S3 bucket (handles us-east-1 quirk) ────────────────────────
create_bucket() {
  local bucket="$1"
  local public="${2:-false}"

  log "Creating S3 bucket: ${bucket}"

  if [[ "${AWS_REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${bucket}" --region "${AWS_REGION}" 2>/dev/null || true
  else
    aws s3api create-bucket \
      --bucket "${bucket}" \
      --region "${AWS_REGION}" \
      --create-bucket-configuration LocationConstraint="${AWS_REGION}" 2>/dev/null || true
  fi

  aws s3api put-bucket-versioning \
    --bucket "${bucket}" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption \
    --bucket "${bucket}" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

  if [[ "${public}" == "false" ]]; then
    aws s3api put-public-access-block \
      --bucket "${bucket}" \
      --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  fi

  aws s3api put-bucket-tagging \
    --bucket "${bucket}" \
    --tagging "TagSet=[{Key=teleport.dev/creator,Value=${LETSENCRYPT_EMAIL}},{Key=KubernetesCluster,Value=${CLUSTER_NAME}}]"
}

# ── k0ps state store ───────────────────────────────────────────────────────────
create_bucket "${KOPS_STATE_BUCKET}"

# ── Teleport session recordings ────────────────────────────────────────────────
create_bucket "${TELEPORT_SESSIONS_BUCKET}"

# ── CNPG WAL archive and base backups ─────────────────────────────────────────
# CloudNativePG uses this bucket for continuous WAL archiving and scheduled base
# backups. It is the persistence layer for the in-cluster PostgreSQL database —
# the cluster can be destroyed and recreated and Postgres state is preserved here.
create_bucket "${TELEPORT_PG_WAL_BUCKET}"

# ── k0ps deployer role ─────────────────────────────────────────────────────────
# A dedicated automation role that scripts assume before running kops. Using a
# named IAM role (rather than the AWSReservedSSO_Admin SSO role) satisfies SCPs
# that restrict sensitive actions to non-human automation roles.
KOPS_ROLE_NAME="${PREFIX}-kops-deployer"
KOPS_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${KOPS_ROLE_NAME}"

if aws iam get-role --role-name "${KOPS_ROLE_NAME}" &>/dev/null; then
  log "kops deployer role already exists: ${KOPS_ROLE_ARN}"
else
  log "Creating kops deployer role: ${KOPS_ROLE_NAME}"

  TRUST_POLICY=$(cat <<TRUST
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::${AWS_ACCOUNT_ID}:root" },
    "Action": "sts:AssumeRole"
  }]
}
TRUST
)
  aws iam create-role \
    --role-name "${KOPS_ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}" \
    --tags \
      Key=KubernetesCluster,Value="${CLUSTER_NAME}" \
      "Key=teleport.dev/creator,Value=${LETSENCRYPT_EMAIL}"

  log "  Created: ${KOPS_ROLE_ARN}"
fi

# Always sync the inline policy (idempotent — put-role-policy creates or replaces).
# Scoped tightly: IAM restricted to kops node profiles/roles, S3 to the state
# bucket, Route53 ChangeResourceRecordSets to the specific hosted zone.
log "Syncing kops deployer inline policy..."
KOPS_POLICY=$(cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2Management",
      "Effect": "Allow",
      "Action": [
        "ec2:AddTags",
        "ec2:AssociateRouteTable",
        "ec2:AttachInternetGateway",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:CancelSpotInstanceRequests",
        "ec2:AssociateDhcpOptions",
        "ec2:AssociateVpcCidrBlock",
        "ec2:CreateDhcpOptions",
        "ec2:CreateInternetGateway",
        "ec2:CreateLaunchTemplate",
        "ec2:CreateLaunchTemplateVersion",
        "ec2:CreateRoute",
        "ec2:CreateRouteTable",
        "ec2:CreateSecurityGroup",
        "ec2:CreateSubnet",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:CreateVpc",
        "ec2:DeleteDhcpOptions",
        "ec2:DeleteInternetGateway",
        "ec2:DeleteLaunchTemplate",
        "ec2:DeleteRoute",
        "ec2:DeleteRouteTable",
        "ec2:DeleteKeyPair",
        "ec2:DeleteSecurityGroup",
        "ec2:DeleteSubnet",
        "ec2:DeleteTags",
        "ec2:DeleteVolume",
        "ec2:DeleteVpc",
        "ec2:DescribeAccountAttributes",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeDhcpOptions",
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeKeyPairs",
        "ec2:ImportKeyPair",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeInternetGateways",
        "ec2:DescribeKeyPairs",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeRegions",
        "ec2:DescribeRouteTables",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSpotInstanceRequests",
        "ec2:DescribeSpotPriceHistory",
        "ec2:DescribeSubnets",
        "ec2:DescribeTags",
        "ec2:DescribeVolumes",
        "ec2:DescribeSecurityGroupRules",
        "ec2:DescribeEgressOnlyInternetGateways",
        "ec2:DescribeNetworkAcls",
        "ec2:DescribeVpcAttribute",
        "ec2:DescribeVpcs",
        "ec2:DetachInternetGateway",
        "ec2:DisassociateRouteTable",
        "ec2:DisassociateVpcCidrBlock",
        "ec2:ImportKeyPair",
        "ec2:ModifyInstanceAttribute",
        "ec2:ModifyInstanceMetadataOptions",
        "ec2:ModifyLaunchTemplate",
        "ec2:ModifySubnetAttribute",
        "ec2:ModifyVpcAttribute",
        "ec2:RequestSpotInstances",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:RunInstances",
        "ec2:StopInstances",
        "ec2:TerminateInstances"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AutoScaling",
      "Effect": "Allow",
      "Action": [
        "autoscaling:AttachInstances",
        "autoscaling:CreateAutoScalingGroup",
        "autoscaling:CreateOrUpdateTags",
        "autoscaling:DeleteAutoScalingGroup",
        "autoscaling:DeleteTags",
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeLoadBalancers",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "autoscaling:CompleteLifecycleAction",
        "autoscaling:DeleteLifecycleHook",
        "autoscaling:DescribeLifecycleHooks",
        "autoscaling:DeleteWarmPool",
        "autoscaling:DescribeWarmPool",
        "autoscaling:DetachInstances",
        "autoscaling:PutWarmPool",
        "autoscaling:DisableMetricsCollection",
        "autoscaling:PutLifecycleHook",
        "autoscaling:EnableMetricsCollection",
        "autoscaling:SetDesiredCapacity",
        "autoscaling:SuspendProcesses",
        "autoscaling:TerminateInstanceInAutoScalingGroup",
        "autoscaling:UpdateAutoScalingGroup"
      ],
      "Resource": "*"
    },
    {
      "Sid": "LoadBalancers",
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:AddTags",
        "elasticloadbalancing:ApplySecurityGroupsToLoadBalancer",
        "elasticloadbalancing:AttachLoadBalancerToSubnets",
        "elasticloadbalancing:ConfigureHealthCheck",
        "elasticloadbalancing:CreateListener",
        "elasticloadbalancing:CreateLoadBalancer",
        "elasticloadbalancing:CreateLoadBalancerListeners",
        "elasticloadbalancing:CreateLoadBalancerPolicy",
        "elasticloadbalancing:CreateTargetGroup",
        "elasticloadbalancing:DeleteListener",
        "elasticloadbalancing:DeleteLoadBalancer",
        "elasticloadbalancing:DeleteLoadBalancerListeners",
        "elasticloadbalancing:DeleteTargetGroup",
        "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
        "elasticloadbalancing:DeregisterTargets",
        "elasticloadbalancing:DescribeInstanceHealth",
        "elasticloadbalancing:DescribeListeners",
        "elasticloadbalancing:DescribeLoadBalancerAttributes",
        "elasticloadbalancing:DescribeLoadBalancerPolicies",
        "elasticloadbalancing:DescribeLoadBalancers",
        "elasticloadbalancing:DescribeTags",
        "elasticloadbalancing:DescribeTargetGroups",
        "elasticloadbalancing:DescribeTargetHealth",
        "elasticloadbalancing:DetachLoadBalancerFromSubnets",
        "elasticloadbalancing:ModifyListener",
        "elasticloadbalancing:ModifyLoadBalancerAttributes",
        "elasticloadbalancing:ModifyTargetGroup",
        "elasticloadbalancing:ModifyTargetGroupAttributes",
        "elasticloadbalancing:DescribeTargetGroupAttributes",
        "elasticloadbalancing:SetSubnets",
        "elasticloadbalancing:SetSecurityGroups",
        "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
        "elasticloadbalancing:RegisterTargets",
        "elasticloadbalancing:RemoveTags",
        "elasticloadbalancing:SetLoadBalancerPoliciesForBackendServer"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMReadOnly",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole",
        "iam:GetInstanceProfile",
        "iam:GetRolePolicy",
        "iam:GetOpenIDConnectProvider",
        "iam:ListOpenIDConnectProviders",
        "iam:ListRoles",
        "iam:ListInstanceProfiles",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:ListRolePolicies"
      ],
      "Resource": "*"
    },
    {
      "Sid": "NodeInstanceProfilesAndRoles",
      "Effect": "Allow",
      "Action": [
        "iam:AddRoleToInstanceProfile",
        "iam:AttachRolePolicy",
        "iam:CreateInstanceProfile",
        "iam:CreateRole",
        "iam:DeleteInstanceProfile",
        "iam:DeleteRole",
        "iam:DeleteRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PassRole",
        "iam:PutRolePolicy",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:TagInstanceProfile",
        "iam:TagRole",
        "iam:UntagInstanceProfile",
        "iam:UntagRole"
      ],
      "Resource": [
        "arn:aws:iam::${AWS_ACCOUNT_ID}:role/masters.${CLUSTER_NAME}",
        "arn:aws:iam::${AWS_ACCOUNT_ID}:role/nodes.${CLUSTER_NAME}",
        "arn:aws:iam::${AWS_ACCOUNT_ID}:instance-profile/masters.${CLUSTER_NAME}",
        "arn:aws:iam::${AWS_ACCOUNT_ID}:instance-profile/nodes.${CLUSTER_NAME}"
      ]
    },
    {
      "Sid": "EventBridge",
      "Effect": "Allow",
      "Action": [
        "events:DeleteRule",
        "events:DescribeRule",
        "events:ListRules",
        "events:ListRuleNamesByTarget",
        "events:ListTagsForResource",
        "events:ListTargetsByRule",
        "events:TagResource",
        "events:UntagResource",
        "events:PutRule",
        "events:PutTargets",
        "events:RemoveTargets"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SQS",
      "Effect": "Allow",
      "Action": [
        "sqs:CreateQueue",
        "sqs:DeleteQueue",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "sqs:ListQueues",
        "sqs:ListQueueTags",
        "sqs:TagQueue",
        "sqs:UntagQueue",
        "sqs:ReceiveMessage",
        "sqs:SendMessage",
        "sqs:SetQueueAttributes"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMServiceLinkedRole",
      "Effect": "Allow",
      "Action": "iam:CreateServiceLinkedRole",
      "Resource": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/aws-service-role/elasticloadbalancing.amazonaws.com/*",
      "Condition": {
        "StringEquals": { "iam:AWSServiceName": "elasticloadbalancing.amazonaws.com" }
      }
    },
    {
      "Sid": "KopsStateStore",
      "Effect": "Allow",
      "Action": [
        "s3:DeleteObject",
        "s3:GetBucketLocation",
        "s3:GetEncryptionConfiguration",
        "s3:GetObject",
        "s3:GetObjectAcl",
        "s3:ListBucket",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::${KOPS_STATE_BUCKET}",
        "arn:aws:s3:::${KOPS_STATE_BUCKET}/*"
      ]
    },
    {
      "Sid": "Route53RecordSets",
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets",
        "route53:ListResourceRecordSets"
      ],
      "Resource": "arn:aws:route53:::hostedzone/${ROUTE53_HOSTED_ZONE_ID}"
    },
    {
      "Sid": "Route53ReadOnly",
      "Effect": "Allow",
      "Action": [
        "route53:GetChange",
        "route53:GetHostedZone",
        "route53:ListHostedZones"
      ],
      "Resource": "*"
    },
    {
      "Sid": "STS",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
POLICY
)

# Compare to the deployed policy; only update if different.
# Uses --output json so PolicyDocument comes back as a parsed object (not
# tab-separated text). Normalises both sides with sort_keys so cosmetic
# differences in the heredoc don't trigger a spurious update.
_norm_policy() {
  python3 - <<'PY'
import json, sys, urllib.parse
try:
    data = json.load(sys.stdin)
    doc = data.get("PolicyDocument", data)
    if isinstance(doc, str):
        doc = json.loads(urllib.parse.unquote(doc))
    print(json.dumps(doc, sort_keys=True))
except Exception:
    pass
PY
}

CURRENT_POLICY=$(aws iam get-role-policy \
  --role-name "${KOPS_ROLE_NAME}" \
  --policy-name "${KOPS_ROLE_NAME}-policy" \
  --output json 2>/dev/null | _norm_policy || true)

DESIRED_POLICY=$(echo "${KOPS_POLICY}" | python3 -c "
import json, sys
print(json.dumps(json.load(sys.stdin), sort_keys=True))
")

if [[ "${CURRENT_POLICY}" == "${DESIRED_POLICY}" ]]; then
  log "kops deployer policy is up to date, no changes needed."
else
  log "Updating kops deployer policy..."
  aws iam put-role-policy \
    --role-name "${KOPS_ROLE_NAME}" \
    --policy-name "${KOPS_ROLE_NAME}-policy" \
    --policy-document "${KOPS_POLICY}"
  log "  Policy updated."
fi

log ""
log "Bootstrap complete."
log ""
log "Next steps:"
log "  1. Ensure config.env is filled in (copied from config.env.example)"
log "  2. Push docker/Dockerfile to trigger GHCR image build (GitHub Actions)"
log "  3. Run: make up"
