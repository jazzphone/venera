#!/bin/bash
# A macOS Tahoe VM on Proxmox VE, ready for Venera (Metal, OpenGL and hardware video on the host's GPU).
# Run as root on the Proxmox host, from the unpacked Venera-host-VERSION folder: it uses install-host.sh and the guest
# package (guest/Install Venera VERSION.pkg) beside it. It checks the host, asks its questions, shows the plan, and
# changes nothing until you say yes. MIT (vm/README.md), like the an earlier project script it grew from.
#
#   a new VM:      the host's packages (on each cluster node the VM may run on), OpenCore with SIP and AMFI already as
#                  Venera needs them, macOS Tahoe's recovery from Apple, the VM with Venus graphics and a sound device,
#                  and a "Venera" disk with the installer package. Then: install macOS, open Install Venera on that
#                  disk, restart, and run this again to Finish.
#   an existing VM: Finish (hardware video on every node, the installer disks out, a restart), Ready for Venera (an
#                  older macOS VM: the host's packages, the display, the args and the Venera disk), Upgrade Venera (this
#                  release's host half on every node, then its guest package installed in macOS with the choices it
#                  has, through the guest agent, and a restart), or its Mac identity.
#
# What each piece is for (each one a dead end without it):
#   the SMC key             - without it boot stops at "busy timeout ... AppleACPICPU" (WindowServer can't be decrypted)
#   VMHide + Lilu 1.7       - without it the Apple Account sign-in sees a VM and fails ("Verification failed")
#   -cpu host (+hypervisor) - hiding the hypervisor from the CPU stops the kernel; VMHide hides it from Apple's checks only
#   no TRIM on the disk     - Disk Utility's erase TRIMs the whole disk, which shared iSCSI storage clears 2 MB at a time
#   the guest agent         - clean shutdowns, and Finish reads Venera's status through it
#   virtio-gl + Venus       - the GPU the guest's Metal runs on (vga: virtio-gl, -global virtio-vga-gl.venus/blob/hostmem)
#   host-phys-bits-limit=40 - without it the firmware can put the GPU's memory window above 2^44, which macOS's kernel
#                             can't address: the driver finds no GPU memory
#   a USB sound device      - Safari won't start streaming video (YouTube) without an audio output; macOS has no driver
#                             for QEMU's HDA but drives USB audio itself
#   SIP 0x203, AMFI off     - set in OpenCore before macOS is installed, so Venera installs in one pass (otherwise its
#                             installer changes them first and finishes after a restart)
#   the video device last   - added at Finish: without VeneraVideo.kext, macOS hangs on it and finds no OpenCore disk
set -euo pipefail
ask() { local v; read -r -p "  $2${3:+ [$3]}: " v; printf -v "$1" '%s' "${v:-${3:-}}"; }
yes_no() { local v; read -r -p "  $1 [y/N]: " v; [[ $v =~ ^[Yy] ]]; }
no_yes() { local v; read -r -p "  $1 [Y/n]: " v; ! [[ $v =~ ^[Nn] ]]; }
die() { echo "STOP: $*"; exit 1; }
warn() { echo "  ! $*"; }
num() { [[ $1 =~ ^[0-9]+$ ]] || die "$2 is a number"; }
HERE=$(cd "$(dirname "$0")" && pwd)
GUID=7C436110-AB2A-4BBB-A880-FE41995C9F82   # Apple's NVRAM variables (boot-args, csr-active-config)

# ---- the host ------------------------------------------------------------------------------------------------------
VENUS_PKGS="mesa-vulkan-drivers virgl-server libgl1 libegl1"   # Vulkan, Venus's render server, QEMU's EGL display
TOOL_PKGS="unzip dmg2img genisoimage"

gpu_scan() {   # GPU_KIND intel|amd|nvidia|other|none (Intel first), GPU_NODE, GPU_DRV, GPU_NOTE; reads sysfs only
  local d v drv dev
  GPU_KIND=none GPU_NODE="" GPU_DRV="" GPU_NOTE=""
  for d in /sys/class/drm/renderD*; do
    [ -e "$d/device/vendor" ] || continue
    v=$(cat "$d/device/vendor"); drv=$(basename "$(readlink -f "$d/device/driver")")
    case $v in
      0x8086) GPU_KIND=intel GPU_NODE=/dev/dri/${d##*/} GPU_DRV=$drv; break ;;
      0x1002) [ "$GPU_KIND" = amd ] || { GPU_KIND=amd GPU_NODE=/dev/dri/${d##*/} GPU_DRV=$drv; } ;;
      0x10de) case $GPU_KIND in none | other) GPU_KIND=nvidia GPU_NODE=/dev/dri/${d##*/} GPU_DRV=$drv ;; esac ;;
      *) [ "$GPU_KIND" = none ] && GPU_KIND=other GPU_NODE=/dev/dri/${d##*/} GPU_DRV=$drv ;;
    esac
  done
  # an Intel GPU handed to a VM (vfio-pci) has no render node here
  if [ "$GPU_KIND" != intel ]; then
    for dev in /sys/bus/pci/devices/*; do
      [ "$(cat "$dev/vendor")" = 0x8086 ] && [[ $(cat "$dev/class") == 0x03* ]] || continue
      drv=""; [ -e "$dev/driver" ] && drv=$(basename "$(readlink -f "$dev/driver")")
      GPU_NOTE="the Intel GPU ${dev##*/} is bound to ${drv:-no driver}${drv:+ (passed through to a VM?)}, so the host can't use it"
    done
  fi
  [ "$GPU_KIND" = intel ] && [ "$GPU_NODE" != /dev/dri/renderD128 ] &&
    GPU_NOTE="the Intel GPU is $GPU_NODE, not renderD128: QEMU's display may pick another GPU"
  return 0
}
gpu_says() {   # what this GPU gives Venera
  case $1 in
    intel) echo "Intel ($2): Metal, OpenGL and hardware video (decoding and encoding)" ;;
    amd) echo "AMD ($2): Metal and OpenGL (hardware video needs an Intel GPU)" ;;
    nvidia) echo "NVIDIA ($2): untested with Venus" ;;
    other) echo "a GPU Venera hasn't been tried on ($2)" ;;
    none) echo "no GPU the host can render on" ;;
  esac
}
missing_pkgs() { local p; for p in "$@"; do dpkg-query -W -f '${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || printf '%s ' "$p"; done; }
host_prep() {   # $@ the packages: installs the missing ones, KVM's ignore_msrs on (now and after reboots)
  local miss
  miss=$(missing_pkgs "$@")
  if [ -n "$miss" ]; then
    echo "   apt-get install $miss"
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q $miss >/dev/null ||
      { apt-get update -q >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -q $miss >/dev/null; } || return 1
  fi
  echo 1 >/sys/module/kvm/parameters/ignore_msrs
  echo 0 >/sys/module/kvm/parameters/report_ignored_msrs 2>/dev/null || true
  [ -f /etc/modprobe.d/kvm-macos.conf ] || echo "options kvm ignore_msrs=1 report_ignored_msrs=0" >/etc/modprobe.d/kvm-macos.conf
}
host_versions() {   # dies when QEMU or virglrenderer are too old for Venus
  local q v
  q=$(dpkg-query -W -f '${Version}' pve-qemu-kvm 2>/dev/null || true)
  [ -n "$q" ] || die "no pve-qemu-kvm: this is for Proxmox VE"
  dpkg --compare-versions "$q" ge 9.2 || die "pve-qemu-kvm $q: Venus needs QEMU 9.2 or later (Proxmox VE 9)"
  v=$(dpkg-query -W -f '${Version}' libvirglrenderer1 2>/dev/null || true)
  [ -z "$v" ] || dpkg --compare-versions "$v" ge 1.0 || die "virglrenderer $v: Venus needs 1.0 or later (Proxmox VE 9)"
}

# the cluster's other nodes, and a way to run commands on them (the cluster's own SSH keys, host keys checked)
other_nodes() { local n; for n in /etc/pve/nodes/*; do n=${n##*/}; [ "$n" = "$(hostname)" ] || echo "$n"; done; }
node_ip() {   # a node's address, from corosync's node list
  awk -v n="$1" '/^[[:space:]]*node[[:space:]]*\{/ {nm = ""; ip = ""} $1 == "name:" {nm = $2} $1 == "ring0_addr:" {ip = $2}
    /^[[:space:]]*\}/ {if (nm == n && ip != "") {print ip; exit}}' "${COROSYNC:-/etc/pve/corosync.conf}"
}
on_node() {   # on_node NODE COMMAND: runs COMMAND (one string) as root on NODE
  local ip; ip=$(node_ip "$1"); [ -n "$ip" ] || { echo "no address for $1 in corosync.conf" >&2; return 1; }
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o HostKeyAlias="$1" -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="/etc/pve/nodes/$1/ssh_known_hosts /etc/pve/priv/known_hosts" "root@$ip" "$2"
}
storage_shared() {   # 0 when a storage is shared between the nodes (a VM on it can run on any of them)
  pvesh get "/storage/$1" --output-format json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if d.get("shared") or d.get("type") in ("nfs", "cifs", "rbd", "cephfs", "iscsi", "iscsidirect", "glusterfs", "zfs") else 1)'
}

