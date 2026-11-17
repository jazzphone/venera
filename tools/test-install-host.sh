#!/bin/bash
# test-install-host: packaging/host/install-host.sh in a throwaway Debian container with stand-in Proxmox commands
# (packaging/host/test): install, reinstall, a second VM, status, remove one, uninstall, refusals. Never touches a host.
set -eu
cd "$(dirname "$0")/.."
[ -f dist/Venera-host-$(cat VERSION).tar.gz ] || packaging/make-host.sh >/dev/null
W=$(mktemp -d)
tar -xzf dist/Venera-host-$(cat VERSION).tar.gz -C "$W"
docker run --rm --platform linux/amd64 -v "$W":/work -v "$PWD/packaging/host/test":/test:ro venera-hostvideo-build \
  bash /test/run.sh
rm -rf "$W"
