# Access Graph SQL Queries

Teleport's Access Graph (Identity Security) component writes a live graph of all
identities, roles, resources, and access paths into a CNPG-managed Postgres
database. This document describes the schema and provides verified SQL queries
you can run directly against the database for security audits, RBAC reviews, and
ad-hoc investigation.

---

## Database layout

| Item | Value |
|------|-------|
| Database name | `access_graph` |
| Schema pattern | `tenant_<uuid>` — one schema per Teleport cluster |
| Internal host | `teleport-postgres-rw.teleport.svc.cluster.local:5432` |
| User | `access_graph` |
| Password | Secret `access-graph-pg-creds` in the `teleport` namespace, key `password` |

The Access Graph component writes exclusively within its tenant schema. If you
have a single Teleport cluster there will be exactly one `tenant_*` schema.

---

## Getting a psql shell

```bash
# Fetch the password from the cluster secret
PGPASS=$(kubectl -n teleport get secret access-graph-pg-creds \
  -o jsonpath='{.data.password}' | base64 -d)

# Open an interactive psql session on the primary pod
kubectl -n teleport exec -it teleport-postgres-1 -- \
  env PGPASSWORD="$PGPASS" \
  psql -h 127.0.0.1 -U access_graph -d access_graph
```

Inside psql, discover the tenant schema and set the search path:

```sql
\dn                                         -- list schemas; look for tenant_<uuid>
SET search_path TO tenant_3b228468_2445_4972_a8ea_3c56e698ce4a;
```

Replace the UUID above with the value returned by `\dn` for your cluster.

---

## Schema reference

### `nodes` — every entity in the access graph

```
nodes(
  id          uuid PRIMARY KEY,
  kind        text,      -- identity | identity_group | resource | resource_group | action
  subkind     text,      -- see table below
  source      text,
  value       jsonb,     -- GIN-indexed; shape varies by kind
  origin_type text
)
```

| `kind` | `subkind` | Represents |
|--------|-----------|------------|
| `identity` | `user` | A Teleport user (human or bot) |
| `identity` | `resource` | A resource-level identity principal |
| `identity_group` | `role` | A Teleport role |
| `resource` | `ssh` / `kubernetes` / `app` / `database` / `desktop` | A registered Teleport resource |
| `resource_group` | _(varies)_ | A label-match resource group |
| `action` | `ssh` / `kubernetes` / `app` / `database` / `desktop` / `impersonation` / `can_request` / `can_review` | A per-role per-resource-kind allow rule |

**JSONB shape examples:**

`identity/user`:
```json
{
  "name": "admin",
  "traits": { ... },
  "properties": {
    "standing_privileges": 4,
    "identity_groups": 1,
    "weakest_mfa_device_kind": "TOTP",
    "is_crown_jewel": false
  },
  "login_status": { "is_locked": false, "is_deleted": false }
}
```

`identity_group/role`:
```json
{
  "name": "role-base",
  "properties": {
    "hash": "...",
    "teleport": {
      "description": "...",
      "require_mfa_type": "OFF",
      "trusted_device": "...",
      "max_session_ttl": 108000000000000,
      "ssh": { "logins": { "original_values": ["ubuntu", "root"] } }
    }
  }
}
```

`resource`:
```json
{ "name": "grafana", "labels": { "app": "grafana", ... } }
```

### `edges` — relationships between nodes

```
edges(
  from_node  uuid REFERENCES nodes(id),
  to_node    uuid REFERENCES nodes(id),
  kind       text,
  properties jsonb
)
```

| `kind` | Direction | Meaning |
|--------|-----------|---------|
| `member_of` | identity → identity_group | User is a member of a role |
| `access` | identity_group → action | Role grants an action rule |
| `access` | action → resource/resource_group | Action rule grants access to resources |
| `requester_of` | identity_group → identity_group | Role can request escalation to target role |
| `reviewer_of` | identity_group → identity_group | Role can approve requests for target role |
| `impersonator_of` | identity → identity_group | Bot identity can impersonate target role |

### `security_alerts` — detected risk findings

```
security_alerts(
  id       uuid PRIMARY KEY,
  kind     text,
  source   text,
  severity text,
  status   text,
  data     jsonb
)
```