# ---- Venera's parts, beside this script ----------------------------------------------------------------------------
VER=$(cat "$HERE/VERSION" 2>/dev/null || true)
HOSTKIT=""; [ -x "$HERE/install-host.sh" ] && [ -x "$HERE/bin/venera-videod" ] && HOSTKIT=$HERE
GPKG=""; for f in "$HERE"/guest/*.pkg "$HERE"/*.pkg; do [ -f "$f" ] && { GPKG=$f; break; }; done

venera_args() {   # the VM's args line with Venera's pieces added (each only once): $1 the line, $2 1 for the sound device
  local a=$1 g
  case " $a " in
    *host-phys-bits-limit=*) ;;
    *" -cpu host,"* | *" -cpu host ") a=$(sed -E 's/(^| )-cpu host(,| |$)/\1-cpu host,host-phys-bits-limit=40\2/' <<<"$a") ;;
    *) echo "  ! the VM's -cpu isn't 'host': add host-phys-bits-limit=40 to it by hand" >&2 ;;
  esac
  for g in venus=on blob=on hostmem=2G; do
    case " $a " in *" -global virtio-vga-gl.${g%%=*}="*) ;; *) a="$a -global virtio-vga-gl.$g" ;; esac
  done
  if [ "$2" = 1 ]; then case " $a " in *usb-audio*) ;; *) a="$a -audiodev spice,id=vsnd -device usb-audio,audiodev=vsnd" ;; esac; fi
  echo "${a# }"
}
venera_disk() {   # $1 the image to write: an ISO with the guest package and a note, which macOS mounts as "Venera"
  local d; d=$(mktemp -d)
  cp "$GPKG" "$d/$(basename "$GPKG")"
  cat >"$d/Read Me.txt" <<TXT
Venera ${VER:-} for this VM

1. Open "$(basename "$GPKG")" (Customize has the video, app and Safari WebGL choices).
2. Restart when it says so.
3. On the Proxmox host, run proxmox-macos-vm.sh again and choose Finish: it turns on hardware video, takes out the
   installer disks (this one too) and restarts the VM.

SIP and AMFI are already set in OpenCore as Venera needs them, so the package installs in one pass.
The install guide: https://github.com/jazzphone/venera/blob/main/docs/INSTALL.md
TXT
  genisoimage -quiet -V Venera -J -r -o "$1" "$d"; rm -rf "$d"
}

# ---- OpenCore ------------------------------------------------------------------------------------------------------
OC_URL=https://github.com/thenickdude/KVM-Opencore/releases/download/v21/OpenCore-v21.iso.gz
OC_SHA=a2b03ae2fb558e0bce99b57b5aff78e650501e39ecbeff0a8f69a8f25d64d76e   # the unpacked OpenCore-v21.iso
LILU_URL=https://github.com/acidanthera/Lilu/releases/download/1.7.2/Lilu-1.7.2-RELEASE.zip
LILU_SHA=53967d7dcfaab01023a33df2e969a89522f13d6654a6a56ac4711b62dabf3ab8
VMHIDE_URL=https://github.com/Carnations-Botanica/VMHide/releases/download/2.0.0/VMHide-2.0.0-RELEASE.zip
VMHIDE_SHA=31ffb861192eea52ad166fc0629b411ae48d8507c75935ab875bc61aebaa8dbb
MACREC_URL=https://raw.githubusercontent.com/acidanthera/OpenCorePkg/1.0.8/Utilities/macrecovery/macrecovery.py
MACREC_SHA=3023a9b4ca79a5255d93c00f25ab5df37e6f938b729b797d9ecea56184b17aff
TAHOE_BOARD=Mac-CFF7D910A743CAAF   # OpenCorePkg's macrecovery list: macOS 26 Tahoe, "-os latest"

oc_mount() {   # mounts the OpenCore image $OCIMG (a file or a VM disk) at $MNT
  [[ $OCIMG == /dev/* ]] && lvchange -ay "$OCIMG"   # shared LVM keeps a stopped VM's disks inactive
  LOOP=$(losetup -fP --show "$OCIMG"); MNT=$(mktemp -d); mount "${LOOP}p1" "$MNT"
}
oc_umount() { sync; umount "$MNT"; losetup -d "$LOOP"; rmdir "$MNT"; [[ $OCIMG == /dev/* ]] && lvchange -an "$OCIMG" || true; }

oc_config() {   # edits config.plist $1: settings from the environment (OC_RES, OC_CSR, OC_ARGS, MODEL/SERIAL/MLB/ROM)
  python3 - "$1" <<'PY'
import os, plistlib, sys, uuid
p = sys.argv[1]
with open(p, "rb") as f: c = plistlib.load(f)
e = os.environ.get
if e("OC_RES"):
    add = c["Kernel"]["Add"]
    if not any(k["BundlePath"] == "VMHide.kext" for k in add):
        i = [k["BundlePath"] for k in add].index("Lilu.kext")
        k = dict(add[i]); k.update({"BundlePath": "VMHide.kext", "ExecutablePath": "Contents/MacOS/VMHide", "PlistPath": "Contents/Info.plist",
                                    "Comment": "VMHide: hide the VM from Apple Account sign-in", "MinKernel": "", "MaxKernel": "", "Enabled": True})
        add.insert(i + 1, k)
    c["UEFI"]["Output"]["Resolution"] = e("OC_RES") + "@32"
    c["Misc"]["Boot"]["Timeout"] = 5
    print("   OpenCore: Lilu 1.7.2 + VMHide,", e("OC_RES") + ", boot menu 5 s")
nv = c["NVRAM"]
if e("OC_ARGS") is not None:
    nv["Add"].setdefault("7C436110-AB2A-4BBB-A880-FE41995C9F82", {})["boot-args"] = e("OC_ARGS")
    print("   boot-args:", e("OC_ARGS"))
if e("OC_CSR"):
    nv["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]["csr-active-config"] = bytes.fromhex(e("OC_CSR"))
    print("   SIP: csr-active-config 0x%X" % int.from_bytes(bytes.fromhex(e("OC_CSR")), "little"))
# OpenCore writes NVRAM > Add only over the variables NVRAM > Delete lists (or that don't exist yet)
dl = nv.setdefault("Delete", {}).setdefault("7C436110-AB2A-4BBB-A880-FE41995C9F82", [])
for k, v in (("boot-args", e("OC_ARGS")), ("csr-active-config", e("OC_CSR"))):
    if v and k not in dl: dl.append(k)
if e("MODEL") and not e("SERIAL"):   # the sample identity on a model macOS Tahoe installs on
    c["PlatformInfo"]["Generic"]["SystemProductName"] = e("MODEL")
    print("   model:", e("MODEL"), "(the sample serial: no iCloud)")
if e("SERIAL"):
    g = c["PlatformInfo"]["Generic"]
    g["SystemProductName"] = e("MODEL"); g["SystemSerialNumber"] = e("SERIAL"); g["MLB"] = e("MLB")
    g["ROM"] = bytes.fromhex(e("ROM").replace(":", "").replace("-", ""))
    g["SystemUUID"] = str(uuid.uuid4()).upper()
    c["PlatformInfo"]["Automatic"] = True; c["PlatformInfo"]["UpdateSMBIOSMode"] = "Create"
    print("   identity:", g["SystemProductName"], g["SystemSerialNumber"][:4] + "...", "ROM", g["ROM"].hex(":"))
with open(p, "wb") as f: plistlib.dump(c, f)
PY
}

prepare_opencore() {   # on the new OpenCore image $OCIMG: Lilu 1.7.2 + VMHide, the screen size, SIP/AMFI, the identity
  local w; w=$(mktemp -d)
  curl -fsL "$LILU_URL" -o "$w/lilu.zip"; curl -fsL "$VMHIDE_URL" -o "$w/vmhide.zip"
  echo "$LILU_SHA  $w/lilu.zip" | sha256sum -c --quiet || die "Lilu download doesn't match its checksum"
  echo "$VMHIDE_SHA  $w/vmhide.zip" | sha256sum -c --quiet || die "VMHide download doesn't match its checksum"
  unzip -q "$w/lilu.zip" -d "$w/lilu"; unzip -q "$w/vmhide.zip" -d "$w/vmhide"
  oc_mount
  rm -rf "$MNT/EFI/OC/Kexts/Lilu.kext"
  cp -R "$(find "$w/lilu" -maxdepth 2 -name Lilu.kext | head -1)" "$(find "$w/vmhide" -maxdepth 2 -name VMHide.kext | head -1)" "$MNT/EFI/OC/Kexts/"
  OC_RES=$RES OC_ARGS=$BOOTARGS OC_CSR=$CSR MODEL=$MODEL SERIAL=$SERIAL MLB=$MLB ROM=$ROM oc_config "$MNT/EFI/OC/config.plist"
  oc_umount; rm -rf "$w"
}

apply_identity() {   # an existing VM's OpenCore disk: the Mac identity only
  oc_mount
  MODEL=$MODEL SERIAL=$SERIAL MLB=$MLB ROM=$ROM oc_config "$MNT/EFI/OC/config.plist"
  oc_umount
}

# ---- an existing VM ------------------------------------------------------------------------------------------------
guest() {   # guest COMMAND: runs a shell command in macOS through the guest agent, prints its output
  qm guest exec "$VMID" --timeout 60 -- /bin/sh -c "$1" 2>/dev/null |
    python3 -c 'import json, sys; d = json.load(sys.stdin); print(d.get("out-data", ""), end="")' 2>/dev/null || true
}
drop_disk() {   # takes the disk in slot $1 out of the VM and deletes its volume (the VM stopped)
  local vol u
  vol=$(qm config "$VMID" | sed -n "s/^$1: \([^,]*\).*/\1/p"); [ -n "$vol" ] || return 0
  qm set "$VMID" --delete "$1" >/dev/null
  u=$(qm config "$VMID" | awk -v v="$vol" -F': ' '$1 ~ /^unused/ && $2 == v {print $1}')
  [ -z "$u" ] || qm disk unlink "$VMID" --idlist "$u" --force 1 >/dev/null
  echo "   $1 ($vol) taken out and deleted"
}
disk_of() { qm config "$VMID" | sed -n "s/^$1: \([^,]*\).*/\1/p"; }   # the volume in slot $1
vm_other_nodes() {   # the other nodes the VM may run on: none when its disk is on this node's own storage
  local st; st=$(disk_of virtio0); st=${st%%:*}
  if [ -n "$st" ] && ! storage_shared "$st"; then
    [ -z "$(other_nodes)" ] || echo "  ($st is this node's own: VM $VMID stays here, the other nodes aren't set up)" >&2
    return 0
  fi
  other_nodes
}
backup_conf() { mkdir -p /root/macos-vm-backup; cp "/etc/pve/qemu-server/$VMID.conf" "/root/macos-vm-backup/$VMID.conf.$(date +%Y%m%d-%H%M%S)"; }
stop_vm() {   # shuts the VM down (from macOS, as the Apple menu does) and waits; HA's VMs through HA
  qm status "$VMID" | grep -q stopped && return 0
  echo "== shutting VM $VMID down"
  qm shutdown "$VMID" --timeout 300 >/dev/null 2>&1 || true
  local i; for i in $(seq 1 120); do qm status "$VMID" 2>/dev/null | grep -q stopped && return 0; sleep 5; done
  die "VM $VMID didn't shut down in 10 minutes: shut it down from macOS, then run this again"
}
attach_venera_disk() {   # a Venera disk in ide1 (made from the guest package), unless one is there
  [ -n "$GPKG" ] || return 0
  if [ -n "$(disk_of ide1)" ]; then echo "   ide1 is in use: no Venera disk (copy the package in yourself)"; return 0; fi
  local img; img=$(mktemp --suffix=.iso); venera_disk "$img"
  qm disk import "$VMID" "$img" "$STORAGE" --format raw >/dev/null; rm -f "$img"
  local u; u=$(qm config "$VMID" | sed -n 's/^\(unused[0-9]*\): .*/\1/p' | tail -1)
  qm set "$VMID" --ide1 "$(qm config "$VMID" | sed -n "s/^$u: //p"),cache=unsafe" >/dev/null
  echo "   ide1: the Venera disk ($(basename "$GPKG"))"
}

