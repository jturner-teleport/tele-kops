# ssh-node image — Ubuntu 22.04 base with the Teleport Enterprise binary copied
# from the official distroless image, plus an `ubuntu` Linux user (NOPASSWD sudo).
# Built + pushed to ghcr.io by .github/workflows/build-ssh-node.yml on changes
# under ssh-node/**.
#
# When deployed (helm/ssh-node-deployment.yaml.tpl), the container runs as a
# Teleport node (role=node), reverse-tunnels to the proxy, and serves SSH
# sessions for users who hold role-ssh-access (login: ubuntu) or
# role-ssh-root-access (login: root).

FROM public.ecr.aws/gravitational/teleport-ent-distroless:18.7.6 AS teleport-bin

FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash sudo ca-certificates curl iproute2 net-tools \
    && rm -rf /var/lib/apt/lists/*

COPY --from=teleport-bin /usr/local/bin/teleport /usr/local/bin/teleport

# `ubuntu` user with NOPASSWD sudo (so role-ssh-access users can demonstrate
# limited shell + role-ssh-root-access users get the root login directly).
RUN useradd --create-home --shell /bin/bash ubuntu && \
    echo "ubuntu ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/ubuntu && \
    chmod 440 /etc/sudoers.d/ubuntu

# Teleport's data directory (used for keys/identity caching).
RUN mkdir -p /var/lib/teleport && chown root:root /var/lib/teleport

ENTRYPOINT ["/usr/local/bin/teleport"]
