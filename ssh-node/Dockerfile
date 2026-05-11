# ssh-node image — Ubuntu 22.04 base with the Teleport Enterprise binary copied
# from the official distroless image, plus an unprivileged `ubuntu` Linux user.
# Built + pushed to ghcr.io by .github/workflows/build-ssh-node.yml on changes
# under ssh-node/**.
#
# When deployed (helm/ssh-node-deployment.yaml.tpl), the container runs as a
# Teleport node (role=node), reverse-tunnels to the proxy, and serves SSH
# sessions for users who hold role-ssh-access (login: ubuntu, no sudo) or
# role-ssh-root-access (login: root). Privilege separation lives at the OS
# layer: there is NO sudo on this image, so the only path to root is to
# request role-ssh-root-access (which requires manual review).

FROM public.ecr.aws/gravitational/teleport-ent-distroless:18.7.6 AS teleport-bin

FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash ca-certificates curl iproute2 net-tools \
    && rm -rf /var/lib/apt/lists/*

COPY --from=teleport-bin /usr/local/bin/teleport /usr/local/bin/teleport

# Unprivileged `ubuntu` login for role-ssh-access. No sudo binary on the image,
# no sudoers entry — escalation to root is only possible by requesting
# role-ssh-root-access (which lands the user as root directly via SSH).
RUN useradd --create-home --shell /bin/bash ubuntu

# Teleport's data directory (used for keys/identity caching).
RUN mkdir -p /var/lib/teleport && chown root:root /var/lib/teleport

ENTRYPOINT ["/usr/local/bin/teleport"]