---

## Queries

All queries below assume you have run `SET search_path TO tenant_<uuid>;` first.

---

### Q1: Users — standing privileges, MFA strength, and lock status

What level of standing access does each user have, and what MFA method are they
enrolled in? `standing_privileges` is an integer score computed by Access Graph
that reflects how many sensitive roles/permissions a user holds without needing
an access request. Higher is riskier. `weakest_mfa_device_kind` surfaces the
weakest authenticator on the account (e.g. `TOTP` is weaker than `WEBAUTHN`).

**Expected output:** One row per user, ordered from highest to lowest standing
privilege score.

```sql
SELECT
  value->>'name'                                  AS user,
  value->'properties'->>'standing_privileges'     AS standing,
  value->'properties'->>'identity_groups'         AS roles_count,
  value->'properties'->>'weakest_mfa_device_kind' AS mfa,
  value->'properties'->>'is_crown_jewel'          AS crown_jewel,
  value->'login_status'->>'is_locked'             AS locked
FROM nodes WHERE kind='identity' AND subkind='user'
ORDER BY (value->'properties'->>'standing_privileges')::int DESC;
```

---

### Q2: Dead roles (no members, no escalation references)

Which roles have no users assigned to them and are not the target of any access
request or reviewer chain? These are dead weight — they increase review surface
area without providing access to anyone and are candidates for cleanup.

**Expected output:** One row per unused role with its description.

```sql
SELECT r.value->>'name' AS role,
       r.value->'properties'->'teleport'->>'description' AS description
FROM nodes r
WHERE r.kind='identity_group' AND r.subkind='role'
  AND NOT EXISTS (SELECT 1 FROM edges e WHERE e.to_node=r.id AND e.kind IN ('member_of','impersonator_of'))
  AND NOT EXISTS (SELECT 1 FROM edges e WHERE e.to_node=r.id AND e.kind IN ('requester_of','reviewer_of'))
ORDER BY role;
```

---

### Q3: Standing SSH access (user → role → SSH logins)

Show every user's direct SSH login list inherited through standing role
membership. This is the complete picture of who can SSH into nodes without
submitting an access request, and which UNIX logins they'd land as.

**Expected output:** One row per (user, role) pair with the list of allowed
logins as a JSONB array.

```sql
SELECT DISTINCT
  u.value->>'name' AS user,
  r.value->>'name' AS role,
  a.value->'properties'->'teleport'->'ssh'->'logins'->'original_values' AS logins
FROM edges m
JOIN nodes u ON u.id=m.from_node AND u.kind='identity'
JOIN nodes r ON r.id=m.to_node   AND r.kind='identity_group'
JOIN edges ra ON ra.from_node=r.id AND ra.kind='access'
JOIN nodes a ON a.id=ra.to_node   AND a.kind='action' AND a.subkind='ssh'
WHERE m.kind='member_of';
```

---

### Q4: Bots — which roles they can impersonate

Which bot identities exist and what Teleport roles can each one impersonate?
Bot impersonation grants the bot the full permission set of the target role, so
this query surfaces all machine-identity lateral-movement paths.

**Expected output:** One row per (bot, target role) pair.

```sql
SELECT u.value->>'name' AS bot, r.value->>'name' AS impersonates_role
FROM edges e
JOIN nodes u ON u.id=e.from_node
JOIN nodes r ON r.id=e.to_node
WHERE e.kind='impersonator_of';
```

---

### Q5: Access request escalation paths

Which roles can request escalation to which other roles? This maps the full
JIT (just-in-time) access topology — useful for validating that escalation paths
follow the principle of least privilege and have no unexpected shortcuts.
Rows for built-in requester roles (`requester`, `okta-requester`) are excluded.

**Expected output:** One row per (base role, requestable role) pair.

```sql
SELECT r1.value->>'name' AS base_role, r2.value->>'name' AS can_request
FROM edges e
JOIN nodes r1 ON r1.id=e.from_node
JOIN nodes r2 ON r2.id=e.to_node
WHERE e.kind='requester_of'
  AND r1.value->>'name' NOT IN ('requester','okta-requester')
ORDER BY base_role, can_request;
```

