#!/usr/bin/env bash
# apply-teleport-config.sh — Apply Teleport YAML configs via tctl.
# Idempotent: uses tctl create -f --force which overwrites existing resources.
# Mirrors what .github/workflows/teleport-apply.yml does, but for local dev runs
# of `make up` before any commit has been merged to main.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
source "${ROOT_DIR}/config.env"

log()  { echo "[apply-config] $*"; }
fail() { echo "[apply-config] ERROR: $*" >&2; exit 1; }

# tctl is run inside the Teleport pod since it needs direct auth service access.
TCTL=(kubectl -n teleport exec -i deploy/teleport-auth -- tctl)

log "Waiting for Teleport auth to be ready..."
ATTEMPTS=0
until "${TCTL[@]}" status &>/dev/null; do
  ATTEMPTS=$((ATTEMPTS + 1))
  [[ $ATTEMPTS -ge 30 ]] && fail "Timed out waiting for tctl to be available"
  sleep 10
done

# ── RBAC roles ────────────────────────────────────────────────────────────────
log "Applying RBAC roles..."
for role_file in "${ROOT_DIR}/teleport/roles/"*.yaml; do
  log "  Applying: $(basename "${role_file}")"
  "${TCTL[@]}" create -f - --force < "${role_file}"
done

# ── Login Rules ───────────────────────────────────────────────────────────────
log "Applying Login Rules..."
for rule_file in "${ROOT_DIR}/teleport/rules/"*.yaml; do
  log "  Applying: $(basename "${rule_file}")"
  "${TCTL[@]}" create -f - --force < "${rule_file}"
done

# ── Bot and token resources ───────────────────────────────────────────────────
log "Applying bot and token resources..."
for f in "${ROOT_DIR}/teleport/bots/"*.yaml "${ROOT_DIR}/teleport/tokens/"*.yaml; do
  [[ -f "${f}" ]] || continue
  log "  Applying: $(basename "${f}")"
  "${TCTL[@]}" create -f - --force < "${f}"
done

# ── OIDC Connector (template: requires env vars) ──────────────────────────────
[[ -n "${TELEPORT_DOMAIN:-}" ]] \
  || fail "TELEPORT_DOMAIN not set in config.env"
[[ -n "${GOOGLE_ADMIN_EMAIL:-}" ]] \
  || fail "GOOGLE_ADMIN_EMAIL not set in config.env"
[[ -n "${GOOGLE_OAUTH_CLIENT_ID:-}" ]] \
  || fail "GOOGLE_OAUTH_CLIENT_ID not set in config.env — required for Google OIDC connector"
[[ -n "${GOOGLE_OAUTH_CLIENT_SECRET:-}" ]] \
  || fail "GOOGLE_OAUTH_CLIENT_SECRET not set in config.env — required for Google OIDC connector"

log "Applying Google OIDC connector..."
envsubst < "${ROOT_DIR}/teleport/connectors/google-oidc.yaml.tpl" \
  | "${TCTL[@]}" create -f - --force

log ""
log "Teleport config applied."
log "  Roles: role-base, role-kube-access, role-ssh-access, role-ssh-root-access"
log "  Login Rule: google-groups-to-team"
log "  OIDC Connector: google"
log ""
log "Set connector as default SSO (run once):"
log "  kubectl -n teleport exec deploy/teleport-auth -- tctl edit cap"
log "  # Set spec.oidc.connector_name: google"
