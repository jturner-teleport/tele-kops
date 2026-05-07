# teleport-values.yaml.tpl — Helm values template for teleport-cluster chart.
# Processed by scripts/spin-up.sh via envsubst AFTER CNPG is ready.
# CNPG_PASSWORD is extracted at runtime from the teleport-postgres-app secret.
#
# chartMode: standalone — chart renders separate auth/proxy ConfigMaps + Deployments,
# wires cert-manager TLS, mounts the enterprise license, and sets up proxy↔auth join.
# We override only what the chart can't infer (Postgres backend, OTP-only auth, peer settings).

chartMode: standalone
clusterName: ${TELEPORT_DOMAIN}
kubeClusterName: ${CLUSTER_NAME}
teleportVersionOrChannel: "${TELEPORT_VERSION}"
enterprise: true
licenseSecretName: license          # chart auto-mounts at /var/lib/license/license.pem
proxyListenerMode: multiplex

# Postgres backend — no need for PVC-backed /var/lib/teleport (chart uses emptyDir then).
persistence:
  enabled: false

highAvailability:
  replicaCount: 1
  certManager:
    enabled: true                   # auto-creates Certificate, wires https_keypairs
    issuerName: letsencrypt-production
    issuerKind: ClusterIssuer

podSecurityPolicy:
  enabled: false

# Google Workspace service account JSON for OIDC group fetching.
# Secret 'google-sa' is created by spin-up.sh from ${GOOGLE_SA_JSON_FILE}.
extraVolumes:
  - name: google-sa
    secret:
      secretName: google-sa
extraVolumeMounts:
  - name: google-sa
    mountPath: /var/run/secrets/google-sa
    readOnly: true

# Auth pod overrides — Postgres backend, S3 sessions, proxy peering tunnel strategy,
# and OTP-only authentication (chart default enables webauthn).
auth:
  teleportConfig:
    teleport:
      diag_addr: "0.0.0.0:3000"
      storage:
        type: postgresql
        conn_string: "postgresql://teleport:${CNPG_PASSWORD}@teleport-postgres-rw.teleport.svc.cluster.local:5432/teleport?sslmode=require"
        audit_events_uri:
          - "postgresql://teleport:${CNPG_PASSWORD}@teleport-postgres-rw.teleport.svc.cluster.local:5432/teleport?sslmode=require"
          - "stdout://"
        audit_sessions_uri: "s3://${TELEPORT_SESSIONS_BUCKET}?region=${AWS_REGION}"
    auth_service:
      authentication:
        type: local
        second_factor: otp
        # Null out the chart's webauthn defaults so we get OTP-only behavior.
        second_factors: ~
        webauthn: ~
      tunnel_strategy:
        type: proxy_peering
        agent_connection_count: 1

# Proxy pod overrides — proxy peering listener (chart exposes :3021 on the pod
# already when enterprise=true, but doesn't set peer_listen_addr).
proxy:
  teleportConfig:
    teleport:
      diag_addr: "0.0.0.0:3000"
    proxy_service:
      peer_listen_addr: "0.0.0.0:3021"
