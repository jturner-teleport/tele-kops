# access-graph-values.yaml.tpl — Helm values for teleport-access-graph chart.
# Processed by scripts/spin-up.sh via envsubst.
#  - HOST_CA is the Teleport host CA PEM (extracted at runtime via
#    `tctl get cert_authorities`); already indented by 4 spaces by spin-up.sh
#    so it embeds cleanly under the YAML | block.
#  - The Postgres connection password lives in the access-graph-pg-uri Secret;
#    TAG reads it via postgres.secretName/secretKey below.

# Postgres connection: shared CNPG cluster, access_graph database/user.
postgres:
  secretName: "access-graph-pg-uri"
  secretKey: "uri"

# In-cluster TLS for the TAG gRPC endpoint. Issued by access-graph-ca-issuer
# (cert-manager). Auth pod trusts this via access_graph.ca in teleport.yaml.
tls:
  existingSecretName: "access-graph-tls"

# CA(s) trusted for inbound auth-server connections. This is Teleport's host CA.
clusterHostCAs:
  - |
${HOST_CA}

service:
  type: ClusterIP
  grpcPort: 443

replicaCount: 1

log:
  level: INFO

# Identity Activity Center — persists Teleport audit events into the AWS
# data lake (S3 + Athena + Glue) provisioned by scripts/spin-up.sh. Without
# this block, the auth pod's audit_log.enabled stream reaches TAG but is
# dropped (no persistent backend). Field meanings are documented in
# https://goteleport.com/docs/identity-security/access-graph/identity-activity-center/
identity_activity_center:
  enabled: true
  region: ${AWS_REGION}
  database: ${TELEPORT_IAC_GLUE_DB}
  table: ${TELEPORT_IAC_GLUE_TABLE}
  s3: s3://${TELEPORT_IAC_LONG_TERM_BUCKET}/data/
  s3_results: s3://${TELEPORT_IAC_TRANSIENT_BUCKET}/results/
  s3_large_files: s3://${TELEPORT_IAC_TRANSIENT_BUCKET}/large_files/
  workgroup: ${TELEPORT_IAC_WORKGROUP}
  sqs_queue_url: ${IAC_SQS_QUEUE_URL}
