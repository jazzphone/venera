#!/bin/zsh
# Build, copy to the Proxmox host, inject into VM 108's OpenCore, boot, and print the driver's log.
#   tools/deploy.sh            build + deploy + logs
#   tools/deploy.sh logs       logs only
#   tools/deploy.sh disable    turn the kext off in OpenCore and reboot (recovery)
set -euo pipefail
cd "${0:A:h}/.."
HOST=root@pve-host
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias=pve-host -i ~/.ssh/vgpu_host_key)
SCP=(scp -q -o BatchMode=yes -o HostKeyAlias=pve-host -i ~/.ssh/vgpu_host_key)

"${SSH[@]}" $HOST 'mkdir -p /root/vgpu'
"${SCP[@]}" tools/vm-remote.sh tools/oc_kext.py $HOST:/root/vgpu/

case "${1:-deploy}" in
deploy)
  # 1. core via OpenCore (+ SIP 0x201) and boot; 2. framebuffer into the AuxKC and reboot; 3. logs
  tools/build.sh >/dev/null
  tar -czf build/VirtioGPUFramebuffer.tgz -C build VirtioGPUFramebuffer.kext
  "${SSH[@]}" $HOST 'rm -rf /root/vgpu/VirtioGPU.kext'
  "${SCP[@]}" -r build/VirtioGPU.kext build/VirtioGPUFramebuffer.tgz $HOST:/root/vgpu/
  "${SSH[@]}" $HOST 'bash /root/vgpu/vm-remote.sh deploy /root/vgpu/VirtioGPU.kext'
  sleep 10
  "${SSH[@]}" $HOST 'bash /root/vgpu/vm-remote.sh aux /root/vgpu/VirtioGPUFramebuffer.tgz VirtioGPUFramebuffer.kext'
  sleep 20
  "${SSH[@]}" $HOST 'bash /root/vgpu/vm-remote.sh logs'
  ;;
core) # only the OpenCore-injected core, no AuxKC step
  tools/build.sh >/dev/null
  "${SSH[@]}" $HOST 'rm -rf /root/vgpu/VirtioGPU.kext'
  "${SCP[@]}" -r build/VirtioGPU.kext $HOST:/root/vgpu/
  "${SSH[@]}" $HOST 'bash /root/vgpu/vm-remote.sh deploy /root/vgpu/VirtioGPU.kext'
  sleep 20
  "${SSH[@]}" $HOST 'bash /root/vgpu/vm-remote.sh logs'
  ;;
logs)
  "${SSH[@]}" $HOST 'bash /root/vgpu/vm-remote.sh logs'
  ;;
disable)
  "${SSH[@]}" $HOST 'bash /root/vgpu/vm-remote.sh disable VirtioGPU.kext'
  ;;
shots) # tools/deploy.sh shots COUNT INTERVAL -> build/shots/NN.png
  "${SSH[@]}" $HOST "bash /root/vgpu/vm-remote.sh shots ${2:-20} ${3:-3}"
  rm -rf build/shots && mkdir -p build/shots
  "${SCP[@]}" "$HOST:/tmp/vgpu-shots/*.png" build/shots/
  ls build/shots | wc -l
  ;;
esac
