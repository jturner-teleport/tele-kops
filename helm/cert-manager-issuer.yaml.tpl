# cert-manager-issuer.yaml.tpl — Let's Encrypt ClusterIssuer using Route53 DNS-01.
# Processed by scripts/spin-up.sh via envsubst. Do not apply directly.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
spec:
  acme:
    email: ${LETSENCRYPT_EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-production
    solvers:
    - dns01:
        route53:
          region: ${AWS_REGION}
          hostedZoneID: ${ROUTE53_HOSTED_ZONE_ID}
