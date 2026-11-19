#!/bin/bash
# get-venera: Venera's macOS VM script, from the newest release, on a Proxmox VE node. Paste into the node's shell
# (Datacenter > the node > Shell, or ssh root@node):
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/jazzphone/venera/main/get-venera.sh)"
#
# It downloads the host package (Venera-host-VERSION.tar.gz) into /root/venera, checks it (GitHub's checksum of the
# download, then the package's own SHA256SUMS), unpacks it, and starts proxmox-macos-vm.sh in it, which asks its
# questions and shows its plan before it changes anything. Run it again later for the script's other choices
# (Finish, Upgrade, the Mac identity), or run /root/venera/Venera-host-VERSION/proxmox-macos-vm.sh directly.
#
#   VENERA_VERSION=0.1.6   that release instead of the newest
#   GH_TOKEN=...           a GitHub token, for a private copy of the repository (also pass it to curl above:
#                          -H "Authorization: Bearer $GH_TOKEN")
set -euo pipefail
REPO=${VENERA_REPO:-jazzphone/venera}
DIR=${VENERA_DIR:-/root/venera}
die() { echo "get-venera: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run it as root, on a Proxmox VE node's shell"
command -v pveversion >/dev/null || [ -n "${VENERA_NO_PVE:-}" ] || die "this isn't a Proxmox VE node (no pveversion)"
for c in curl python3 tar sha256sum; do command -v $c >/dev/null || die "needs $c"; done

AUTH=()
[ -n "${GH_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer $GH_TOKEN")
LIST=$(curl -fsSL "${AUTH[@]}" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/releases?per_page=30") ||
  die "couldn't read $REPO's releases from GitHub (a private repository needs GH_TOKEN)"

# the release (VENERA_VERSION's, or the newest vX.Y.Z, pre-releases included) and its host package
read -r VER ASSET_API ASSET_URL DIGEST < <(python3 -c '
import json, os, sys
want = os.environ.get("VENERA_VERSION", "").lstrip("v")
for r in json.loads(sys.stdin.read()):
    tag = r.get("tag_name", "")
    if r.get("draft") or not tag.startswith("v") or (want and tag != "v" + want):
        continue
    for a in r.get("assets", []):
        if a["name"].startswith("Venera-host-") and a["name"].endswith(".tar.gz"):
            print(tag[1:], a["url"], a["browser_download_url"], (a.get("digest") or "-").replace("sha256:", ""))
            sys.exit(0)
' <<<"$LIST") || die "no release${VENERA_VERSION:+ $VENERA_VERSION} with a host package (Venera-host-VERSION.tar.gz)"

KIT=$DIR/Venera-host-$VER
TGZ=$DIR/Venera-host-$VER.tar.gz
mkdir -p "$DIR"
echo "Venera $VER: the host package into $DIR"
if [ -n "${GH_TOKEN:-}" ]; then   # a private repository's assets come through the API
  curl -fL --progress-bar "${AUTH[@]}" -H "Accept: application/octet-stream" -o "$TGZ.part" "$ASSET_API"
else
  curl -fL --progress-bar -o "$TGZ.part" "$ASSET_URL"
fi || die "the download failed"
if [ "$DIGEST" != - ]; then
  echo "$DIGEST  $TGZ.part" | sha256sum -c --quiet - || die "the download doesn't match GitHub's checksum"
fi
mv "$TGZ.part" "$TGZ"
rm -rf "$KIT.new" && mkdir "$KIT.new"
tar -xzf "$TGZ" -C "$KIT.new" --strip-components=1 || die "couldn't unpack $TGZ"
if [ -f "$KIT.new/SHA256SUMS" ]; then
  (cd "$KIT.new" && sha256sum -c --quiet SHA256SUMS) || die "the package's files don't match its SHA256SUMS"
fi
rm -rf "$KIT" && mv "$KIT.new" "$KIT"
[ -x "$KIT/proxmox-macos-vm.sh" ] || die "no proxmox-macos-vm.sh in the package"
echo "Starting $KIT/proxmox-macos-vm.sh"
echo
[ -n "${VENERA_NO_RUN:-}" ] && exit 0
cd "$KIT"
exec ./proxmox-macos-vm.sh </dev/tty
