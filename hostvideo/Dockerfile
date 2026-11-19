# The build environment for Venera's host video program (x86-64 Debian 13, the Proxmox host's base).
# Debian pinned by digest: packaging/UPSTREAM DEBIAN_IMAGE (tools/make-sources.sh checks they agree)
FROM --platform=linux/amd64 debian:trixie@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential nasm pkg-config libva-dev libdrm-dev ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
