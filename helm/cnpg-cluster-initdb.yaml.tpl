# cnpg-cluster-initdb.yaml.tpl — CloudNativePG Cluster for first-time bootstrap.
# Used when no base backup exists in S3. Processed by spin-up.sh via envsubst.
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: teleport-postgres
  namespace: teleport
spec:
  instances: 1
  imageName: ghcr.io/jturner-teleport/postgres-wal2json:17
  imagePullSecrets:
    - name: ghcr-pull-secret

  postgresql:
    parameters:
      wal_level: logical
      max_replication_slots: "10"
      max_wal_senders: "10"

  storage:
    size: 10Gi

  # Declarative role + database management for the Access Graph user.
  # The 'access_graph' user owns the 'access_graph' database (defined as a
  # postgresql.cnpg.io/v1 Database resource in helm/cnpg-access-graph-db.yaml).
  # The user's password is read from the 'access-graph-pg-creds' Secret created
  # by spin-up.sh.
  managed:
    roles:
      - name: access_graph
        ensure: present
        login: true
        passwordSecret:
          name: access-graph-pg-creds

  bootstrap:
    initdb:
      database: teleport
      owner: teleport
      postInitSQL:
        - ALTER ROLE teleport REPLICATION;

  backup:
    barmanObjectStore:
      destinationPath: s3://${TELEPORT_PG_WAL_BUCKET}/cnpg
      s3Credentials:
        inheritFromIAMRole: true
      wal:
        compression: gzip
      data:
        compression: gzip
    retentionPolicy: "7d"
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: teleport-postgres-daily
  namespace: teleport
spec:
  schedule: "0 2 * * *"
  backupOwnerReference: self
  cluster:
    name: teleport-postgres
