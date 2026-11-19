#!/bin/zsh
# seed-pool (0.1.2): VM 108's translation pool (/Library/GPUBundles/Venera/cache) as the package's seed, so a fresh
# install's first boot finds Core Animation's shaders already translated (a fresh install translated 167 shaders, 125 s
# of CPU, 104 s of it WindowServer's, in its first minutes). Translations are keyed by the translator and the shader
# text, so the seed is good for one translator on any macOS build (a build's changed shaders just aren't in it):
# packaging/seed/pool-BUILDS-TRANSLATOR.tar.gz, BUILDS the builds it was made on joined by "+". A run on another
# build adds that build's translations to the seed for the same translator; make-dist.sh ships the seed only when the
# translator it builds with matches.
#   tools/seed-pool.sh                                  VM 108's pool
#   SEED_FROM=pool.tar.gz SEED_BUILD=25H123 tools/seed-pool.sh   another VM's (its cache folder's hash-named files, tarred)
# Fill the pool first on a VM with the release's translator (a clean cache, a restart, the system apps, gestures).
set -euo pipefail
cd "${0:A:h}/.."
. tools/host.sh
TR=$(shasum -a 256 build/translator/libnvmtl_translate.dylib | cut -c1-12)
mkdir -p packaging/seed
NEW=$(mktemp -d)
trap 'rm -rf $NEW' EXIT
if [[ -n ${SEED_FROM:-} ]]; then
  BUILD=${SEED_BUILD:?SEED_BUILD: the macOS build SEED_FROM was made on}
  tar -xzf $SEED_FROM -C $NEW
else
  BUILD=$("${SSH[@]}" $H "bash /root/vgpu/vm-remote.sh run 'sw_vers -buildVersion' 30" | tr -d '\r' | grep -E '^[0-9]+[A-Z][0-9]+[a-z]?$' | head -1)
  [[ -n $BUILD ]] || { echo "VM 108's macOS build: no answer"; exit 1; }
  # through the transfer disk (the guest agent's output can't carry megabytes)
  "${SSH[@]}" $H "bash /root/vgpu/vm-remote.sh run 'cd /Library/GPUBundles/Venera/cache && ls | grep -E \"^[0-9a-f]{64}\$\" | tar -czf /var/tmp/venera-seed.tar.gz -T -' 120 &&
    rm -rf /root/vgpu/seed && bash /root/vgpu/vm-remote.sh pull /var/tmp/venera-seed.tar.gz /root/vgpu/seed >/dev/null"
  "${SCP[@]}" $H:/root/vgpu/seed/venera-seed.tar.gz $NEW/in.tar.gz
  tar -xzf $NEW/in.tar.gz -C $NEW && rm $NEW/in.tar.gz
fi
# this translator's seed so far: its translations stay, its builds are named on
OLD=$(ls packaging/seed/pool-*-$TR.tar.gz 2>/dev/null | head -1 || true)
BUILDS=$BUILD
if [[ -n $OLD ]]; then
  tar -xzf $OLD -C $NEW
  BUILDS=$(echo ${${OLD:t}#pool-} | cut -d- -f1 | tr '+' '\n' | cat - <(echo $BUILD) | sort -u | paste -sd+ -)
fi
OUT=packaging/seed/pool-$BUILDS-$TR.tar.gz
ABS=$PWD/$OUT
(cd $NEW && ls | grep -E '^[0-9a-f]{64}$' | COPYFILE_DISABLE=1 tar -czf $ABS.new -T -)
tar -tzf $OUT.new >/dev/null && mv $OUT.new $OUT
rm -f $(ls packaging/seed/pool-*.tar.gz | grep -v -x $OUT) 2>/dev/null || true
echo "$OUT: $(tar -tzf $OUT | wc -l | tr -d ' ') translations, $(du -h $OUT | cut -f1)"
