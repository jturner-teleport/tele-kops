# SMTP Email Notifications (Mailpit)

Sets up the `teleport-plugin-email` Helm chart to send access request notifications through [Mailpit](https://mailpit.axllent.org/) — a local SMTP catch-all that lets you inspect outbound emails without a real mail server.

## Architecture

```
Access Request submitted
    → teleport-plugin-email   (in-cluster, bot identity)
        → Mailpit SMTP        (in-cluster, port 1025, no TLS)
            → Mailpit Web UI  (port-forward to localhost:8025)
```

The review links in captured emails point at your live Teleport URL, so you can click through and actually approve/deny requests.

---

## Prerequisites

- Cluster running (`make up` complete, admin user created)
- `kubectl` context pointing at the cluster

---

## Step 1: Deploy Mailpit

```bash
cat <<'EOF' | kubectl apply --validate=false -f -
apiVersion: v1
kind: Namespace
metadata:
  name: mailpit
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mailpit
  namespace: mailpit
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mailpit
  template:
    metadata:
      labels:
        app: mailpit
    spec:
      containers:
      - name: mailpit
        image: axllent/mailpit:latest
        ports:
        - containerPort: 1025
        - containerPort: 8025
        env:
        - name: MP_MAX_MESSAGES
          value: "500"
        - name: MP_SMTP_AUTH_ALLOW_INSECURE
          value: "true"
---
apiVersion: v1
kind: Service
metadata:
  name: mailpit-smtp
  namespace: mailpit
spec:
  selector:
    app: mailpit
  ports:
  - port: 1025
    targetPort: 1025
---
apiVersion: v1
kind: Service
metadata:
  name: mailpit-ui
  namespace: mailpit
spec:
  selector:
    app: mailpit
  ports:
  - port: 8025
    targetPort: 8025
EOF
```

> **Gotcha:** The env var `MP_SMTP_AUTH_ACCEPT_ANY` does **not** work for insecure (non-TLS) auth — Mailpit requires `MP_SMTP_AUTH_ALLOW_INSECURE=true` for plaintext SMTP. Using the wrong var causes an immediate crash on startup.

Verify it's running:

```bash
kubectl rollout status deployment/mailpit -n mailpit
```

---

## Step 2: Create the bot role

```bash
cat <<'EOF' | kubectl -n teleport exec -i deploy/teleport-auth -- tctl create -f
kind: role
version: v7
metadata:
  name: teleport-plugin-email
spec:
  allow:
    rules:
      - resources: [access_request]
        verbs: [list, read, update]
      - resources: [access_monitoring_rule]
        verbs: [list, read, watch]
      - resources: [user]
        verbs: [list, read]
      - resources: [role]
        verbs: [list, read]
EOF
```

> **Gotcha:** The plugin also watches `access_monitoring_rule` (v18+). If this permission is missing the plugin starts, connects successfully, then immediately crashes with `failed to initialize watcher for all the required resources`.

---

## Step 3: Create the bot

```bash
kubectl -n teleport exec deploy/teleport-auth -- \
  tctl bots add email-plugin --roles=teleport-plugin-email
```

This creates:
- Bot resource `email-plugin`
- User `bot-email-plugin`
- System role `bot-email-plugin` (with impersonation of `teleport-plugin-email`)

### Grant permissions directly to the system bot role

`tctl bots add` creates a system role `bot-email-plugin` with impersonation rights only. The plugin connects as `bot-email-plugin`, so the resource permissions must also be on that system role — not just on `teleport-plugin-email`.

Patch the system role to add the plugin permissions:

```bash
cat <<'EOF' | kubectl -n teleport exec -i deploy/teleport-auth -- tctl create -f
kind: role
metadata:
  description: Automatically generated role for bot email-plugin
  labels:
    teleport.internal/bot: email-plugin
  name: bot-email-plugin
spec:
  allow:
    impersonate:
      roles:
      - teleport-plugin-email
    rules:
    - resources: [cert_authority]
      verbs: [readnosecrets]
    - resources: [access_request]
      verbs: [list, read, update]
    - resources: [access_monitoring_rule]
      verbs: [list, read, watch]
    - resources: [user]
      verbs: [list, read]
    - resources: [role]
      verbs: [list, read]
  deny: {}
  options:
    cert_format: standard
    forward_agent: false
    max_session_ttl: 12h0m0s
version: v8
EOF
```

> **Why:** When the plugin authenticates with the signed identity, it presents the `bot-email-plugin` role — not `teleport-plugin-email`. Teleport checks permissions based on the active role in the certificate, not impersonation targets. The system role needs both the impersonation entry (for tbot compatibility) and the direct rules.

---

## Step 4: Sign an identity and create the secret

The Teleport auth pod runs a `distroless` image (no shell, no `cat`, no `tar` for `kubectl cp`). Use the `--tar` flag to stream the identity to stdout:

```bash
AUTH_POD=$(kubectl get pod -n teleport -l app.kubernetes.io/component=auth \
  -o jsonpath='{.items[0].metadata.name}')

kubectl -n teleport exec "$AUTH_POD" -- \
  tctl auth sign --user=bot-email-plugin --out=identity --ttl=8760h --tar \
  2>/dev/null | tar -x -O identity > /tmp/email-plugin-identity

kubectl create secret generic teleport-plugin-email-identity \
  -n teleport \
  --from-file=auth_id=/tmp/email-plugin-identity

rm /tmp/email-plugin-identity
```

> **Gotcha:** `kubectl cp` requires `tar` in the container — distroless has none. `tctl auth sign --out=/dev/stdout` also doesn't work. The `--tar` flag is the only way to stream the file out of a distroless pod.

> **Note:** The identity is valid for 1 year (`8760h`). For production, use `tbot` with the Kubernetes join method for auto-rotating credentials instead.

---

## Step 5: Create the SMTP password secret

The Helm chart requires the SMTP password as a Kubernetes secret — inline `password:` values in the chart values are not supported (it looks for a password file path).

```bash
kubectl create secret generic mailpit-smtp-password \
  -n teleport \
  --from-literal=password=teleport
```

---

## Step 6: Deploy the email plugin

```bash
source config.env   # for TELEPORT_DOMAIN

helm repo add teleport https://charts.releases.teleport.dev
helm repo update

cat > /tmp/email-plugin-values.yaml <<EOF
teleport:
  address: "teleport-auth.teleport.svc.cluster.local:3025"
  identitySecretName: "teleport-plugin-email-identity"
  identitySecretPath: "auth_id"

smtp:
  enabled: true
  host: "mailpit-smtp.mailpit.svc.cluster.local"
  port: 1025
  username: "teleport"
  passwordFromSecret: "mailpit-smtp-password"
  passwordSecretPath: "password"
  starttlsPolicy: "disabled"

delivery:
  sender: "teleport@${TELEPORT_DOMAIN}"

roleToRecipients:
  b1tsized-poweruser:
    - "admin@${TELEPORT_DOMAIN}"
  "*":
    - "admin@${TELEPORT_DOMAIN}"

log:
  severity: "DEBUG"
EOF

helm upgrade --install teleport-plugin-email teleport/teleport-plugin-email \
  --namespace teleport \
  --values /tmp/email-plugin-values.yaml \
  --version 18.7.4   # match your Teleport version
```

> **Gotcha:** `smtp.enabled: true` is required. Without it, the chart omits the smtp block from the generated config and the plugin crashes with `provide either [mailgun] or [smtp] sections`.

> **Note on `roleToRecipients`:** The `"*"` wildcard entry is required as a fallback — the plugin will refuse to start without it. Add an entry per role that should trigger notifications.

Verify the plugin is healthy:

```bash
kubectl logs -n teleport -l app.kubernetes.io/name=teleport-plugin-email --tail=20
# Should end with: INFO  Plugin is ready
```

---

## Accessing the Mailpit UI

```bash
kubectl port-forward -n mailpit svc/mailpit-ui 8025:8025
```

Open **http://localhost:8025**

Emails appear here as access requests are submitted. Review links in the emails point to your live Teleport cluster.

---

## Updating `roleToRecipients`

To add a new role mapping, edit your values file and upgrade:

```bash
helm upgrade teleport-plugin-email teleport/teleport-plugin-email \
  --namespace teleport \
  --values /tmp/email-plugin-values.yaml \
  --version 18.7.4
```

---

## Troubleshooting

### Plugin crashes immediately — `provide either [mailgun] or [smtp]`

`smtp.enabled: true` is missing from values.

### Plugin crashes — `Error reading password from .../smtp_password`

SMTP password must be in a Kubernetes secret, not inline. See Step 5.

### Plugin starts then crashes — `failed to initialize watcher`

The `bot-email-plugin` system role is missing `access_monitoring_rule` permissions. Re-apply the role patch from Step 3.

### Plugin crashes — `none of the requested kinds can be watched`

Same root cause as above — permissions on the system role are incomplete.

### Mailpit pod in `CrashLoopBackOff`

Check logs: `kubectl logs -n mailpit -l app=mailpit --previous`

If you see `authentication requires STARTTLS or TLS encryption`, the env var is wrong. It must be `MP_SMTP_AUTH_ALLOW_INSECURE=true`, not `MP_SMTP_AUTH_ACCEPT_ANY`.

### No emails arriving in Mailpit

1. Submit a test access request as a non-admin user
2. Check plugin logs for delivery attempts: `kubectl logs -n teleport -l app.kubernetes.io/name=teleport-plugin-email`
3. Verify the requested role is covered by `roleToRecipients` (either directly or via `"*"`)