finish_vm() {   # macOS and Venera installed: hardware video, the installer disks out, a restart; the old clean-ups
  local st="" up=0 nodes=() n
  echo; echo "== Finish VM $VMID"
  qm agent "$VMID" ping >/dev/null 2>&1 && up=1
  if [ $up = 1 ]; then
    st=$(guest 'V="/Library/Application Support/Venera"; [ -e "$V/VERSION" ] && echo "Venera $(cat "$V/VERSION") in macOS"; [ -e "$V/VIDEO" ] && echo "with its video choice"; kextstat 2>/dev/null | grep -q VeneraVideo && echo "VeneraVideo.kext loaded"')
    if [ -n "$st" ]; then echo "$st" | sed 's/^/  /'
    else warn "Venera isn't installed in macOS yet: open Install Venera on the Venera disk first (or go on without it)"; fi
  else
    echo "  (no guest agent in macOS: can't read Venera's status; mac-guest-agent gives it one)"
  fi
  local VIDEO=0 drops=() HASDEV=0 RESTART=0
  case " $(qm config "$VMID" | sed -n 's/^args: //p') " in *"/run/venera-video-$VMID.sock"*) HASDEV=1 ;; esac
  gpu_scan
  if [ "$GPU_KIND" = intel ] && [ -n "$HOSTKIT" ]; then
    if [ -z "$st" ] || [[ $st == *"video choice"* ]]; then
      no_yes "Hardware video (the host's Intel GPU decodes and encodes for the VM)?" && VIDEO=1
    else   # without VeneraVideo.kext the device hangs macOS's boot
      warn "Venera in macOS was installed without its video choice: install it again with it before turning this on"
      yes_no "Hardware video anyway?" && VIDEO=1
    fi
  elif [ "$GPU_KIND" = intel ]; then
    echo "  (hardware video: run this from the unpacked Venera-host folder; it carries the host's half)"
  fi
  if [ $VIDEO = 1 ]; then for n in $(vm_other_nodes); do no_yes "Hardware video on $n too (HA may start the VM there)?" && nodes+=("$n"); done; fi
  for s in ide0 ide1; do
    [ -n "$(disk_of $s)" ] && yes_no "Take out and delete $s ($(disk_of $s): the macOS recovery or the Venera disk)?" && drops+=("$s")
  done
  { [ $VIDEO = 1 ] && [ $HASDEV = 0 ]; } || [ ${#drops[@]} -gt 0 ] && RESTART=1
  echo; echo "== The plan"
  [ $VIDEO = 1 ] && echo "  - hardware video: install-host.sh --vm $VMID here${nodes[*]:+ and on ${nodes[*]}}$([ $HASDEV = 1 ] && echo " (the VM has its device: this updates the service)")"
  [ ${#drops[@]} -gt 0 ] && echo "  - take out and delete ${drops[*]}"
  [ $up = 1 ] && echo "  - in macOS: set the clock once, Apple's power logging (PerfPowerServices) off (it held a core at ~90%)"
  [ $RESTART = 1 ] && echo "  - shut VM $VMID down and start it again (QEMU picks up the device and disk changes when it starts)"
  yes_no "Go ahead?" || die "nothing changed"
  if [ $up = 1 ]; then
    qm guest exec "$VMID" --timeout 20 -- /usr/bin/sntp -sS time.apple.com >/dev/null 2>&1 || true
    qm guest exec "$VMID" --timeout 20 -- /bin/launchctl disable system/com.apple.PerfPowerServices >/dev/null 2>&1 || true
    qm guest exec "$VMID" --timeout 20 -- /bin/launchctl bootout system/com.apple.PerfPowerServices >/dev/null 2>&1 || true
  fi
  [ $VIDEO = 1 ] || [ $RESTART = 1 ] || { echo "== Done."; exit 0; }
  [ $RESTART = 0 ] || stop_vm
  backup_conf
  for n in "${nodes[@]}"; do   # the other nodes first: the VM needs its socket wherever it starts
    echo "== hardware video on $n"
    tar -C "$(dirname "$HOSTKIT")" -cz "$(basename "$HOSTKIT")" | on_node "$n" "mkdir -p /root/venera && tar -C /root/venera -xz"
    on_node "$n" "/root/venera/$(basename "$HOSTKIT")/install-host.sh --vm $VMID" | sed 's/^/   /'
  done
  if [ $VIDEO = 1 ]; then echo "== hardware video here"; "$HOSTKIT/install-host.sh" --vm "$VMID" | sed 's/^/   /'; fi
  for s in "${drops[@]}"; do drop_disk "$s"; done
  [ $RESTART = 0 ] || { echo "== starting VM $VMID"; qm start "$VMID"; }
  echo "== Done. In macOS, the Venera app (Applications) shows what runs. The config before: /root/macos-vm-backup/."
}

ready_vm() {   # an existing macOS VM (stopped): the host's packages, the display, the args, the Venera disk
  local cur new AUDIO=1 nodes=() n
  qm status "$VMID" | grep -q stopped || die "shut VM $VMID down first, then run this again"
  STORAGE=$(qm config "$VMID" | sed -n 's/^virtio0: \([^:]*\):.*/\1/p'); [ -n "$STORAGE" ] || STORAGE=local-lvm
  cur=$(qm config "$VMID" | sed -n 's/^args: //p')
  case " $cur " in *usb-audio*) ;; *) no_yes "A sound device (USB audio; YouTube needs one)?" || AUDIO=0 ;; esac
  new=$(venera_args "$cur" $AUDIO)
  for n in $(vm_other_nodes); do no_yes "Set up $n too (HA may start the VM there)?" && nodes+=("$n"); done
  echo; echo "== The plan"
  echo "  - here${nodes[*]:+ and on ${nodes[*]}}: install $(missing_pkgs $VENUS_PKGS genisoimage)(those missing), KVM ignore_msrs on"
  echo "  - VM $VMID: display virtio-gl (was $(qm config "$VMID" | sed -n 's/^vga: //p'))"
  [ "$new" = "$cur" ] || echo "  - its args gain: $(comm -13 <(tr ' ' '\n' <<<"$cur" | sort -u) <(tr ' ' '\n' <<<"$new" | sort -u) | tr '\n' ' ')"
  [ -n "$GPKG" ] && echo "  - a Venera disk in ide1 with $(basename "$GPKG")"
  echo "  (the config is backed up to /root/macos-vm-backup first)"
  yes_no "Go ahead?" || die "nothing changed"
  echo "== the host"; host_prep $VENUS_PKGS genisoimage || die "the packages didn't install (apt)"
  for n in "${nodes[@]}"; do echo "== $n"; on_node "$n" "$(declare -f missing_pkgs host_prep); host_prep $VENUS_PKGS" || die "$n's packages didn't install (apt on $n)"; done
  backup_conf
  qm set "$VMID" --vga virtio-gl --args "$new" >/dev/null; echo "   display virtio-gl, args updated"
  attach_venera_disk
  echo "== Done. Start VM $VMID, open Install Venera on the Venera disk (Finder's sidebar, Locations) and restart when"
  echo "   it says so (when SIP has to change it finishes after one more restart). Then run this again and choose Finish."
}

choices_xml() {   # Installer's choice changes for the guest package: $1 video, $2 app, $3 webgl (each 0 or 1)
  local c
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><array>'
  for c in "video $1" "app $2" "webgl $3"; do
    printf '<dict><key>attributeSetting</key><integer>%s</integer><key>choiceAttribute</key><string>selected</string><key>choiceIdentifier</key><string>%s</string></dict>' "${c#* }" "${c% *}"
  done
  printf '</array></plist>\n'
}
guest_rc() {   # guest_rc TIMEOUT COMMAND: like guest, with stderr, then "rc=N" (the command's exit code)
  qm guest exec "$VMID" --timeout "$1" -- /bin/sh -c "$2" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("out-data", "") + d.get("err-data", ""), end="")
print("rc=%s" % d.get("exitcode", "?"))' 2>/dev/null || echo "rc=?"
}
usb_disk() {   # usb_disk add IMAGE | del: the image as a USB drive in the running VM, on the EHCI bus (macOS ignores
  # a drive on the XHCI's hub); QEMU drops the drive with the device, and both are gone at the VM's next start
  if [ "$1" = add ]; then
    local o
    o=$(qm monitor "$VMID" <<<"drive_add 0 if=none,id=venera-upg,file=$2,format=raw,readonly=on" 2>&1
      qm monitor "$VMID" <<<"device_add usb-storage,drive=venera-upg,id=venera-upgdev,bus=ehci.0,removable=on" 2>&1)
    if grep -q -i -E 'error|could not|not found|duplicate' <<<"$o"; then echo "$o" | grep -v '^qm>' >&2; return 1; fi
    return 0
  fi
  qm monitor "$VMID" <<<"device_del venera-upgdev" >/dev/null 2>&1 || true
}