---

### Q6: Reviewers per request target

For each role that can be requested, which other roles are designated as
reviewers? A role with no reviewers is un-approvable; a role with too many
reviewers may indicate overly broad approval authority.

**Expected output:** One row per target role with a comma-separated list of
reviewer roles.

```sql
SELECT r2.value->>'name' AS target_role,
       array_agg(DISTINCT r1.value->>'name' ORDER BY r1.value->>'name') AS reviewers
FROM edges e
JOIN nodes r1 ON r1.id=e.from_node
JOIN nodes r2 ON r2.id=e.to_node
WHERE e.kind='reviewer_of' AND r2.value->>'name' LIKE 'role-%'
GROUP BY target_role
ORDER BY target_role;
```

---

### Q7: Resource inventory

A full inventory of every Teleport resource registered in the cluster, grouped
by type. Use the labels column to confirm expected label coverage (env, team,
etc.) or spot resources that escaped labelling.

**Expected output:** One row per resource, ordered by type then name.

```sql
SELECT subkind AS kind, value->>'name' AS name, value->'labels' AS labels
FROM nodes WHERE kind='resource' ORDER BY subkind, name;
```

---

### Q8: Blast radius per role (top 25)

For each role, count the number of distinct resource groups it grants access to
(directly through action nodes). Roles with a high count have a large blast
radius — if their member accounts are compromised, many resources are reachable.

**Expected output:** Up to 25 rows, highest blast radius first.

```sql
SELECT r.value->>'name' AS role, count(DISTINCT e2.to_node) AS resource_groups_granted
FROM nodes r
JOIN edges e1 ON e1.from_node=r.id AND e1.kind='access'
JOIN nodes a  ON a.id=e1.to_node   AND a.kind='action'
JOIN edges e2 ON e2.from_node=a.id AND e2.kind='access'
WHERE r.kind='identity_group' AND r.subkind='role'
GROUP BY role
ORDER BY resource_groups_granted DESC
LIMIT 25;
```

---

### Q9: Wildcard-access roles

Which roles grant access to the `{"*":"*"}` resource group — i.e., every
resource in the cluster regardless of labels? These roles bypass label-based
segmentation entirely and represent the highest-privilege paths.

**Expected output:** One row per (role, resource kind) pair where wildcard
access is granted.

```sql
SELECT DISTINCT r.value->>'name' AS role, a.subkind AS resource_kind
FROM edges e1
JOIN nodes r  ON r.id=e1.from_node AND r.kind='identity_group'
JOIN nodes a  ON a.id=e1.to_node   AND a.kind='action'
JOIN edges e2 ON e2.from_node=a.id
JOIN nodes rg ON rg.id=e2.to_node  AND rg.kind='resource_group'
WHERE rg.value->>'name' = '{"*":"*"}'
ORDER BY role, resource_kind;
```

---

### Q10: Roles requiring MFA or trusted-device verification

Which roles enforce additional assurance (MFA or hardware device trust) at the
action level? Cross-referencing with Q9 (wildcard roles) reveals whether your
most powerful roles have adequate assurance requirements.

**Expected output:** One row per role that has `require_mfa_type != 'OFF'` or
`trusted_device = 'required'`.

```sql
SELECT DISTINCT value->>'name' AS role,
       value->'properties'->'teleport'->>'require_mfa_type' AS mfa,
       value->'properties'->'teleport'->>'trusted_device'   AS trusted_device
FROM nodes
WHERE kind='action'
  AND (value->'properties'->'teleport'->>'require_mfa_type' <> 'OFF'
       OR value->'properties'->'teleport'->>'trusted_device' = 'required')
ORDER BY role;
```

---

### Q11: Active security alerts

All security alerts detected by Access Graph, most recent first. The `data`
column contains the full structured finding. Filter by `severity` or `status`
to focus on open critical issues.

**Expected output:** Up to 50 rows of alerts ordered by creation time
descending. Empty result means no alerts have been raised.

```sql
SELECT severity, status, kind, data->>'created_at' AS created_at, data
FROM security_alerts
ORDER BY (data->>'created_at') DESC
LIMIT 50;
```
