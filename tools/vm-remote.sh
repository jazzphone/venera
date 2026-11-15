#!/bin/bash
# Runs on the Proxmox host. Deploys a kext into VM 108's OpenCore and boots it, or reads its logs.
#   vm-remote.sh deploy  /root/vgpu/VirtioGPU.kext   # stop VM, inject (enabled), start, wait
#   vm-remote.sh disable VirtioGPU.kext              # stop VM, disable the kext, start, wait
#   vm-remote.sh logs                                # driver log lines + device tree
set -uo pipefail
VM=108
OCDISK=/dev/pve/vm-108-disk-1
MNT=/mnt/oc108
HERE=$(dirname "$0")

agent() { qm guest exec $VM --timeout "${2:-60}" -- /bin/sh -c "$1" | python3 -I -c '
import json, sys
r = json.load(sys.stdin)
sys.stdout.write(r.get("out-data", "")); sys.stderr.write(r.get("err-data", ""))'; }

wait_agent() {
  for i in $(seq 1 60); do
    sleep 5
    if qm guest cmd $VM ping >/dev/null 2>&1; then echo "agent up after $((i * 5)) s"; return 0; fi
  done
  echo "agent did not come up; screen: /tmp/vm108-screen.png"
  echo "screendump /tmp/vm108-screen.png -f png" | qm monitor $VM >/dev/null 2>&1
  return 1
}

stop_vm() {
  if qm status $VM | grep -q running; then
    qm guest exec $VM --timeout 10 -- /sbin/shutdown -h now >/dev/null 2>&1
    for i in $(seq 1 36); do sleep 5; qm status $VM | grep -q stopped && break; done
    qm status $VM | grep -q stopped || { echo "forcing stop"; qm stop $VM; }
  fi
}

with_oc() { # run "$@" with the OpenCore ESP mounted read-write at $MNT
  local loop
  loop=$(losetup -fP --show $OCDISK) || return 1
  mount "${loop}p1" $MNT && "$@"
  local rc=$?
  sync; umount $MNT; losetup -d "$loop"
  return $rc
}

inject() {
  local src=$1 name
  name=$(basename "$src")
  rm -rf "$MNT/EFI/OC/Kexts/$name" && cp -r "$src" "$MNT/EFI/OC/Kexts/$name" &&
    python3 -I "$HERE/oc_kext.py" "$MNT/EFI/OC/config.plist" "$name" enable &&
    python3 -I "$HERE/oc_kext.py" "$MNT/EFI/OC/config.plist" - nopicker &&
    python3 -I "$HERE/oc_kext.py" "$MNT/EFI/OC/config.plist" - csr 0x203 # + unapproved kexts, unrestricted fs (AuxKC in /Library/KernelCollections)
}

# Installs a kext into /Library/Extensions and builds it into the Auxiliary kernel collection.
# This guest agent (mac-guest-agent) takes neither Proxmox's --pass-stdin (MIME base64) nor
# file-write, so the tarball goes in as base64 text, 1 KB per exec argument (4 KB hangs the agent). No network involved.
push_file() { # push_file LOCAL REMOTE
  local b64 i n chunk
  b64=$(base64 -w0 "$1")
  n=${#b64}
  qm guest exec $VM --timeout 20 -- /bin/sh -c "rm -f '$2.b64'" >/dev/null || return 1
  for ((i = 0; i < n; i += 1024)); do
    chunk=${b64:i:1024}
    qm guest exec $VM --timeout 20 -- /bin/sh -c "printf %s '$chunk' >> '$2.b64'" >/dev/null || return 1
  done
  qm guest exec $VM --timeout 20 -- /bin/sh -c "base64 -D -i '$2.b64' -o '$2' && rm '$2.b64'" >/dev/null || return 1
  echo "pushed $1 ($n base64 bytes) to $2"
}

aux_install() {
  local tgz=$1 name=$2
  push_file "$tgz" /tmp/vgpu-aux.tgz || { echo "push failed"; return 1; }
  agent "set -e
    rm -rf /Library/Extensions/$name /tmp/vgpu-aux && mkdir -p /tmp/vgpu-aux
    tar -xzf /tmp/vgpu-aux.tgz -C /tmp/vgpu-aux
    mv /tmp/vgpu-aux/$name /Library/Extensions/$name
    chown -R root:wheel /Library/Extensions/$name && chmod -R 755 /Library/Extensions/$name
    # Build the Auxiliary KC directly (as nvidia-macos-driver's installer does); kernelmanagerd
    # loads it at the next boot. SIP 0x203 lets the unsigned, unapproved kext in and the KC be replaced.
    KC=/Library/KernelCollections/AuxiliaryKernelExtensions.kc
    kmutil create -n aux --volume-root / --allow-missing-kdk --kernel /System/Library/Kernels/kernel \\
      -B /System/Library/KernelCollections/BootKernelExtensions.kc \\
      -S /System/Library/KernelCollections/SystemKernelExtensions.kc \\
      --repository /Library/Extensions -A \$KC.vgpu-new -z > /tmp/vgpu-kmutil.log 2>&1 || { tail -15 /tmp/vgpu-kmutil.log; exit 1; }
    kmutil inspect -a x86_64 -A \$KC.vgpu-new 2>/dev/null | grep -i homelab || { echo 'kmutil left the kext out:'; tail -15 /tmp/vgpu-kmutil.log; exit 1; }
    mv -f \$KC.vgpu-new \$KC && echo \"aux collection rebuilt; loads at next boot\"" 300
}

reboot_vm() {
  qm guest exec $VM --timeout 10 -- /sbin/shutdown -r now >/dev/null 2>&1
  sleep 30
  wait_agent
}

case "$1" in
deploy)
  stop_vm
  with_oc inject "$2" || exit 1
  qm start $VM && wait_agent
  ;;
disable)
  stop_vm
  with_oc python3 -I "$HERE/oc_kext.py" "$MNT/EFI/OC/config.plist" "$2" disable || exit 1
  qm start $VM && wait_agent
  ;;
