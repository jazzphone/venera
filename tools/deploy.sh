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
  sleep 45 # let the boot settle: the agent times out on big work right after login
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
test) # build tools/vgputest.c, copy it into the VM, run it as the console user
  tools/build-tools.sh >/dev/null
  "${SCP[@]}" build/vgputest $HOST:/root/vgpu/
  "${SSH[@]}" $HOST "bash /root/vgpu/vm-remote.sh push /root/vgpu/vgputest /tmp/vgputest >/dev/null && bash /root/vgpu/vm-remote.sh run 'chmod +x /tmp/vgputest && sudo -u dev /tmp/vgputest; echo exit \$?'"
  ;;
xfer) # tools/deploy.sh xfer FILE...: onto the VM's transfer disk (/Volumes/VGPU)
  shift
  "${SSH[@]}" $HOST 'mkdir -p /root/vgpu/xfer && rm -rf /root/vgpu/xfer/*'
  "${SCP[@]}" -r "$@" $HOST:/root/vgpu/xfer/
  "${SSH[@]}" $HOST 'bash /root/vgpu/vm-remote.sh xfer /root/vgpu/xfer/*'
  ;;
vk) # Venus: Mesa's ICD + vkprobe over the transfer disk, run as the console user
  tools/build-tools.sh >/dev/null
  "${SSH[@]}" $HOST 'mkdir -p /root/vgpu/xfer && rm -rf /root/vgpu/xfer/*'
  "${SCP[@]}" mesa/out/libvulkan_virtio.dylib build/vkprobe build/vkexec build/vgputest $HOST:/root/vgpu/xfer/
  "${SSH[@]}" $HOST "bash /root/vgpu/vm-remote.sh xfer /root/vgpu/xfer/* >/dev/null; bash /root/vgpu/vm-remote.sh run 'mkdir -p /tmp/vk && cp /Volumes/VGPU/libvulkan_virtio.dylib /Volumes/VGPU/vkprobe /Volumes/VGPU/vkexec /Volumes/VGPU/vgputest /tmp/vk/ && chmod 755 /tmp/vk /tmp/vk/vkprobe /tmp/vk/vkexec /tmp/vk/vgputest && chmod 644 /tmp/vk/libvulkan_virtio.dylib && cd /tmp/vk && sudo -u dev env VN_DEBUG=${VN_DEBUG:-init,result} ./${VKTOOL:-vkprobe} ./libvulkan_virtio.dylib ${VKARGS:-} 2>&1 | tail -70; echo exit \$?' 240"
  ;;
shots) # tools/deploy.sh shots COUNT INTERVAL -> build/shots/NN.png
  "${SSH[@]}" $HOST "bash /root/vgpu/vm-remote.sh shots ${2:-20} ${3:-3}"
  rm -rf build/shots && mkdir -p build/shots
  "${SCP[@]}" "$HOST:/tmp/vgpu-shots/*.png" build/shots/
  ls build/shots | wc -l
  ;;
esac
