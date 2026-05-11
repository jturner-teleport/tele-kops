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

# Mounted on both auth and proxy pods (proxy mount is harmless):
#   - google-sa: Google Workspace SA JSON for OIDC group fetching.
#     Secret 'google-sa' is created by spin-up.sh from ${GOOGLE_SA_JSON_FILE}.
#   - access-graph-ca: cert-manager-issued CA cert that signs TAG's TLS cert.
#     Used only by the auth pod's access_graph.ca config; secret managed by
#     helm/access-graph-cert.yaml.
extraVolumes:
  - name: google-sa
    secret:
      secretName: google-sa
  - name: access-graph-ca
    secret:
      secretName: access-graph-ca
      items:
        - key: tls.crt
          path: ca.pem
extraVolumeMounts:
  - name: google-sa
    mountPath: /var/run/secrets/google-sa
    readOnly: true
  - name: access-graph-ca
    mountPath: /var/run/access-graph
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
    # Identity Security / Access Graph (TAG) integration. The auth pod streams
    # cluster events to TAG over gRPC. Endpoint is the in-cluster TAG Service;
    # ca.pem is signed by the cert-manager self-signed CA created in
    # helm/access-graph-cert.yaml. If TAG isn't yet deployed, auth logs warnings
    # but otherwise operates normally — TAG is a non-blocking optional integration.
    access_graph:
      enabled: true
      endpoint: teleport-access-graph.teleport.svc.cluster.local:443
      ca: /var/run/access-graph/ca.pem
      # Forward Teleport audit log events to Access Graph for long-term retention
      # and cross-platform correlation (Identity Activity Center feature). Requires
      # TAG v1.28.0+ (we run 1.29.7). If TAG's IAC isn't fully configured with the
      # AWS Athena/S3/SQS stack, events are received but may not persist long-term
      # — basic forwarding still works.
      audit_log:
        enabled: true

# Proxy pod overrides — proxy peering listener (chart exposes :3021 on the pod
# already when enterprise=true, but doesn't set peer_listen_addr).
# The proxy ALSO needs the access_graph block: when a user opens the Identity
# Security UI, the proxy serves /webapi/access-graph and proxies requests to
# TAG. Without this block, proxy returns 404 "access graph service is not
# reachable" (lib/web/accessgraph.go).
proxy:
  teleportConfig:
    teleport:
      diag_addr: "0.0.0.0:3000"
    proxy_service:
      peer_listen_addr: "0.0.0.0:3021"
    access_graph:
      enabled: true
      endpoint: teleport-access-graph.teleport.svc.cluster.local:443
      ca: /var/run/access-graph/ca.pem
      # Forward Teleport audit log events to Access Graph for long-term retention
      # and cross-platform correlation (Identity Activity Center feature). Requires
      # TAG v1.28.0+ (we run 1.29.7). If TAG's IAC isn't fully configured with the
      # AWS Athena/S3/SQS stack, events are received but may not persist long-term
      # — basic forwarding still works.
      audit_log:
        enabled: true
