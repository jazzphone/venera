#!/bin/zsh
# seed-pool (0.1.2): VM 108's translation pool (/Library/GPUBundles/Venera/cache) as the package's seed, so a fresh
# install's first boot finds Core Animation's shaders already translated (a fresh install translated 167 shaders, 125 s
# of CPU, 104 s of it WindowServer's, in its first minutes). Translations are keyed by the translator and the shader
# text, so the seed is good for one macOS build and one translator: packaging/seed/pool-BUILD-TRANSLATOR.tar.gz, and
# make-dist.sh ships it only when the translator it builds with matches.
# Fill the pool first on a VM with the release's translator (a clean cache, a restart, the system apps, gestures).
set -euo pipefail
cd "${0:A:h}/.."
. tools/host.sh
TR=$(shasum -a 256 build/translator/libnvmtl_translate.dylib | cut -c1-12)
BUILD=$("${SSH[@]}" $H "bash /root/vgpu/vm-remote.sh run 'sw_vers -buildVersion' 30" | tr -d '\r' | grep -E '^[0-9]+[A-Z][0-9]+[a-z]?$' | head -1)
[[ -n $BUILD ]] || { echo "VM 108's macOS build: no answer"; exit 1; }
mkdir -p packaging/seed
OUT=packaging/seed/pool-$BUILD-$TR.tar.gz
# through the transfer disk (the guest agent's output can't carry megabytes)
"${SSH[@]}" $H "bash /root/vgpu/vm-remote.sh run 'cd /Library/GPUBundles/Venera/cache && ls | grep -E \"^[0-9a-f]{64}\$\" | tar -czf /var/tmp/venera-seed.tar.gz -T -' 120 &&
  rm -rf /root/vgpu/seed && bash /root/vgpu/vm-remote.sh pull /var/tmp/venera-seed.tar.gz /root/vgpu/seed >/dev/null"
"${SCP[@]}" $H:/root/vgpu/seed/venera-seed.tar.gz $OUT.new
tar -tzf $OUT.new >/dev/null && mv $OUT.new $OUT
rm -f $(ls packaging/seed/pool-*.tar.gz | grep -v -x $OUT) 2>/dev/null || true
echo "$OUT: $(tar -tzf $OUT | wc -l | tr -d ' ') translations, $(du -h $OUT | cut -f1)"
