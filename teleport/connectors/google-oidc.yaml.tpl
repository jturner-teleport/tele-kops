kind: oidc
version: v2
metadata:
  name: google
spec:
  issuer_url: 'https://accounts.google.com'
  client_id: '${GOOGLE_OAUTH_CLIENT_ID}'
  client_secret: '${GOOGLE_OAUTH_CLIENT_SECRET}'
  redirect_url: 'https://${TELEPORT_DOMAIN}/v1/webapi/oidc/callback'
  scope:
    - openid
    - email
    - profile
  # Google groups are not in the standard OIDC token; Teleport fetches them
  # server-side via the service account with domain-wide delegation.
  google_service_account_uri: 'file:///var/run/secrets/google-sa/service-account.json'
  google_admin_email: '${GOOGLE_ADMIN_EMAIL}'
  # Assign base roles to all authenticated b1tsized.tech users.
  # Login Rules (login-rule.yaml) transform Google groups → team trait.
  # All authenticated b1tsized.tech users get role-base only — no standing
  # privileges. They request role-{kube,ssh,ssh-root}-access as needed via
  # the access-request flow (role-ssh-access is auto-approved by the bot).
  # devops additionally gets role-grafana-access (Teleport-app access to
  # Grafana/Prometheus, gated by app_labels — orthogonal to the request flow).
  claims_to_roles:
    - claim: groups
      value: 'admin@b1tsized.tech'
      roles:
        - role-base
    - claim: groups
      value: 'engineering@b1tsized.tech'
      roles:
        - role-base
    - claim: groups
      value: 'devops@b1tsized.tech'
      roles:
        - role-base
        - role-grafana-access
