# Access Graph SQL Queries

Access Graph provides a graph-based view of all identities, resources, and
access paths in the Teleport cluster. These queries demonstrate key security
insights available via the Access Graph interface in the Teleport UI or API.

> **Note:** Access Graph's actual SQL schema may differ from the examples below.
> These are illustrative queries showing the *types* of security questions
> Access Graph can answer. In practice, use the Teleport UI's Access Graph
> query builder, which provides live schema introspection.

## Example Queries

### 1. Overprivileged Users — Root SSH Access

Find users who have access to the `root` login on any SSH node.

```sql
SELECT u.name AS user, r.name AS role, n.hostname AS node
FROM users u
JOIN user_roles ur ON u.id = ur.user_id
JOIN roles r ON ur.role_id = r.id
JOIN role_node_access rna ON r.id = rna.role_id
JOIN nodes n ON rna.node_id = n.id
WHERE 'root' = ANY(rna.logins)
ORDER BY u.name, n.hostname;
```

**Security insight:** Identifies the blast radius if any of these accounts are
compromised. Roles granting root logins should be tightly scoped and reviewed.

---

### 2. Unused Access — Roles Assigned But Never Exercised

Find roles assigned to users who have never created a session with those roles,
for assignments older than 30 days.

```sql
SELECT u.name AS user, r.name AS role, ur.assigned_at
FROM users u
JOIN user_roles ur ON u.id = ur.user_id
JOIN roles r ON ur.role_id = r.id
LEFT JOIN sessions s ON s.user_id = u.id AND s.role_id = r.id
WHERE s.id IS NULL
  AND ur.assigned_at < NOW() - INTERVAL '30 days'
ORDER BY ur.assigned_at;
```

**Security insight:** Surfaces standing access that violates least-privilege.
Unused roles are candidates for revocation or conversion to just-in-time
access requests.

---

### 3. Access Paths to Production Resources

Show all access paths (user → role → node) for nodes labelled `env=production`.

```sql
SELECT u.name AS user, r.name AS role, n.hostname, n.labels->>'env' AS env
FROM users u
JOIN user_roles ur ON u.id = ur.user_id
JOIN roles r ON ur.role_id = r.id
JOIN role_node_access rna ON r.id = rna.role_id
JOIN nodes n ON rna.node_id = n.id
WHERE n.labels->>'env' = 'production'
ORDER BY n.hostname, u.name;
```

**Security insight:** A complete inventory of who can reach production. Useful
for compliance audits and validating that only approved roles have production
access.

---

### 4. Access Request Approval Patterns

Find which reviewers most frequently approve access requests and for which
roles, over the last 90 days.

```sql
SELECT reviewer, requested_role, COUNT(*) AS approvals
FROM access_requests
WHERE state = 'approved'
  AND created_at > NOW() - INTERVAL '90 days'
GROUP BY reviewer, requested_role
ORDER BY approvals DESC
LIMIT 20;
```

**Security insight:** Detects rubber-stamping reviewers and reveals which
elevated roles are most in demand. High approval counts for a single reviewer
may indicate approval fatigue or a missing standing-access policy.

---

### 5. Lateral Movement Risk — Users with Multiple High-Privilege Roles

Identify users who hold both Kubernetes and SSH root access, creating potential
lateral movement paths between workload types.

```sql
SELECT u.name AS user,
  COUNT(DISTINCT r.name) AS privilege_role_count,
  ARRAY_AGG(DISTINCT r.name ORDER BY r.name) AS roles
FROM users u
JOIN user_roles ur ON u.id = ur.user_id
JOIN roles r ON ur.role_id = r.id
WHERE r.name IN ('role-ssh-root-access', 'role-kube-access', 'editor', 'auditor')
GROUP BY u.name
HAVING COUNT(DISTINCT r.name) > 1
ORDER BY privilege_role_count DESC;
```

**Security insight:** A user with both SSH root and Kubernetes cluster-admin
access can pivot between the control plane and nodes without triggering separate
access controls. These accounts warrant MFA enforcement and session recording.