logs)
  agent 'echo "== probe"; ioreg -w0 -r -c VirtioGPU -a | plutil -extract 0.ProbeLog xml1 -o - - 2>/dev/null | sed -n "s/.*<string>\\(.*\\)<\/string>.*/  \\1/p" | sed "s/&quot;/\\\"/g"; echo "== tree"; ioreg -w0 -r -n S08@1 | grep -E "\\+-o" | head -8 | cut -c1-110; echo "== aux"; kmutil showloaded --collection aux 2>/dev/null | grep -i homelab | cut -c1-110; echo "== framebuffers"; ioreg -w0 -r -c IOFramebuffer | grep -E "\\+-o" | head -6 | cut -c1-110' 120
  ;;
logs-raw)
  agent 'ioreg -w0 -r -c VirtioGPU -l' 90
  ;;
aux) # aux TGZ NAME: install into /Library/Extensions + AuxKC, then reboot
  aux_install "$2" "$3"
  reboot_vm
  ;;
mount) # mount the virtiofs share (the Proxmox host /root/vgpu-share, tag vgpu) at /Volumes/vgpu
  agent 'mkdir -p /Volumes/vgpu; mount | grep -q " /Volumes/vgpu " || mount_virtiofs vgpu /Volumes/vgpu; ls -la /Volumes/vgpu | head -20' 60
  ;;
push) # push LOCAL REMOTE: copy a file into the VM over the guest agent
  push_file "$2" "$3"
  ;;
run) # run 'command': run a shell command in the VM as root, print its output
  agent "$2" "${3:-120}"
  ;;
shots) # shots COUNT INTERVAL: QEMU screenshots into /tmp/vgpu-shots/NN.png
  rm -rf /tmp/vgpu-shots && mkdir -p /tmp/vgpu-shots
  for i in $(seq -w 1 "${2:-20}"); do
    echo "screendump /tmp/vgpu-shots/$i.png -f png" | qm monitor $VM >/dev/null 2>&1
    sleep "${3:-3}"
  done
  ls /tmp/vgpu-shots | wc -l
  ;;
*)
  echo "usage: $0 deploy KEXT | disable NAME | logs | logs-raw | shots COUNT INTERVAL"; exit 2
  ;;
esac
