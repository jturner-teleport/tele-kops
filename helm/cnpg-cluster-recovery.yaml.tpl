# cnpg-cluster-recovery.yaml.tpl — CloudNativePG Cluster for recovery from S3 backup.
# Used when a base backup already exists in S3 (e.g. after make down / make up).
# Processed by spin-up.sh via envsubst.
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
  # See cnpg-cluster-initdb.yaml.tpl for full notes. On recovery from S3
  # backup, CNPG re-applies the managed role spec — so even if the recovered
  # DB has a stale password hash for access_graph, CNPG resets it to match
  # the access-graph-pg-creds Secret.
  managed:
    roles:
      - name: access_graph
        ensure: present
        login: true
        passwordSecret:
          name: access-graph-pg-creds

  bootstrap:
    recovery:
      source: teleport-postgres-backup

  externalClusters:
  - name: teleport-postgres-backup
    barmanObjectStore:
      destinationPath: s3://${TELEPORT_PG_WAL_BUCKET}/cnpg
      serverName: teleport-postgres
      s3Credentials:
        inheritFromIAMRole: true

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