screen_state() {   # open, locked or nobody: macOS mounts a new USB disk only while someone is logged in, unlocked
  guest 'ioreg -n Root -d1 -a | plutil -extract IOConsoleUsers json -o - - 2>/dev/null' | screen_says
}
screen_says() {   # IOConsoleUsers (JSON) -> open, locked or nobody; open when it can't tell (the mount's wait says)
  python3 -c '
import json, sys
try:
    us = json.load(sys.stdin)
except Exception:
    print("open"); sys.exit()
on = [u for u in us if u.get("kCGSSessionOnConsoleKey")]
print("nobody" if not on else "locked" if on[0].get("CGSSessionScreenIsLocked") else "open")'
}

upgrade_vm() {   # a VM with Venera: this release's host half on every node, then its guest package in macOS, a restart
  local st cur="" video=0 app=0 webgl=0 user="" HASDEV=0 nodes=() n img mnt out k
  [ -n "$GPKG" ] || die "no guest package beside this script: run it from the unpacked Venera-host folder"
  echo; echo "== Upgrade VM $VMID to Venera ${VER:-?}"
  qm status "$VMID" | grep -q running || die "VM $VMID isn't running: start it (the upgrade goes in through the guest agent), then run this again"
  qm agent "$VMID" ping >/dev/null 2>&1 || die "VM $VMID's guest agent doesn't answer: copy $(basename "$GPKG") into macOS and open it instead"
  st=$(guest 'V="/Library/Application Support/Venera"; [ -e "$V/VERSION" ] && echo "version $(cat "$V/VERSION")"; [ -e "$V/VIDEO" ] && echo video; [ -d /Applications/Venera.app ] && echo app; [ -e "$V/NO_SYSVOL" ] && echo nosysvol; csrutil authenticated-root status 2>/dev/null | grep -qi disabled && echo authroot-off; stat -f %Su /dev/console')
  cur=$(sed -n 's/^version //p' <<<"$st")
  [ -n "$cur" ] || die "Venera isn't installed in VM $VMID's macOS: open Install Venera there (Ready for Venera makes the disk)"
  grep -qx video <<<"$st" && video=1
  grep -qx app <<<"$st" && app=1
  grep -qx authroot-off <<<"$st" && ! grep -qx nosysvol <<<"$st" && webgl=1
  user=$(tail -1 <<<"$st"); [ "$user" = root ] && user=""
  case " $(qm config "$VMID" | sed -n 's/^args: //p') " in *"/run/venera-video-$VMID.sock"*) HASDEV=1 ;; esac
  echo "  macOS has Venera $cur: hardware video $([ $video = 1 ] && echo on || echo off), the Venera app $([ $app = 1 ] && echo on || echo off), Safari WebGL (the system-volume copy) $([ $webgl = 1 ] && echo on || echo off)"
  if [ $HASDEV = 1 ]; then
    [ -n "$HOSTKIT" ] || die "VM $VMID has hardware video but Venera's host half isn't beside this script"
    for n in $(vm_other_nodes); do no_yes "The host half on $n too (HA may start the VM there)?" && nodes+=("$n"); done
  fi
  echo; echo "== The plan"
  [ $HASDEV = 1 ] && echo "  - the host half: install-host.sh --vm $VMID here${nodes[*]:+ and on ${nodes[*]}} (running VMs keep their video connections)"
  echo "  - in macOS: $(basename "$GPKG") from a USB disk, with the same choices, then a restart"
  [ -z "$user" ] || echo "    ($user is logged in: the restart closes their apps, and anything unsaved is lost)"
  echo "    (macOS takes the disk only while someone is logged in with the screen unlocked: this waits for that)"
  yes_no "Go ahead?" || die "nothing changed"
  for n in "${nodes[@]}"; do   # the other nodes first: the VM needs its socket wherever it starts
    echo "== the host half on $n"
    tar -C "$(dirname "$HOSTKIT")" -cz "$(basename "$HOSTKIT")" | on_node "$n" "mkdir -p /root/venera && tar -C /root/venera -xz"
    on_node "$n" "/root/venera/$(basename "$HOSTKIT")/install-host.sh --vm $VMID" | sed 's/^/   /'
  done
  if [ $HASDEV = 1 ]; then echo "== the host half here"; "$HOSTKIT/install-host.sh" --vm "$VMID" | sed 's/^/   /'; fi
  echo "== the guest package"
  mkdir -p /root/venera; img=/root/venera/venera-upgrade-$VMID.iso
  venera_disk "$img"
  while :; do   # loginwindow turns the disk away (and ejects it) while the screen is locked or nobody is logged in
    case $(screen_state) in
      locked) ask k "macOS's screen is locked, and it won't take a USB disk then: unlock it (the VM's console or Screen Sharing), then press Enter" ;;
      nobody) ask k "nobody is logged in to macOS, and it won't take a USB disk then: log in (the VM's console or Screen Sharing), then press Enter" ;;
      *) break ;;
    esac
  done
  usb_disk add "$img" || { rm -f "$img"; die "the USB disk didn't attach (qm monitor $VMID)"; }
  mnt=""; for n in $(seq 1 24); do
    mnt=$(guest "ls -d /Volumes/*/'$(basename "$GPKG")' 2>/dev/null | head -1"); [ -n "$mnt" ] && break; sleep 5
  done
  if [ -z "$mnt" ]; then usb_disk del; rm -f "$img"; die "macOS didn't mount the USB disk in 2 minutes (did its screen lock?): nothing installed"; fi
  guest "printf '%s' '$(choices_xml $video $app $webgl)' > /private/var/tmp/venera-choices.xml" >/dev/null
  out=$(guest_rc 900 "/usr/sbin/installer -pkg '$mnt' -target / -applyChoiceChangesXML /private/var/tmp/venera-choices.xml 2>&1; rm -f /private/var/tmp/venera-choices.xml")
  sed 's/^/   /' <<<"$out" | grep -v '^   rc='
  guest "diskutil eject '$(dirname "$mnt")' >/dev/null 2>&1" >/dev/null; sleep 2; usb_disk del; rm -f "$img"
  grep -qx 'rc=0' <<<"$out" || die "the install failed: its log is /Library/Application Support/Venera/install.log in macOS; nothing restarted"
  echo "== restarting macOS"
  qm guest exec "$VMID" --timeout 10 -- /sbin/shutdown -r now >/dev/null 2>&1 || true
  sleep 30
  for n in $(seq 1 60); do qm agent "$VMID" ping >/dev/null 2>&1 && break; sleep 5; done
  sleep 20
  st=$(guest 'V="/Library/Application Support/Venera"; echo "Venera $(cat "$V/VERSION")"; kextstat 2>/dev/null | grep -o "VeneraVideo ([0-9.]*)"; ioreg -rc VirtioGPUAccel -d1 2>/dev/null | sed -n "s/.*\"VirtioGPUArmState\" = \"\(.*\)\"/desktop: \1/p"')
  if [ -n "$st" ]; then sed 's/^/   /' <<<"$st"; else warn "macOS's guest agent hasn't answered since the restart: check the VM's console"; fi
  echo "== Done. In macOS, the Venera app (Applications) shows what runs."
}

