#!/bin/zsh
# make-pkg: "dist/Install Venera VERSION.pkg" from the release folder make-dist.sh assembled (dist/Venera-VERSION).
#
# The package puts the release folder in /Library/Application Support/Venera/release and runs its install.sh, with
# the Customize choices as flags: Video decoding (--video), the Venera app (else --no-app), the guest agent (else
# --no-agent), Safari WebGL (else --no-system-volume, unless authenticated root is already off). Packages, in install
# order:
#   prep    (hidden)  clears the choice markers
#   video, app, agent, webgl  each leaves a marker (/Library/Application Support/Venera/.choices/NAME)
#   core    (hidden)  the release folder, then install.sh with the markers' flags; asks for the restart
# SIGN_ID="Developer ID Installer: NAME (TEAM)" signs it (productbuild --sign); unsigned otherwise.
# Then dist/Venera-Tools-VERSION.iso: the package and a read-me (packaging/tools-readme.txt) on a CD image, "Venera
# Tools", to attach to a VM as a CD drive (macOS shows it on the desktop); no network needed.
set -euo pipefail
cd "${0:A:h}/.."
VERSION=$(cat VERSION)
D=dist/Venera-$VERSION
[[ -x $D/install.sh ]] || { echo "no $D: run packaging/make-dist.sh"; exit 1; }
B=build/pkg
rm -rf $B && mkdir -p $B/pkgs $B/res
REL="$B/root/Library/Application Support/Venera/release"
mkdir -p "$REL" && cp -R $D/. "$REL/"
C='/Library/Application Support/Venera/.choices'

script() { # script NAME BODY: a scripts-only folder with a postinstall
  mkdir -p $B/scripts/$1
  printf '#!/bin/bash\n%s\n' "$2" >$B/scripts/$1/postinstall
  chmod 755 $B/scripts/$1/postinstall
}
script prep "rm -rf '$C'; mkdir -p '$C'; exit 0"
for c in video app agent webgl; do script $c "mkdir -p '$C' && touch '$C/$c'; exit 0"; done
script core "$(cat <<'SH'
V="/Library/Application Support/Venera"
C="$V/.choices"
ARGS=(--set-security)
[ -e "$C/video" ] && ARGS+=(--video)
[ -e "$C/app" ] || ARGS+=(--no-app)
[ -e "$C/agent" ] || ARGS+=(--no-agent)
if [ ! -e "$C/webgl" ] && ! csrutil authenticated-root status 2>/dev/null | grep -qi disabled; then
  ARGS+=(--no-system-volume)
fi
rm -rf "$C"
# what runs as root below is root's, whoever built the package
chown -R root:wheel "$V/release" && chmod -R go-w "$V/release" || exit 1
echo "Venera: install.sh ${ARGS[*]}"
"$V/release/install.sh" "${ARGS[@]}" 2>&1 | tee "$V/install.log"
exit "${PIPESTATUS[0]}"
SH
)"

for c in prep video app agent webgl; do
  pkgbuild --nopayload --scripts $B/scripts/$c --identifier local.homelab.venera.$c --version $VERSION \
    $B/pkgs/$c.pkg >/dev/null
done
# the release's bundles stay where they are (pkgbuild would otherwise let Installer "relocate" a bundle onto any
# copy with the same identifier it finds, e.g. /Applications/Venera.app)
pkgbuild --analyze --root $B/root $B/components.plist >/dev/null
i=0
while plutil -extract $i.RootRelativeBundlePath raw -o - $B/components.plist >/dev/null 2>&1; do
  plutil -replace $i.BundleIsRelocatable -bool NO $B/components.plist
  plutil -replace $i.BundleOverwriteAction -string upgrade $B/components.plist
  i=$((i + 1))
done
pkgbuild --root $B/root --component-plist $B/components.plist --scripts $B/scripts/core \
  --identifier local.homelab.venera.core --version $VERSION --ownership recommended --install-location / \
  $B/pkgs/core.pkg >/dev/null

sed "s/@VERSION@/$VERSION/g" packaging/pkg/Distribution.xml >$B/Distribution.xml
for f in welcome conclusion; do sed "s/@VERSION@/$VERSION/g" packaging/pkg/$f.html >$B/res/$f.html; done
# the license as a page (it is Markdown: headings, paragraphs, links)
python3 -I - LICENSE $B/res/LICENSE.html <<'PY'
import html, re, sys
out = ['<!DOCTYPE html><html><head><meta charset="utf-8"><style>body{font:12px -apple-system,sans-serif;line-height:1.4}'
       'h1{font-size:15px}h2{font-size:13px;margin:14px 0 4px}p{margin:0 0 8px}</style></head><body>']
for block in open(sys.argv[1]).read().split('\n\n'):
    t = ' '.join(block.split())
    if not t:
        continue
    m = re.match(r'(#+) (.*)', t)
    if m:
        n = min(len(m.group(1)), 2)
        out.append(f'<h{n}>{html.escape(m.group(2))}</h{n}>')
        continue
    t = html.escape(t)
    t = re.sub(r'&lt;(https?://[^&]+)&gt;', r'<a href="\1">\1</a>', t)
    t = re.sub(r'\[([^\]]+)\]\([^)]*\)', r'\1', t)
    out.append(f'<p>{t}</p>')
open(sys.argv[2], 'w').write('\n'.join(out) + '</body></html>\n')
PY
cp build/Venera.iconset/icon_128x128.png $B/res/background.png
OUT="dist/Install Venera $VERSION.pkg"
SIGN=()
[[ -n "${SIGN_ID:-}" ]] && SIGN=(--sign "$SIGN_ID")
productbuild --distribution $B/Distribution.xml --package-path $B/pkgs --resources $B/res "${SIGN[@]}" "$OUT" >/dev/null
echo "$OUT ($([[ -n "${SIGN_ID:-}" ]] && echo "signed: $SIGN_ID" || echo unsigned))"
shasum -a 256 "$OUT"
# the CD: Venera Tools
T=$B/tools && rm -rf $T && mkdir -p $T
cp "$OUT" $T/
sed "s/@VERSION@/$VERSION/g" packaging/tools-readme.txt >"$T/Read Me.txt"
ISO=dist/Venera-Tools-$VERSION.iso
rm -f $ISO
hdiutil makehybrid -quiet -iso -joliet -default-volume-name "Venera Tools" -o $ISO $T
echo "$ISO"
shasum -a 256 $ISO
