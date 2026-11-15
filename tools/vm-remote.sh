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
    python3 -I "$HERE/oc_kext.py" "$MNT/EFI/OC/config.plist" - nopicker
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
  agent 'echo "== probe"; ioreg -w0 -r -c VirtioGPU -a | plutil -extract 0.ProbeLog json -o - - 2>/dev/null | tr "," "\n" | sed -E "s/^\[?\"/  /; s/\"\]?$//" || ioreg -w0 -r -c VirtioGPU -a | plutil -p - | sed -n "/ProbeLog/,/]/p"; echo "== tree"; ioreg -w0 -r -n S08@1 | grep -E "\+-o" | head -4 | cut -c1-110' 90
  ;;
logs-raw)
  agent 'ioreg -w0 -r -c VirtioGPU -l' 90
  ;;
*)
  echo "usage: $0 deploy KEXT | disable NAME | logs"; exit 2
  ;;
esac