# ---- the questions -------------------------------------------------------------------------------------------------
[ -z "${MACOS_VM_TEST:-}" ] || return 0   # vm/test.sh sources the functions above
[ "$(id -u)" = 0 ] || die "run as root on the Proxmox host"
command -v qm >/dev/null && command -v pvesm >/dev/null || die "this is for a Proxmox VE host (no qm / pvesm)"
grep -q -m1 GenuineIntel /proc/cpuinfo || die "this makes macOS VMs for Intel CPUs (-cpu host as an Intel Mac); this host's CPU isn't Intel"
[ -e /dev/kvm ] || die "no /dev/kvm: turn on VT-x in the host's firmware"

echo; echo "== A macOS Tahoe VM on Proxmox, ready for Venera${VER:+ $VER}"
gpu_scan
echo "  GPU: $(gpu_says "$GPU_KIND" "${GPU_DRV:-}${GPU_NODE:+ $GPU_NODE}")"
[ -z "$GPU_NOTE" ] || warn "$GPU_NOTE"
if [ -n "$HOSTKIT" ]; then echo "  Venera's host half: $HOSTKIT"; else echo "  Venera's host half: not beside this script (hardware video waits for it)"; fi
if [ -n "$GPKG" ]; then echo "  the guest package: $GPKG"; else echo "  the guest package: not beside this script (copy it into macOS yourself)"; fi
echo "  VMs now:"; qm list | sed 's/^/    /'
ask NAME "VM name" "macos"
EXIST=$(qm list | awk -v n="$NAME" '$2 == n {print $1}' | head -1)
ELSEWHERE=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if r.get("name") == sys.argv[1]: print(r.get("vmid"), r.get("node")); break' "$NAME" || true)
[ -n "$EXIST" ] || [ -z "$ELSEWHERE" ] || die "$NAME is VM ${ELSEWHERE% *} on node ${ELSEWHERE#* }: run this there"
if [ -n "$EXIST" ]; then
  VMID=$EXIST; echo "  $NAME is VM $VMID already ($(qm status "$VMID" | cut -d' ' -f2))."
  echo "    1  Finish: macOS and Venera are installed (hardware video, the installer disks out, a restart)"
  echo "    2  Ready for Venera: an older macOS VM gets Venus graphics, a sound device and the Venera disk"
  echo "    3  Its Mac identity (for iCloud)"
  echo "    4  Upgrade Venera${VER:+ to $VER}: the host half on every node, then the guest package in macOS, and a restart"
  ask WHAT "Which" "1"
  case $WHAT in
    1) finish_vm; exit 0 ;;
    2) host_versions; [ "$GPU_KIND" != none ] || die "no GPU the host can render on: Venera needs one"; ready_vm; exit 0 ;;
    3) ;;
    4) upgrade_vm; exit 0 ;;
    *) die "nothing changed" ;;
  esac
  qm status "$VMID" | grep -q stopped || die "shut VM $VMID down first (Proxmox's Shutdown, or Apple menu > Shut Down), then run this again"
  OCVOL=$(disk_of ide2); [ -n "$OCVOL" ] || die "VM $VMID has no OpenCore disk on ide2"
  OCIMG=$(pvesm path "$OCVOL"); MODE=identity
