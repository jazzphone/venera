# The build environment for Venera's host video program (x86-64 Debian 13, the Proxmox host's base).
FROM --platform=linux/amd64 debian:trixie
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential nasm pkg-config libva-dev libdrm-dev ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
