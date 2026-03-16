---
# cluster.yaml.tpl — kops cluster manifest template.
# Processed by scripts/spin-up.sh via envsubst. Do not apply directly.
apiVersion: kops.k8s.io/v1alpha2
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
spec:
  # Custom domain for the API server ELB. Included in the API server TLS cert
  # so kubectl can verify TLS when using the friendly hostname.
  additionalSANs:
  - ${K8S_API_DOMAIN}

  # Tags applied to all cloud resources kops creates (ASGs, launch templates,
  # instances, volumes). Satisfies SCPs that require aws:RequestTag conditions.
  cloudLabels:
    teleport.dev/creator: "${LETSENCRYPT_EMAIL}"

  api:
    loadBalancer:
      type: Public
  authorization:
    rbac: {}
  channel: stable
  cloudProvider: aws
  configBase: ${KOPS_STATE_STORE}/${CLUSTER_NAME}

  etcdClusters:
  - etcdMembers:
    - instanceGroup: master-${AWS_AZ}
      name: a
    name: main
  - etcdMembers:
    - instanceGroup: master-${AWS_AZ}
      name: a
    name: events

  kubernetesVersion: 1.30.0
  kubernetesApiAccess:
  - 0.0.0.0/0
  sshAccess:
  - 0.0.0.0/0

  networkCIDR: 172.20.0.0/16
  nonMasqueradeCIDR: 100.64.0.0/10

  networking:
    calico: {}

  subnets:
  - cidr: 172.20.32.0/19
    name: ${AWS_AZ}
    type: Public
    zone: ${AWS_AZ}

  topology:
    masters: public
    nodes: public

  # Instance profile policies — grants Teleport pods (DynamoDB + S3) and
  # cert-manager (Route53 DNS-01) access without static credentials.
  additionalPolicies:
    node: |
      [
        {
          "Effect": "Allow",
          "Action": [
            "route53:ChangeResourceRecordSets",
            "route53:ListResourceRecordSets",
            "route53:GetChange",
            "route53:ListHostedZones"
          ],
          "Resource": ["*"]
        },
        {
          "Effect": "Allow",
          "Action": [
            "dynamodb:PutItem",
            "dynamodb:GetItem",
            "dynamodb:UpdateItem",
            "dynamodb:DeleteItem",
            "dynamodb:Query",
            "dynamodb:Scan",
            "dynamodb:DescribeTable",
            "dynamodb:UpdateTimeToLive",
            "dynamodb:UpdateContinuousBackups"
          ],
          "Resource": [
            "arn:aws:dynamodb:${AWS_REGION}:${AWS_ACCOUNT_ID}:table/${TELEPORT_BACKEND_TABLE}",
            "arn:aws:dynamodb:${AWS_REGION}:${AWS_ACCOUNT_ID}:table/${TELEPORT_EVENTS_TABLE}"
          ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "s3:ListBucket",
            "s3:GetBucketVersioning",
            "s3:GetEncryptionConfiguration",
            "s3:GetObject",
            "s3:PutObject",
            "s3:GetObjectVersion",
            "s3:ListBucketVersions"
          ],
          "Resource": [
            "arn:aws:s3:::${TELEPORT_SESSIONS_BUCKET}",
            "arn:aws:s3:::${TELEPORT_SESSIONS_BUCKET}/*"
          ]
        }
      ]

---
apiVersion: kops.k8s.io/v1alpha2
kind: InstanceGroup
metadata:
  labels:
    kops.k8s.io/cluster: ${CLUSTER_NAME}
  name: master-${AWS_AZ}
spec:
  machineType: t3.medium
  maxSize: 1
  minSize: 1
  role: Master
  subnets:
  - ${AWS_AZ}

---
apiVersion: kops.k8s.io/v1alpha2
kind: InstanceGroup
metadata:
  labels:
    kops.k8s.io/cluster: ${CLUSTER_NAME}
  name: nodes-${AWS_AZ}
spec:
  machineType: t3.medium
  maxSize: ${WORKER_MAX}
  minSize: ${WORKER_MIN}
  mixedInstancesPolicy:
    instances:
    - t3.medium
    - t3.large
    onDemandAboveBase: 0
    onDemandBase: 0
    spotAllocationStrategy: capacity-optimized
  role: Node
  subnets:
  - ${AWS_AZ}
