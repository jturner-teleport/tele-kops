# grafana-agent-values.yaml.tpl — teleport-kube-agent values for proxying Grafana.
# Processed by scripts/spin-up.sh via envsubst.
#
# Deploys a teleport-kube-agent (helm release 'grafana-agent', namespace 'teleport')
# in role=app that registers Grafana as a Teleport application. Once running, Grafana
# is reachable at https://grafana.${TELEPORT_DOMAIN} via Google SSO.

roles: "app"
proxyAddr: "${TELEPORT_DOMAIN}:443"
enterprise: true
teleportClusterName: "${TELEPORT_DOMAIN}"

# Resolve the proxy FQDN to the in-cluster service IP so the reverse tunnel
# doesn't egress through the public NLB. Without this, the NLB drops idle
# connections after ~60s, causing teleport_connected_resources to flap and
# producing Unknown InventoryControlStream gRPC errors. The TLS cert SAN
# still matches because we kept the FQDN — only the resolution path changes.
hostAliases:
  - ip: "${TELEPORT_PROXY_CLUSTER_IP}"
    hostnames:
      - "${TELEPORT_DOMAIN}"

# Kubernetes-style join via the agent's ServiceAccount JWT.
# Token is teleport/tokens/grafana-app-agent-token.yaml — applied by apply-teleport-config.sh
# (and by the teleport-apply CI workflow on push to main).
joinParams:
  method: "kubernetes"
  tokenName: "grafana-app-agent-token"

# Per-release Secret name so multiple teleport-kube-agent helm releases can
# coexist in the same namespace (default would collide).
joinTokenSecret:
  name: "grafana-agent-join-token"
  create: true

# Expose /metrics on port 3000 for Prometheus scraping.
# Setting podMonitor.enabled=true causes the chart to:
#   1. Add `--diag-addr=0.0.0.0:3000` to the teleport args
#   2. Render a PodMonitor CR that the kube-prometheus-stack picks up
podMonitor:
  enabled: true
  interval: 30s

apps:
  - name: grafana
    uri: "http://monitoring-grafana.monitoring.svc.cluster.local:80"
    public_addr: "grafana.${TELEPORT_DOMAIN}"
    rewrite:
      headers:
        - "Host: grafana.${TELEPORT_DOMAIN}"
        - "Origin: https://grafana.${TELEPORT_DOMAIN}"
        # Grafana's auth.jwt verifies this Teleport-signed JWT against the
        # proxy's JWKS endpoint (configured in helm/monitoring-values.yaml
        # under grafana.grafana.ini.auth.jwt). username_claim=sub maps to
        # the Teleport login name; role_attribute_path resolves the Grafana
        # org role from the JWT's roles claim on every request.
        # Reference: https://goteleport.com/docs/enroll-resources/application-access/jwt/grafana/
        - "Authorization: Bearer {{internal.jwt}}"
    labels:
      app: grafana
      env: dev
      tier: ops
