# prometheus-agent-values.yaml.tpl — teleport-kube-agent values for proxying Prometheus.
# Processed by scripts/spin-up.sh via envsubst.
#
# Deploys a teleport-kube-agent (helm release 'prometheus-agent', namespace 'teleport')
# in role=app that registers Prometheus as a Teleport application. Once running,
# Prometheus is reachable at https://prometheus.${TELEPORT_DOMAIN} via Google SSO.
# Access is gated by role-grafana-access (label tier=ops), so devops + admin@ users
# automatically have it via the OIDC connector mapping.

roles: "app"
proxyAddr: "${TELEPORT_DOMAIN}:443"
enterprise: true
teleportClusterName: "${TELEPORT_DOMAIN}"

joinParams:
  method: "kubernetes"
  tokenName: "prometheus-app-agent-token"

# Per-release Secret name so this release doesn't collide with grafana-agent.
joinTokenSecret:
  name: "prometheus-agent-join-token"
  create: true

# Expose /metrics for Prometheus scraping (yes, Prometheus scraping its own
# proxy agent — useful to verify the agent is healthy).
podMonitor:
  enabled: true
  interval: 30s

apps:
  - name: prometheus
    uri: "http://monitoring-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"
    public_addr: "prometheus.${TELEPORT_DOMAIN}"
    rewrite:
      headers:
        - "Host: prometheus.${TELEPORT_DOMAIN}"
        - "Origin: https://prometheus.${TELEPORT_DOMAIN}"
    labels:
      app: prometheus
      env: dev
      tier: ops
