# ssh-node-deployment.yaml.tpl — Teleport SSH node (role=node) running in-cluster.
# Processed by scripts/spin-up.sh via envsubst.
#
# Joins via the kubernetes ProvisionToken in teleport/tokens/ssh-node-token.yaml
# (allow.service_account = "teleport:ssh-node"). Reverse-tunnels to the proxy
# at ${TELEPORT_DOMAIN}:443 so no inbound port exposure is needed. Exposes
# /metrics on port 3000 via a PodMonitor so Prometheus scrapes it like the
# other kube-agents.
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ssh-node
  namespace: teleport
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ssh-node-config
  namespace: teleport
data:
  teleport.yaml: |
    version: v3
    teleport:
      nodename: ssh-node-1
      data_dir: /var/lib/teleport
      diag_addr: "0.0.0.0:3000"
      proxy_server: ${TELEPORT_DOMAIN}:443
      join_params:
        method: kubernetes
        token_name: ssh-node-token
      log:
        output: stderr
        severity: INFO
    ssh_service:
      enabled: "yes"
      labels:
        env: dev
        team: devops
        hostname: ssh-node-1
    auth_service:
      enabled: "no"
    proxy_service:
      enabled: "no"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ssh-node
  namespace: teleport
  labels:
    app.kubernetes.io/name: ssh-node
    app.kubernetes.io/component: agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ssh-node
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ssh-node
        app.kubernetes.io/component: agent
    spec:
      serviceAccountName: ssh-node
      imagePullSecrets:
        - name: ghcr-pull-secret
      containers:
        - name: teleport
          image: ghcr.io/jturner-teleport/ssh-node:latest
          imagePullPolicy: Always
          args:
            - start
            - --config=/etc/teleport/teleport.yaml
          ports:
            - name: diag
              containerPort: 3000
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /readyz
              port: diag
            initialDelaySeconds: 15
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          volumeMounts:
            - name: config
              mountPath: /etc/teleport
              readOnly: true
            - name: data
              mountPath: /var/lib/teleport
      volumes:
        - name: config
          configMap:
            name: ssh-node-config
        - name: data
          emptyDir: {}
---
# PodMonitor so kube-prometheus-stack scrapes this agent's /metrics — matches
# the pattern used by the chart-managed grafana-agent / prometheus-agent
# PodMonitors.
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: ssh-node
  namespace: teleport
spec:
  namespaceSelector:
    matchNames:
      - teleport
  selector:
    matchLabels:
      app.kubernetes.io/name: ssh-node
  podMetricsEndpoints:
    - port: diag
      path: /metrics
      interval: 30s
