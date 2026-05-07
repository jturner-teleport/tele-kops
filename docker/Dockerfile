FROM ghcr.io/cloudnative-pg/postgresql:17
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-17-wal2json \
    && rm -rf /var/lib/apt/lists/*
USER 26
