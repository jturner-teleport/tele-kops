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
      class: Network
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

  # Instance profile policies — grants node pods (CNPG S3 WAL, Teleport sessions,
  # cert-manager Route53 DNS-01) access without static credentials.
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
            "s3:ListBucket",
            "s3:GetBucketVersioning",
            "s3:GetEncryptionConfiguration",
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:GetObjectVersion",
            "s3:ListBucketVersions",
            "s3:ListBucketMultipartUploads",
            "s3:AbortMultipartUpload",
            "s3:ListMultipartUploadParts"
          ],
          "Resource": [
            "arn:aws:s3:::${TELEPORT_SESSIONS_BUCKET}",
            "arn:aws:s3:::${TELEPORT_SESSIONS_BUCKET}/*"
          ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:ListBucket",
            "s3:GetBucketLocation",
            "s3:GetBucketVersioning",
            "s3:GetEncryptionConfiguration"
          ],
          "Resource": [
            "arn:aws:s3:::${TELEPORT_PG_WAL_BUCKET}",
            "arn:aws:s3:::${TELEPORT_PG_WAL_BUCKET}/*"
          ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "kms:GenerateDataKey",
            "kms:Decrypt"
          ],
          "Resource": "*",
          "Condition": {
            "ForAnyValue:StringEquals": {
              "kms:ResourceAliases": "alias/${TELEPORT_IAC_KMS_ALIAS}"
            }
          }
        },
        {
          "Effect": "Allow",
          "Action": [
            "sqs:ReceiveMessage",
            "sqs:DeleteMessage",
            "sqs:SendMessage"
          ],
          "Resource": [
            "arn:aws:sqs:${AWS_REGION}:${AWS_ACCOUNT_ID}:${TELEPORT_IAC_SQS_QUEUE}"
          ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "s3:ListBucket",
            "s3:ListBucketMultipartUploads",
            "s3:GetBucketLocation",
            "s3:ListBucketVersions"
          ],
          "Resource": [
            "arn:aws:s3:::${TELEPORT_IAC_LONG_TERM_BUCKET}",
            "arn:aws:s3:::${TELEPORT_IAC_TRANSIENT_BUCKET}"
          ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "s3:PutObject",
            "s3:GetObject",
            "s3:GetObjectVersion",
            "s3:DeleteObject",
            "s3:DeleteObjectVersion",
            "s3:ListMultipartUploadParts",
            "s3:AbortMultipartUpload"
          ],
          "Resource": [
            "arn:aws:s3:::${TELEPORT_IAC_LONG_TERM_BUCKET}/data/*",
            "arn:aws:s3:::${TELEPORT_IAC_TRANSIENT_BUCKET}/results/*",
            "arn:aws:s3:::${TELEPORT_IAC_TRANSIENT_BUCKET}/large_files/*"
          ]
        },
        {
          "Effect": "Allow",
          "Action": [
            "glue:GetTable",
            "athena:StartQueryExecution",
            "athena:GetQueryResults",
            "athena:GetQueryExecution"
          ],
          "Resource": [
            "arn:aws:athena:${AWS_REGION}:${AWS_ACCOUNT_ID}:workgroup/${TELEPORT_IAC_WORKGROUP}",
            "arn:aws:glue:${AWS_REGION}:${AWS_ACCOUNT_ID}:catalog",
            "arn:aws:glue:${AWS_REGION}:${AWS_ACCOUNT_ID}:database/${TELEPORT_IAC_GLUE_DB}",
            "arn:aws:glue:${AWS_REGION}:${AWS_ACCOUNT_ID}:table/${TELEPORT_IAC_GLUE_DB}/${TELEPORT_IAC_GLUE_TABLE}"
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
  machineType: t3.large
  maxSize: ${WORKER_MAX}
  minSize: ${WORKER_MIN}
  mixedInstancesPolicy:
    instances:
    - t3.large
    - t3.xlarge
    onDemandAboveBase: 0
    onDemandBase: 0
    spotAllocationStrategy: capacity-optimized
  role: Node
  subnets:
  - ${AWS_AZ}
  # Allow pods to reach EC2 IMDS for IAM credentials (e.g. CNPG → S3, Teleport → S3).
  # AWS defaults to hop limit 1 (instance only); pods need limit 2.
  instanceMetadata:
    httpPutResponseHopLimit: 2
    httpTokens: required
