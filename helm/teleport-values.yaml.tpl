# teleport-values.yaml.tpl — Helm values template for teleport-cluster chart.
# Processed by scripts/spin-up.sh via envsubst. Do not apply directly.

chartMode: aws
clusterName: ${TELEPORT_DOMAIN}
teleportVersionOrChannel: "${TELEPORT_VERSION}"
proxyListenerMode: multiplex

aws:
  region: ${AWS_REGION}
  backendTable: ${TELEPORT_BACKEND_TABLE}
  auditLogTable: ${TELEPORT_EVENTS_TABLE}
  auditLogMirrorOnStdout: false
  sessionRecordingBucket: ${TELEPORT_SESSIONS_BUCKET}
  backups: false
  dynamoAutoScaling: false

highAvailability:
  replicaCount: 1
  certManager:
    enabled: true
    issuerName: letsencrypt-production
    issuerKind: ClusterIssuer

podSecurityPolicy:
  enabled: false