else
  MODE=create
  host_versions
  VENERA=0 VIDEO=0 WEBGL=0 AUDIO=1 NODES=()
  if [ "$GPU_KIND" != none ]; then no_yes "Set it up for Venera (Metal and OpenGL on the host's GPU)?" && VENERA=1; fi
  if [ $VENERA = 1 ]; then
    [ "$GPU_KIND" = intel ] && no_yes "Hardware video (the host's Intel GPU decodes H.264, HEVC and VP9 and encodes H.264 and HEVC)?" && VIDEO=1
    yes_no "Safari WebGL (SIP's authenticated root off too, so the driver can go on the system volume)?" && WEBGL=1
  fi
  no_yes "A sound device (USB audio over SPICE; YouTube needs one)?" || AUDIO=0
  echo; echo "  VM storage (its disks):"; pvesm status --content images | sed 's/^/    /'
  ask STORAGE "Storage for the VM's disks" "local-lvm"
  pvesm status --content images | awk 'NR>1{print $1}' | grep -qx "$STORAGE" || die "$STORAGE can't hold VM disks"
  if [ -n "$(other_nodes)" ]; then
    if storage_shared "$STORAGE"; then
      for n in $(other_nodes); do no_yes "Set up node $n too (HA may start the VM there)?" && NODES+=("$n"); done
    else echo "  ($STORAGE is this node's own: the VM stays here, the other nodes aren't set up)"; fi
  fi
  echo; echo "  ISO storage (where the OpenCore and macOS recovery images are downloaded, ~1.5 GB):"; pvesm status --content iso | sed 's/^/    /'
  ask ISOSTORE "Storage for the downloads" "local"
  pvesm status --content iso | awk 'NR>1{print $1}' | grep -qx "$ISOSTORE" || die "$ISOSTORE can't hold ISO images"
  ISO=$(dirname "$(pvesm path "$ISOSTORE:iso/probe.iso")")
  echo; echo "  Network bridges:"; ip -br link show type bridge | awk '$1 ~ /^vmbr/ {print "    " $1}'
  ask BRIDGE "Bridge" "vmbr0"
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "no bridge $BRIDGE"
  ask VLAN "VLAN tag (empty for none)" ""
  [ -z "$VLAN" ] || num "$VLAN" "the VLAN tag"
  ask VMID "VM number" "$(pvesh get /cluster/nextid)"; num "$VMID" "the VM number"
  qm status "$VMID" >/dev/null 2>&1 && die "VM $VMID already exists"
  compgen -G "/etc/pve/nodes/*/qemu-server/$VMID.conf" >/dev/null && die "VM $VMID already exists on another node"
  ask CORES "Cores" "4"; num "$CORES" "cores"
  ask MEM "Memory in MB" "8192"; num "$MEM" "memory"
  [ $VENERA = 0 ] || [ "$MEM" -ge 8192 ] || die "Venera needs 8192 MB or more"
  ask DISK "Disk in GB" "64"; num "$DISK" "the disk size"
  ask RES "Screen size at boot" "1280x800"
  [[ $RES =~ ^[0-9]{3,4}x[0-9]{3,4}$ ]] || die "a screen size is like 1280x800"
  # Apple's SMC key, the same for every Mac (published by the open-source macOS VM projects). The OpenCore image has no
  # VirtualSMC, so without it macOS can't decrypt WindowServer and boot stalls at "busy timeout ... AppleACPICPU".
  OSK="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
  BASE=$ISO/OpenCore-v21.iso OCIMG=$ISO/OpenCore-$NAME.iso REC=$ISO/Tahoe-recovery.img
  [ ! -f "$OCIMG" ] || die "$OCIMG is there already (another VM's?): pick another name, or remove it"
  BOOTARGS="keepsyms=1" CSR=""
  if [ $VENERA = 1 ]; then
    BOOTARGS="keepsyms=1 amfi_get_out_of_my_way=1"
    if [ $WEBGL = 1 ]; then CSR=030A0000; else CSR=03020000; fi   # 0xA03 / 0x203, little-endian
  fi
