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
