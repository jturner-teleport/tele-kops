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
        # Grafana's auth.proxy trusts these headers (configured in
        # helm/monitoring-values.yaml under grafana.grafana.ini.auth.proxy).
        # The Teleport user is auto-signed-up in Grafana on first request.
        # X-WEBAUTH-ROLE refreshes the Grafana org role on every login —
        # all users with role-grafana-access get Admin (gated at Teleport).
        #
        # X-WEBAUTH-USER uses {{external.email}} so the Grafana login
        # matches the user's email. SSO users get their Google email; the
        # local admin user has `email: admin@b1tsized.tech` set as a trait
        # (so `external.email` resolves for both).
        # The {{teleport.user}} placeholder is NOT supported in app rewrite
        # headers in v18 (only in role/login-rule templates).
        - "X-WEBAUTH-USER: {{external.email}}"
        - "X-WEBAUTH-EMAIL: {{external.email}}"
        - "X-WEBAUTH-NAME: {{external.name}}"
        - "X-WEBAUTH-ROLE: Admin"
    labels:
      app: grafana
      env: dev
      tier: ops