fi

echo; echo "  Your MacBook's identity, used to sign into iCloud. Press Enter at the serial to skip it for now:"
echo "  the VM then keeps the shared sample identity from OpenCore and must NOT be signed into iCloud until you run this again."
SERIAL="" MLB="" ROM=""
ask MODEL "Model identifier (one macOS Tahoe supports)" "iMac20,1"
ask SERIAL "Serial number"
if [ -n "$SERIAL" ]; then
  SERIAL=${SERIAL^^}; [[ $SERIAL =~ ^[A-Z0-9]{10,12}$ ]] || die "that serial doesn't look like a Mac serial"
  ask MLB "Board serial (MLB)"; MLB=${MLB^^}; [[ $MLB =~ ^[A-Z0-9]{13,17}$ ]] || die "that MLB doesn't look right (13-17 letters and digits)"
  ask ROM "Wi-Fi MAC address (aa:bb:cc:dd:ee:ff)"; ROM=${ROM,,}
  [[ $ROM =~ ^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$ ]] || die "that MAC address doesn't look right"
elif [ $MODE = identity ]; then die "no identity given: nothing changed"
fi

# ---- the plan ------------------------------------------------------------------------------------------------------
echo; echo "== The plan"
if [ $MODE = create ]; then
  PCORES=$(cat /sys/devices/cpu_core/cpus 2>/dev/null || true)   # a hybrid CPU's performance cores
  NEED="$TOOL_PKGS"; [ $VENERA = 0 ] || NEED="$VENUS_PKGS $TOOL_PKGS"
  MISS=$(missing_pkgs $NEED)
  echo "  - this host: KVM ignore_msrs on (now and after reboots)${MISS:+; install $MISS}"
  for n in "${NODES[@]}"; do
    r=$(on_node "$n" "$(declare -f missing_pkgs gpu_scan); gpu_scan; echo \"\$GPU_KIND\"; missing_pkgs $VENUS_PKGS" 2>&1) ||
      die "can't reach $n over the cluster's SSH ($r)"
    echo "  - node $n: KVM ignore_msrs on$(sed -n 2p <<<"$r" | sed 's/^\(..*\)/; install \1/')"
    [ "$(head -1 <<<"$r")" != none ] || warn "$n has no GPU the host can render on: the VM won't start there"
  done
  echo "  - download into $ISO: the OpenCore image (thenickdude/KVM-Opencore v21) and macOS Tahoe's recovery from Apple"
  echo "  - VM $VMID '$NAME': $CORES cores${PCORES:+ on the performance cores ($PCORES)}, $MEM MB, $DISK GB on $STORAGE"
  echo "    (the OpenCore and recovery images are imported as two small disks there too)"
  echo "  - network: $BRIDGE${VLAN:+, VLAN $VLAN}; starts with the host"
  echo "  - SMC: QEMU applesmc with Apple's SMC key; CPU: the host's own; OpenCore with Lilu 1.7.2 + VMHide, $RES"
  if [ $VENERA = 1 ]; then
    echo "  - Venera: display virtio-gl with Venus, host-phys-bits-limit=40; in OpenCore SIP 0x$([ $WEBGL = 1 ] && echo A03 || echo 203)"
    echo "    and amfi_get_out_of_my_way=1$([ $WEBGL = 1 ] && echo " (authenticated root off, for Safari WebGL)")"
    if [ -n "$GPKG" ]; then echo "  - a Venera disk with $(basename "$GPKG"), to open once macOS is installed"; fi
    [ $VIDEO = 1 ] && echo "  - hardware video: set up at Finish (the device waits for VeneraVideo.kext in macOS)"
  else
    echo "  - display: VMware SVGA (no Venera)"
  fi
  [ $AUDIO = 1 ] && echo "  - a USB sound device (plays in Proxmox's SPICE console)"
  echo "  - a guest agent port (ISA serial) for mac-guest-agent"
fi
if [ -n "$SERIAL" ]; then echo "  - Mac identity: $MODEL, serial ${SERIAL:0:4}..., MAC $ROM"
else echo "  - Mac identity: the sample one from OpenCore$([ $MODE = create ] && echo ", model $MODEL") (no iCloud until you add yours)"; fi
yes_no "Go ahead?" || die "nothing changed"

if [ $MODE = identity ]; then
  [[ $OCIMG == /dev/* ]] && lvchange -ay "$OCIMG"
  BK=/root/opencore-$NAME-$(date +%Y%m%d-%H%M%S).img; dd if="$OCIMG" of="$BK" bs=1M status=none
  apply_identity
  echo "== Done (the previous OpenCore disk is saved as $BK). Start VM $VMID, then sign into your Apple Account inside it."; exit 0
fi

# ---- a new VM ------------------------------------------------------------------------------------------------------
echo "== this host"
host_prep $NEED || die "the packages didn't install (apt-get install $(missing_pkgs $NEED))"
for n in "${NODES[@]}"; do echo "== node $n"; on_node "$n" "$(declare -f missing_pkgs host_prep); host_prep $VENUS_PKGS" || die "$n's packages didn't install (apt on $n)"; done

echo "== OpenCore image"
mkdir -p "$ISO"
if [ ! -f "$BASE" ]; then
  curl -fL "$OC_URL" -o /tmp/OpenCore-v21.iso.gz
  gunzip -c /tmp/OpenCore-v21.iso.gz >"$BASE.part" && rm /tmp/OpenCore-v21.iso.gz
  echo "$OC_SHA  $BASE.part" | sha256sum -c --quiet || { rm -f "$BASE.part"; die "the OpenCore image doesn't match its checksum"; }
  mv "$BASE.part" "$BASE"
fi
cp "$BASE" "$OCIMG"; prepare_opencore

echo "== macOS Tahoe recovery, from Apple"
if [ ! -f "$REC" ]; then
  W=$(mktemp -d); cd "$W"
  curl -fsL "$MACREC_URL" -o macrecovery.py
  echo "$MACREC_SHA  macrecovery.py" | sha256sum -c --quiet || die "macrecovery.py doesn't match its checksum"
  python3 macrecovery.py -b $TAHOE_BOARD -m 00000000000000000 -os latest download   # checks Apple's chunklist
  DMG=""   # Apple sends one of the two (not ls: with pipefail, the one that's missing stopped the script)
  for d in com.apple.recovery.boot/BaseSystem.dmg com.apple.recovery.boot/RecoveryImage.dmg; do
    [ -n "$DMG" ] || [ ! -f "$d" ] || DMG=$d
  done
  [ -n "$DMG" ] || die "Apple's recovery download has no BaseSystem.dmg"
  dmg2img "$DMG" "$REC.part" >/dev/null && mv "$REC.part" "$REC"
  cd /; rm -rf "$W"
fi

echo "== VM $VMID"
# One tablet: the args' own on the XHCI. Proxmox's (--tablet 1, on the EHCI) beside it made two, and QEMU sends the
# console's mouse to one of them; on VM 107 it went to Proxmox's, which macOS had stopped reading, and the mouse died.
ARGS="-smbios type=2 -device qemu-xhci -device usb-kbd -device usb-tablet -global nec-usb-xhci.msi=off -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off -cpu host,vendor=GenuineIntel,+invtsc,+hypervisor,kvm=on,vmware-cpuid-freq=on -device isa-applesmc,osk=\"$OSK\""
VGA=vmware
if [ $VENERA = 1 ]; then VGA=virtio-gl; ARGS=$(venera_args "$ARGS" $AUDIO)
elif [ $AUDIO = 1 ]; then ARGS="$ARGS -audiodev spice,id=vsnd -device usb-audio,audiodev=vsnd"; fi
qm create "$VMID" --name "$NAME" --ostype other --machine q35 --bios ovmf \
  --cores "$CORES" --sockets 1 ${PCORES:+--affinity "$PCORES"} --memory "$MEM" --balloon 0 \
  --vga $VGA --tablet 0 --agent enabled=1,type=isa \
  --net0 "vmxnet3,bridge=$BRIDGE${VLAN:+,tag=$VLAN},firewall=0" \
  --efidisk0 "$STORAGE:1,efitype=4m,pre-enrolled-keys=0" \
  --virtio0 "$STORAGE:$DISK,cache=none" --onboot 1 \
  --description "macOS Tahoe, made by proxmox-macos-vm.sh${VER:+ (Venera $VER)}" >/dev/null   # no discard: a TRIM over iSCSI crawls
echo "== importing the OpenCore and recovery images as disks"
qm disk import "$VMID" "$OCIMG" "$STORAGE" --format raw >/dev/null
qm disk import "$VMID" "$REC" "$STORAGE" --format raw >/dev/null
OCDISK=$(qm config "$VMID" | sed -n 's/^unused0: //p'); RECDISK=$(qm config "$VMID" | sed -n 's/^unused1: //p')
[ -n "$OCDISK" ] && [ -n "$RECDISK" ] || die "the imported disks didn't show up (qm config $VMID)"
qm set "$VMID" --ide2 "$OCDISK,cache=unsafe" --ide0 "$RECDISK,cache=unsafe" --boot order=ide2 --args "$ARGS" >/dev/null
[ $VENERA = 1 ] && attach_venera_disk

echo "== Done: VM $VMID ($NAME). Start it from the Proxmox web page, open its Console, and install macOS Tahoe:"
echo "   at OpenCore's menu pick the macOS Base System; Disk Utility > View > Show All Devices > erase the VirtIO disk"
echo "   (APFS, GUID Partition Map) > back, Reinstall macOS Tahoe. It restarts a few times, and OpenCore's menu starts on"
echo "   macOS Base System each time: press an arrow key within 5 s to stop it, then pick macOS Installer while it installs,"
echo "   and Macintosh HD once it has (macOS Base System again goes back to the recovery). Setup Assistant can stop on its"
echo "   last screen with no graphics driver yet: if it hasn't moved in a few minutes, restart the VM (Reboot, or Stop and"
echo "   Start); the account is made, and macOS starts at the login window."
echo "   After setup, in macOS: automatic updates off (Venera is tested on 26.7.3; a newer macOS may keep the software"
echo "   desktop); never sleep; set time automatically. The guest agent: build mac-guest-agent (MIT) from source and run"
echo "   its --install (Finish reads Venera's status through it)."
if [ $VENERA = 1 ]; then
  if [ -n "$GPKG" ]; then echo "   Then open Install Venera on the Venera disk (Finder's sidebar, Locations) and restart when it says so."
  else echo "   Then copy Venera's guest package (Install Venera VERSION.pkg) into macOS, open it, and restart when it says so."; fi
  echo "   Then run this again and choose Finish$([ $VIDEO = 1 ] && echo ": it turns on hardware video (on every node you set up),") takes out the"
  echo "   installer disks and restarts the VM."
fi
[ -n "$SERIAL" ] || echo "   Do not sign into an Apple Account in it until you have run this script again with your MacBook's identity."
echo "   Undo: qm destroy $VMID --purge; rm $OCIMG (and $BASE $REC, which the next VM can use; /etc/modprobe.d/kvm-macos.conf)"
