#!/bin/bash
# A macOS Tahoe VM on Proxmox VE, ready for Venera (Metal, OpenGL and hardware video on the host's GPU).
# Run as root on the Proxmox host, from the unpacked Venera-host-VERSION folder: it uses install-host.sh and the guest
# package (guest/Install Venera VERSION.pkg) beside it. It checks the host, asks its questions, shows the plan, and
# changes nothing until you say yes. MIT (vm/README.md), like the script it grew from.
#
#   a new VM:      the host's packages (on each cluster node the VM may run on), Venera's OpenCore image (from this
#                  package) with SIP and AMFI already as Venera needs them, macOS Tahoe's recovery from Apple (or your
#                  own macOS disk, installer or recovery image), the VM with Venus graphics and a sound device, and the
#                  Venera Tools CD. Then: install macOS, open Install Venera on that CD, restart, and run this again to
#                  Finish.
#   an existing VM: Finish (hardware video on every node, the installer disks out, a restart), Ready for Venera (an
#                  older macOS VM: the host's packages, the display, the args and the Venera Tools CD), Upgrade Venera (this
#                  release's host half on every node, then its guest package installed in macOS with the choices it
#                  has, through the guest agent, and a restart), its Mac identity, or OpenCore (moved to Venera's own
#                  image, keeping the VM's settings).
#
# What each piece is for (each one a dead end without it):
#   the SMC key             - without it boot stops at "busy timeout ... AppleACPICPU" (WindowServer can't be decrypted)
#   VeneraHide (OpenCore)   - without it the Apple Account sign-in sees a VM and fails ("Verification failed")
#   -cpu host (+hypervisor) - hiding the hypervisor from the CPU stops the kernel; VeneraHide hides it from Apple's checks
#   TRIM only on thin storage - Disk Utility's erase TRIMs the whole disk, which shared iSCSI storage clears 2 MB at a
#                             time; on thin storage (local-lvm, ZFS, Ceph, a file) TRIM gives freed space back
#   the guest agent         - Venera's (a Customize choice, on by default) on the virtio agent port: clean shutdowns,
#                             the VM's addresses in Proxmox, and Finish and Upgrade work through it
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
  # the versions this release was tested on (the host package's TESTED): say so when Proxmox has moved on
  local p want have d=""
  for p in pve-qemu-kvm libvirglrenderer1 virgl-server mesa-vulkan-drivers; do
    want=$(awk -v p="$p" '$1 == p {print $2}' "$HERE/TESTED" 2>/dev/null); have=$(dpkg-query -W -f '${Version}' "$p" 2>/dev/null || true)
    [ -z "$want" ] || [ -z "$have" ] || [ "$want" = "$have" ] || d="$d $p $have (tested $want);"
  done
  [ -z "$d" ] || warn "this host's graphics stack isn't the one Venera ${VER:-} was tested on:$d install-host.sh --check says how to go back"
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
# thin storage: space a disk frees can go back to it (TRIM). Thick LVM and iSCSI LUNs can't take it back, and a TRIM
# over iSCSI crawls (Disk Utility's erase TRIMs the whole disk, 2 MB at a time)
storage_thin() {
  case $(pvesm status 2>/dev/null | awk -v s="$1" '$1 == s {print $2}') in
    lvm | iscsi | iscsidirect | "") return 1 ;;
    *) return 0 ;;
  esac
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
TOOLS=""; for f in "$HERE"/guest/Venera-Tools-*.iso "$HERE"/Venera-Tools-*.iso; do [ -f "$f" ] && { TOOLS=$f; break; }; done

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
venera_disk() {   # $1 the image to write: the Venera Tools CD (the release's, or made here from the guest package)
  if [ -n "$TOOLS" ]; then cp "$TOOLS" "$1"; return; fi
  local d; d=$(mktemp -d)
  cp "$GPKG" "$d/$(basename "$GPKG")"
  cat >"$d/Read Me.txt" <<TXT
Venera Tools ${VER:-}

Venera for a macOS VM on Proxmox: Metal graphics on the host's GPU, hardware video, and the Proxmox guest agent.

1. Open "$(basename "$GPKG")". Customize has the choices: hardware video, the Venera app and the Proxmox
   guest agent (all on), and Safari WebGL (off: it changes a security setting).
2. Restart when it says so.
3. If the VM was made by proxmox-macos-vm.sh, run it again on the Proxmox host and choose Finish: it turns on hardware
   video and the faster guest agent port, takes out the installer disks (this one too) and restarts the VM.
   Otherwise, in Proxmox: the VM's Options > QEMU Guest Agent: on (type VirtIO), then shut the VM down and start it.

The install guide: https://github.com/jazzphone/venera/blob/main/docs/INSTALL.md
TXT
  genisoimage -quiet -V "Venera Tools" -J -r -o "$1" "$d"; rm -rf "$d"
}

# ---- OpenCore ------------------------------------------------------------------------------------------------------
# Venera's own OpenCore image (vm/opencore/build.sh: acidanthera's OpenCore with Venera's config, ACPI table and
# VeneraHide), carried in the host package's opencore/ folder; nothing to download
OCSRC=""; for f in "$HERE"/opencore/OpenCore-Venera-*.img "$HERE"/OpenCore-Venera-*.img; do [ -f "$f" ] && { OCSRC=$f; break; }; done
OCVER=$(basename "${OCSRC:-x-0}" .img); OCVER=${OCVER##*-}
# OpenCorePkg's macserial (Linux, from the same release): a generated Mac identity
MACSERIAL=""; for f in "$HERE"/opencore/macserial "$HERE"/macserial; do [ -x "$f" ] && { MACSERIAL=$f; break; }; done

# gen_identity: a Mac identity for this VM alone, for $MODEL: macserial's serial and board serial (MLB), made as a
# pair (the serial's model code is $MODEL's, the MLB's board code fits its board-id, the same factory and week, the
# MLB's checksum), and a Wi-Fi MAC address (OpenCore's ROM) with one of Apple's prefixes. Valid in form, unique, and
# registered with no one: macOS takes it; iCloud and iMessage may refuse it.
gen_identity() {
  local pair ouis try
  # macserial for Linux has no arc4random: it seeds its generator the same way every run (one identity for every VM,
  # vm/test.sh caught it). The randomness is ours: a random week and production line, and the last of a random number
  # of pairs (its generator's year and board item move on with each one).
  for try in 1 2 3 4 5; do
    pair=$("$MACSERIAL" -m "$MODEL" -n $((RANDOM % 1000 + 1)) -w $((RANDOM % 52 + 1)) -e $((RANDOM % 3400)) 2>/dev/null | tail -1)
    SERIAL=$(awk -F' [|] ' '{print $1}' <<<"$pair"); MLB=$(awk -F' [|] ' '{print $2}' <<<"$pair")
    [[ $SERIAL =~ ^[A-Z0-9]{10,12}$ && $MLB =~ ^[A-Z0-9]{13,17}$ ]] && break
  done
  # Its board item repeats in a cycle (a few in a hundred VMs got the same board serial): in a 17-character MLB the
  # item (after the location, year and week) is a plain 3-digit number (macserial's FORMAT.md), so it gets a random
  # one, and the last character is set again so the checksum holds (weights 3 at odd places, 1 at even; mod 34).
  if [[ $MLB =~ ^[A-Z0-9]{17}$ ]]; then
    local al=0123456789ABCDEFGHJKLMNPQRSTUVWXYZ m i c sum=0 idx
    m=${MLB:0:6}$(printf %03d $((RANDOM % 1000)))${MLB:9:7}
    for ((i = 0; i < 16; i++)); do
      c=${m:i:1}; idx=${al%%"$c"*}; idx=${#idx}
      sum=$((sum + (i % 2 == 1 ? 3 : 1) * idx))
    done
    MLB=$m${al:$(((34 - sum % 34) % 34)):1}
    "$MACSERIAL" --verify "$MLB" 2>/dev/null | grep -q '^Valid MLB checksum' || die "a generated board serial failed its checksum ($MLB)"
  fi
  [[ $SERIAL =~ ^[A-Z0-9]{10,12}$ && $MLB =~ ^[A-Z0-9]{13,17}$ ]] || die "macserial has no identity for model $MODEL"
  ouis=(00:16:cb 00:1b:63 00:1e:c2 00:23:df 00:25:00 28:cf:e9 3c:07:54 40:6c:8f 68:5b:35 70:cd:60 7c:6d:62 88:63:df a4:83:e7 ac:87:a3 c8:2a:14 f0:18:98)
  ROM="${ouis[$((RANDOM % ${#ouis[@]}))]}:$(od -An -N3 -tx1 /dev/urandom | tr -s ' ' ':' | sed 's/^://')"
  GENERATED=1
}
# serial_model SERIAL: the model identifier the serial's model code is (macserial -i), or nothing
serial_model() { [ -n "$MACSERIAL" ] && "$MACSERIAL" -i "$1" 2>/dev/null | sed -n 's/^ *Model: *[A-Z0-9]* - *\([A-Za-z]*[0-9]*,[0-9]*\).*/\1/p' | head -1; }
MACREC_URL=https://raw.githubusercontent.com/acidanthera/OpenCorePkg/1.0.8/Utilities/macrecovery/macrecovery.py
MACREC_SHA=3023a9b4ca79a5255d93c00f25ab5df37e6f938b729b797d9ecea56184b17aff
TAHOE_BOARD=Mac-CFF7D910A743CAAF   # OpenCorePkg's macrecovery list: macOS 26 Tahoe, "-os latest"

oc_mount() {   # mounts the OpenCore image $OCIMG (a file or a VM disk) at $MNT
  [[ $OCIMG == /dev/* ]] && lvchange -ay "$OCIMG"   # shared LVM keeps a stopped VM's disks inactive
  LOOP=$(losetup -fP --show "$OCIMG"); MNT=$(mktemp -d)
  # the partition's node shows up a moment after the loop device (udev): wait for it, else mount at its offset
  local i; for i in $(seq 1 30); do [ -b "${LOOP}p1" ] && break; udevadm settle 2>/dev/null || sleep 0.1; done
  local start; start=$(partx -g -o START -n 1 "$LOOP" 2>/dev/null || true)
  if [ -b "${LOOP}p1" ]; then mount "${LOOP}p1" "$MNT" || die "couldn't mount the OpenCore image's EFI partition"
  elif [ -n "$start" ]; then mount -o offset=$((start * 512)) "$LOOP" "$MNT" || die "couldn't mount the OpenCore image's EFI partition"
  else losetup -d "$LOOP"; rmdir "$MNT"; die "$OCIMG has no partition table OpenCore's EFI partition can be found in"; fi
  [ -f "$MNT/EFI/OC/config.plist" ] || { oc_umount; die "$OCIMG has no EFI/OC/config.plist"; }
}
oc_umount() { sync; umount "$MNT"; losetup -d "$LOOP"; rmdir "$MNT"; [[ $OCIMG == /dev/* ]] && lvchange -an "$OCIMG" || true; }

oc_config() {   # edits config.plist $1: settings from the environment (OC_RES, OC_TIMEOUT, OC_TRIM, OC_CSR, OC_ARGS,
  # MODEL/SERIAL/MLB/ROM)
  python3 - "$1" <<'PY'
import os, plistlib, sys, uuid
p = sys.argv[1]
with open(p, "rb") as f: c = plistlib.load(f)
e = os.environ.get
if e("OC_RES"):
    c["UEFI"]["Output"]["Resolution"] = e("OC_RES") + "@32"
if e("OC_TIMEOUT"):
    c["Misc"]["Boot"]["Timeout"] = int(e("OC_TIMEOUT"))
if e("OC_TRIM"):   # APFS's TRIM at mount: macOS's own timeout (-1), or none (0)
    c["Kernel"]["Quirks"]["SetApfsTrimTimeout"] = -1 if e("OC_TRIM") == "on" else 0
if e("OCVER"):
    print("   OpenCore %s (Venera's): VeneraHide, %s, boot menu %s s" % (e("OCVER"), e("OC_RES"), e("OC_TIMEOUT", "5")))
else:
    if e("OC_RES"): print("   screen at startup:", e("OC_RES"))
    if e("OC_TIMEOUT"): print("   OpenCore's menu:", e("OC_TIMEOUT"), "s")
    if e("OC_TRIM"): print("   APFS TRIM:", e("OC_TRIM"))
if e("NEWUUID"):   # each VM its own hardware UUID (the sample's is zeros)
    c["PlatformInfo"]["Generic"]["SystemUUID"] = str(uuid.uuid4()).upper()
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

prepare_opencore() {   # on the new OpenCore image $OCIMG (a copy of Venera's): the screen size, SIP/AMFI, the identity
  oc_mount
  OCVER=$OCVER NEWUUID=1 OC_RES=$RES OC_TIMEOUT=5 OC_TRIM=$TRIM OC_ARGS=$BOOTARGS OC_CSR=$CSR MODEL=$MODEL SERIAL=$SERIAL MLB=$MLB ROM=$ROM oc_config "$MNT/EFI/OC/config.plist" ||
    { oc_umount; die "OpenCore's config.plist couldn't be edited"; }
  oc_umount
}

# An existing VM's OpenCore disk moved to Venera's OpenCore: the new EFI folder and config, with what was the VM's own
# carried over (Venera's kexts and their entries, boot-args and SIP, the Mac identity, the screen size, the menu's
# timeout); what the old image brought and Venera doesn't need (Lilu, VMHide, WhateverGreen, AppleALC, Broadcom
# Bluetooth, OpenCanopy and its Resources) is left behind. The VM stopped; the old disk saved first.
oc_transplant() {   # OLD-config NEW-config: writes the merge into NEW
  python3 - "$1" "$2" <<'PY'
import plistlib, sys
old = plistlib.load(open(sys.argv[1], "rb")); new = plistlib.load(open(sys.argv[2], "rb"))
mine = ("VirtioGPU.kext", "VeneraVideo.kext", "VeneraConsole.kext")
kept = [k for k in old["Kernel"]["Add"] if k.get("BundlePath") in mine]
new["Kernel"]["Add"] += kept
g = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
for k in ("boot-args", "csr-active-config"):
    if k in old["NVRAM"]["Add"].get(g, {}): new["NVRAM"]["Add"][g][k] = old["NVRAM"]["Add"][g][k]
new["PlatformInfo"]["Generic"] = old["PlatformInfo"]["Generic"]
for k in ("Automatic", "UpdateSMBIOSMode", "UpdateDataHub", "UpdateNVRAM", "UpdateSMBIOS"):
    if k in old["PlatformInfo"]: new["PlatformInfo"][k] = old["PlatformInfo"][k]
new["UEFI"]["Output"]["Resolution"] = old["UEFI"]["Output"].get("Resolution", new["UEFI"]["Output"]["Resolution"])
new["Misc"]["Boot"]["Timeout"] = old["Misc"]["Boot"].get("Timeout", 5)
plistlib.dump(new, open(sys.argv[2], "wb"))
print("   kept:", ", ".join(k["BundlePath"] for k in kept) or "no Venera kexts yet", "| boot-args:",
      new["NVRAM"]["Add"][g].get("boot-args"), "| model:", new["PlatformInfo"]["Generic"].get("SystemProductName"),
      "| screen:", new["UEFI"]["Output"]["Resolution"])
PY
}
update_opencore() {   # the VM stopped, OCIMG its OpenCore disk
  local w old
  [ -n "$OCSRC" ] || die "Venera's OpenCore image isn't beside this script (the host package's opencore/ folder)"
  w=$(mktemp -d); mkdir -p "$w/src" "$w/old"
  mount -o ro,loop,offset=$((2048 * 512)) "$OCSRC" "$w/src"   # its EFI partition starts at sector 2048 (build.sh)
  oc_mount
  old=$(ls -d "$MNT"/EFI/OC/Kexts/*.kext 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')
  cp "$MNT/EFI/OC/config.plist" "$w/old/config.plist"
  for k in VirtioGPU VeneraVideo VeneraConsole; do [ -d "$MNT/EFI/OC/Kexts/$k.kext" ] && cp -R "$MNT/EFI/OC/Kexts/$k.kext" "$w/old/"; done
  echo "   the old EFI folder's kexts: $old"
  rm -rf "$MNT/EFI"
  cp -R "$w/src/EFI" "$MNT/"
  for k in "$w"/old/*.kext; do [ -d "$k" ] && cp -R "$k" "$MNT/EFI/OC/Kexts/"; done
  oc_transplant "$w/old/config.plist" "$MNT/EFI/OC/config.plist"
  oc_umount
  umount "$w/src"; rm -rf "$w"
}

apply_identity() {   # an existing VM's OpenCore disk: the Mac identity only
  oc_mount
  MODEL=$MODEL SERIAL=$SERIAL MLB=$MLB ROM=$ROM oc_config "$MNT/EFI/OC/config.plist"
  oc_umount
}
oc_read() {   # config.plist $1's settings as shell assignments: CUR_RES CUR_TIMEOUT CUR_ARGS CUR_MODEL CUR_TRIM
  python3 - "$1" <<'PY'
import plistlib, shlex, sys
c = plistlib.load(open(sys.argv[1], "rb"))
v = {"CUR_RES": str(c["UEFI"]["Output"].get("Resolution", "")).split("@")[0],
     "CUR_TIMEOUT": str(c["Misc"]["Boot"].get("Timeout", 5)),
     "CUR_ARGS": c["NVRAM"]["Add"].get("7C436110-AB2A-4BBB-A880-FE41995C9F82", {}).get("boot-args", ""),
     "CUR_MODEL": c["PlatformInfo"]["Generic"].get("SystemProductName", ""),
     "CUR_TRIM": "off" if c["Kernel"]["Quirks"].get("SetApfsTrimTimeout", -1) == 0 else "on"}
for k, x in v.items(): print("%s=%s" % (k, shlex.quote(x)))
PY
}
# The size macOS's desktop starts at is the one QEMU's display reports (its EDID's preferred mode: xres and yres,
# 1280x800 when not given); VirtioGPUFramebuffer offers it among its modes, up to 1920x1200. OpenCore's resolution is
# the menu's and Recovery's (and the basic display's, without Venera).
screen_args() {   # the VM's args line $1 with the display's size $2 (WxH), as -global virtio-vga-gl.xres/yres
  local a w=${2%x*} h=${2#*x}
  a=$(sed -E 's/ ?-global virtio-vga-gl\.(xres|yres)=[0-9]+//g' <<<" $1")
  a="$a -global virtio-vga-gl.xres=$w -global virtio-vga-gl.yres=$h"
  echo "${a# }"
}
screen_size() {   # $1 WxH, $2 1 for a Venera VM: dies unless a size the VM can show
  [[ $1 =~ ^([0-9]{3,4})x([0-9]{3,4})$ ]] || die "a screen size is like 1280x800"
  [ "${BASH_REMATCH[1]}" -ge 640 ] && [ "${BASH_REMATCH[2]}" -ge 480 ] || die "the smallest screen is 640x480"
  [ "$2" != 1 ] || { [ "${BASH_REMATCH[1]}" -le 1920 ] && [ "${BASH_REMATCH[2]}" -le 1200 ]; } ||
    die "Venera's display goes up to 1920x1200"
}

# The startup settings people change most, without editing config.plist: the screen size, verbose startup, the
# menu's seconds, Venera on or off, other boot-args. Venera's own boot-args (amfi_get_out_of_my_way=1, vgpuaccel=N)
# are kept as they are. The VM stopped, OCIMG its OpenCore disk; DO_ID=1 when the model and identity come next.
startup_settings() {
  local cfg a x="" v=0 off=0 own="" k s t ven=0 cur_disp xr yr changes=() disk trim_now
  oc_mount; cfg=$(oc_read "$MNT/EFI/OC/config.plist"); oc_umount; eval "$cfg"
  for a in $CUR_ARGS; do
    case $a in
      -v) v=1 ;;
      -vgpuoff) off=1 ;;
      amfi_get_out_of_my_way=* | vgpuaccel=*) own="$own $a" ;;
      *) x="$x $a" ;;
    esac
  done
  x=${x# }; own=${own# }
  qm config "$VMID" | grep -q '^vga: virtio-gl' && ven=1
  xr=$(qm config "$VMID" | sed -n 's/^args:.*-global virtio-vga-gl\.xres=\([0-9]*\).*/\1/p')
  yr=$(qm config "$VMID" | sed -n 's/^args:.*-global virtio-vga-gl\.yres=\([0-9]*\).*/\1/p')
  if [ $ven = 1 ]; then cur_disp=${xr:-1280}x${yr:-800}; else cur_disp=$CUR_RES; fi
  [[ $cur_disp =~ ^[0-9]+x[0-9]+$ ]] || cur_disp=1280x800
  disk=$(qm config "$VMID" | sed -n 's/^virtio0: //p')
  if [ -n "$disk" ] && [[ ,$disk, == *,discard=on,* ]] && [ "$CUR_TRIM" = on ]; then trim_now=on; else trim_now=off; fi
  local S=$cur_disp V=$v T=$CUR_TIMEOUT OFF=$off X=$x R=$trim_now
  DO_ID=0
  while :; do
    echo; echo "  VM $VMID's startup settings (OpenCore's config.plist$([ $ven = 1 ] && echo " and the VM's display")):"
    echo "    1  Screen size: $S$([ $ven = 1 ] && echo "   (macOS's desktop, up to 1920x1200; Recovery and OpenCore's menu too)")"
    echo "    2  Verbose startup: $([ $V = 1 ] && echo on || echo off)   (-v: the kernel's messages instead of the Apple logo)"
    echo "    3  OpenCore's menu: $T s   (the time to pick another disk or Recovery)"
    echo "    4  Venera at startup: $([ $OFF = 1 ] && echo "off (-vgpuoff: the basic display)" || echo on)"
    echo "    5  Other boot-args: ${X:-none}${own:+   (kept for Venera: $own)}"
    echo "    6  Model and Mac identity: ${CUR_MODEL:-?}   (generate new serials, or enter your Mac's: asked next)"
    [ -z "$disk" ] || echo "    7  TRIM: $R   (space macOS frees goes back to ${disk%%:*}; thin storage only)"
    ask k "Change which (Enter when done)" ""
    case $k in
      "") break ;;
      1) ask s "Screen size" "$S"; screen_size "$s" $ven; S=$s ;;
      2) V=$((1 - V)) ;;
      3) ask t "OpenCore's menu, seconds (1-30)" "$T"; [[ $t =~ ^[0-9]+$ ]] && [ "$t" -ge 1 ] && [ "$t" -le 30 ] || die "1 to 30 seconds"; T=$t ;;
      4) OFF=$((1 - OFF)) ;;
      5) ask s "Other boot-args (- for none)" "${X:--}"; [ "$s" = - ] && s=""
         for a in $s; do case $a in -v | -vgpuoff | amfi_get_out_of_my_way=* | vgpuaccel=*) die "$a has its own setting (or is Venera's)" ;; esac; done
         X=$s ;;
      6) DO_ID=1; break ;;
      7) [ -n "$disk" ] || { echo "  (no virtio0 disk)"; continue; }
         if [ "$R" = off ] && ! storage_thin "${disk%%:*}"; then echo "  (${disk%%:*} isn't thin storage: it can't take space back)"; continue; fi
         [ "$R" = on ] && R=off || R=on ;;
      *) echo "  (1 to 7, or Enter)" ;;
    esac
  done
  [ "$S" = "$cur_disp" ] || changes+=("screen size $cur_disp -> $S")
  [ "$V" = "$v" ] || changes+=("verbose startup $([ $V = 1 ] && echo on || echo off)")
  [ "$T" = "$CUR_TIMEOUT" ] || changes+=("OpenCore's menu $T s")
  [ "$OFF" = "$off" ] || changes+=("Venera at startup $([ $OFF = 1 ] && echo off || echo on)")
  [ "$X" = "$x" ] || changes+=("other boot-args: ${X:-none}")
  [ "$R" = "$trim_now" ] || changes+=("TRIM $R (OpenCore's APFS TRIM and the disk's discard)")
  [ ${#changes[@]} -gt 0 ] || { [ $DO_ID = 1 ] && return 0; die "nothing changed"; }
  local args; args=$(echo $X $own $([ $V = 1 ] && echo -v) $([ $OFF = 1 ] && echo -vgpuoff))
  echo; echo "== The plan"
  for k in "${changes[@]}"; do echo "  - $k"; done
  echo "  - boot-args: $args"
  echo "  - the OpenCore disk saved first, to /root$([ $ven = 1 ] && [ "$S" != "$cur_disp" ] && echo "; the VM's config to /root/macos-vm-backup")"
  yes_no "Go ahead?" || die "nothing changed"
  [[ $OCIMG == /dev/* ]] && lvchange -ay "$OCIMG"
  BK=/root/opencore-$NAME-$(date +%Y%m%d-%H%M%S).img; dd if="$OCIMG" of="$BK" bs=1M status=none
  oc_mount
  OC_RES=$([ "$S" = "$cur_disp" ] || echo "$S") OC_TIMEOUT=$([ "$T" = "$CUR_TIMEOUT" ] || echo "$T") OC_ARGS=$args \
    OC_TRIM=$([ "$R" = "$trim_now" ] || echo "$R") \
    oc_config "$MNT/EFI/OC/config.plist" || { oc_umount; die "OpenCore's config.plist couldn't be edited (the disk is saved as $BK)"; }
  oc_umount
  if [ $ven = 1 ] && [ "$S" != "$cur_disp" ]; then
    backup_conf
    qm set "$VMID" --args "$(screen_args "$(qm config "$VMID" | sed -n 's/^args: //p')" "$S")" >/dev/null
    echo "   the VM's display: $S"
  fi
  if [ "$R" != "$trim_now" ]; then
    [ $ven = 1 ] && [ "$S" != "$cur_disp" ] || backup_conf
    local nd; nd=$(sed -E 's/,discard=[a-z]+//' <<<"$disk"); [ "$R" = on ] && nd="$nd,discard=on"
    qm set "$VMID" --virtio0 "$nd" >/dev/null
    echo "   the disk: $nd"
  fi
  echo "== Done (the previous OpenCore disk is saved as $BK; dd it back to undo)."
}

# ---- an existing VM ------------------------------------------------------------------------------------------------
guest() {   # guest COMMAND: runs a shell command in macOS through the guest agent, prints its output
  qm guest exec "$VMID" --timeout 60 -- /bin/sh -c "$1" 2>/dev/null |
    python3 -c 'import json, sys; d = json.load(sys.stdin); print(d.get("out-data", ""), end="")' 2>/dev/null || true
}
clipboard_ok() {   # the console's clipboard (vga clipboard=vnc) keeps live migration only from machine 10.1 (Proxmox)
  local m; m=$(qm config "$VMID" 2>/dev/null | sed -n 's/^machine: //p')
  case $m in *q35-[0-9]*|*i440fx-[0-9]*|pc-[0-9]*) ;; *) return 0 ;; esac   # unpinned: the newest, fine
  local v; v=$(grep -o '[0-9][0-9]*\.[0-9][0-9]*' <<<"$m" | head -1)
  [ -n "$v" ] && [ "$(printf '%s\n10.1\n' "$v" | sort -V | head -1)" = 10.1 ]
}
drop_disk() {   # takes the disk in slot $1 out of the VM and deletes its volume (the VM stopped)
  local vol u
  vol=$(qm config "$VMID" | sed -n "s/^$1: \([^,]*\).*/\1/p"); [ -n "$vol" ] || return 0
  qm set "$VMID" --delete "$1" >/dev/null
  case $vol in *:iso/*) echo "   $1 ($vol) taken out (the ISO stays in the storage)"; return 0 ;; esac
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
# Bring your own macOS: the files in the ISO storages' template/iso folders and their import folders (where Proxmox
# keeps disk images to import) that could be a macOS disk or a macOS installer or recovery image. One line each:
# PATH <tab> disk|installer <tab> size in GB. Venera's own files (OpenCore, the Tools CD) and other OSes' ISOs that
# say what they are in their name are left out.
macos_sources() {
  local st base f size kind
  for st in $(pvesm status --content iso 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}'); do
    base=$(pvesm path "$st:iso/x.iso" 2>/dev/null) || continue; base=${base%/template/iso/x.iso}
    for f in "$base"/template/iso/* "$base"/import/*; do
      [ -f "$f" ] || continue
      case ${f##*/} in
        OpenCore-*|Venera-Tools-*|*.part|*debian*|*ubuntu*|*SERVER_EVAL*|*[Ww]indows*|*Win1*|*virtio-win*|*proxmox*) continue ;;
      esac
      size=$(( $(stat -c %s "$f") / 1073741824 ))
      case ${f,,} in
        *.qcow2|*.vmdk|*.vhdx|*.vhd|*.vdi) kind=disk ;;
        *.dmg) kind=installer ;;
        *.iso|*.img|*.cdr|*.raw) if [ "$size" -ge 20 ]; then kind=disk; else kind=installer; fi ;;
        *) continue ;;
      esac
      printf '%s\t%s\t%s\n' "$f" "$kind" "$size"
    done
  done
}

iso_storage() {   # an active storage that holds ISOs: a shared one first (HA may start the VM on another node)
  pvesh get /nodes/"$(hostname)"/storage --content iso --output-format json 2>/dev/null | python3 -c '
import json, sys
st = [s for s in json.load(sys.stdin) if s.get("active")]
st.sort(key=lambda s: not s.get("shared"))
print(st[0]["storage"] if st else "")'
}
attach_venera_disk() {   # the Venera Tools CD in ide1 (macOS shows it on the desktop), unless ide1 is in use
  [ -n "$GPKG" ] || return 0
  if [ -n "$(disk_of ide1)" ]; then echo "   ide1 is in use: no Venera Tools CD (copy the package in yourself)"; return 0; fi
  local st iso path
  st=$(iso_storage); [ -n "$st" ] || { echo "   no storage holds ISOs here: no Venera Tools CD (copy the package in yourself)"; return 0; }
  iso="Venera-Tools-${VER:-guest}.iso"
  path=$(pvesm path "$st:iso/$iso") || return 0
  [ -f "$path" ] || venera_disk "$path"
  qm set "$VMID" --ide1 "$st:iso/$iso,media=cdrom" >/dev/null
  echo "   ide1: the Venera Tools CD ($st:iso/$iso)"
}

finish_vm() {   # macOS and Venera installed: hardware video, the installer disks out, a restart; the old clean-ups
  local st="" up=0 nodes=() n
  echo; echo "== Finish VM $VMID"
  qm guest cmd "$VMID" ping >/dev/null 2>&1 && up=1
  if [ $up = 1 ]; then
    st=$(guest 'V="/Library/Application Support/Venera"; [ -e "$V/VERSION" ] && echo "Venera $(cat "$V/VERSION") in macOS"; [ -e "$V/VIDEO" ] && echo "with its video choice"; kextstat 2>/dev/null | grep -q VeneraVideo && echo "VeneraVideo.kext loaded"; [ -f /Library/LaunchDaemons/local.venera.agent.plist ] && echo "Venera'"'"'s guest agent"')
    if [ -n "$st" ]; then echo "$st" | sed 's/^/  /'
    else warn "Venera isn't installed in macOS yet: open Install Venera on the Venera Tools CD first (or go on without it)"; fi
  else
    echo "  (no guest agent answers: can't read Venera's status. Venera's installer puts one in, its Proxmox guest agent"
    echo "   choice; on a VM made before 0.1.6 the agent port may be ISA: it answers there too)"
  fi
  local VIDEO=0 drops=() HASDEV=0 RESTART=0 VIRTIO_AGENT=0 CLIP=0
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
    [ -n "$(disk_of $s)" ] && yes_no "Take out $s ($(disk_of $s): the macOS recovery or the Venera Tools CD)?" && drops+=("$s")
  done
  # Venera's agent answers on either port; the virtio one is ten times faster than the ISA serial port
  if [[ $st == *"guest agent"* ]] && ! qm config "$VMID" | grep -q '^agent:.*type=virtio'; then VIRTIO_AGENT=1; fi
  # the Proxmox console's clipboard (Venera's clipboard agent on the other end), where live migration keeps working
  if [[ $st == *"guest agent"* ]] && ! qm config "$VMID" | grep -q '^vga:.*clipboard=vnc'; then
    if clipboard_ok; then CLIP=1; else echo "  (the console's clipboard: not on a VM pinned below machine 10.1, which then couldn't live-migrate)"; fi
  fi
  { [ $VIDEO = 1 ] && [ $HASDEV = 0 ]; } || [ ${#drops[@]} -gt 0 ] || [ $VIRTIO_AGENT = 1 ] || [ $CLIP = 1 ] && RESTART=1
  echo; echo "== The plan"
  [ $VIDEO = 1 ] && echo "  - hardware video: install-host.sh --vm $VMID here${nodes[*]:+ and on ${nodes[*]}}$([ $HASDEV = 1 ] && echo " (the VM has its device: this updates the service)")"
  [ ${#drops[@]} -gt 0 ] && echo "  - take out ${drops[*]} (the recovery disk is deleted; the Venera Tools ISO stays in its storage)"
  [ $VIRTIO_AGENT = 1 ] && echo "  - the guest agent on its virtio port (faster than the ISA serial port)"
  [ $CLIP = 1 ] && echo "  - the Proxmox console's clipboard shared with macOS (display: clipboard=vnc)"
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
  [ $VIRTIO_AGENT = 0 ] || { qm set "$VMID" --agent enabled=1,type=virtio >/dev/null; echo "   guest agent port: virtio"; }
  [ $CLIP = 0 ] || { qm set "$VMID" --vga "$(qm config "$VMID" | sed -n 's/^vga: //p'),clipboard=vnc" >/dev/null; echo "   display: the console's clipboard on"; }
  [ $RESTART = 0 ] || { echo "== starting VM $VMID"; qm start "$VMID"; }
  echo "== Done. In macOS, the Venera app (Applications) shows what runs. The config before: /root/macos-vm-backup/."
}

ready_vm() {   # an existing macOS VM (stopped): the host's packages, the display, the args, the Venera Tools CD
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
  [ -n "$GPKG" ] && echo "  - the Venera Tools CD in ide1 with $(basename "$GPKG")"
  echo "  (the config is backed up to /root/macos-vm-backup first)"
  yes_no "Go ahead?" || die "nothing changed"
  echo "== the host"; host_prep $VENUS_PKGS genisoimage || die "the packages didn't install (apt)"
  for n in "${nodes[@]}"; do echo "== $n"; on_node "$n" "$(declare -f missing_pkgs host_prep); host_prep $VENUS_PKGS" || die "$n's packages didn't install (apt on $n)"; done
  backup_conf
  qm set "$VMID" --vga "virtio-gl$(clipboard_ok && echo ,clipboard=vnc)" --args "$new" >/dev/null; echo "   display virtio-gl, args updated"
  attach_venera_disk
  echo "== Done. Start VM $VMID, open Install Venera on the Venera Tools CD (on the desktop) and restart when"
  echo "   it says so (when SIP has to change it finishes after one more restart). Then run this again and choose Finish."
}

choices_xml() {   # Installer's choice changes for the guest package: $1 video, $2 app, $3 webgl, $4 agent (each 0 or 1)
  local c
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><array>'
  for c in "video $1" "app $2" "webgl $3" "agent ${4:-1}"; do
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
hmp() {   # hmp COMMAND: one QEMU monitor command in the running VM, through Proxmox's own monitor call; `qm monitor`
  # reads the keyboard instead of its input when it runs in a terminal, and leaves you at its qm> prompt
  perl -MPVE::QemuServer::Monitor=mon_cmd -e \
    'print mon_cmd($ARGV[0], "human-monitor-command", "command-line" => $ARGV[1])' "$VMID" "$1" 2>&1 </dev/null
}
# agent_put LOCAL REMOTE: a file into macOS through the guest agent (guest-file-write, 4 MB at a time, through
# Proxmox's own agent call), checked by its SHA-256 there. Venera's agent takes it whatever the screen shows; an older
# agent that can't fails here, and the Upgrade takes a USB disk instead.
agent_put() {
  perl -MPVE::QemuServer::Monitor=mon_cmd -MMIME::Base64 -e '
    my ($vmid, $src, $dst) = @ARGV;
    open(my $in, "<:raw", $src) or die "$src: $!\n";
    my $h = mon_cmd($vmid, "guest-file-open", path => $dst, mode => "wb", timeout => 30);
    my ($buf, $n);
    while ($n = read($in, $buf, 4 << 20)) {
      my $r = mon_cmd($vmid, "guest-file-write", handle => $h, "buf-b64" => encode_base64($buf, ""), timeout => 60);
      die "wrote $r->{count} of $n bytes\n" if $r->{count} != $n;
    }
    mon_cmd($vmid, "guest-file-close", handle => $h, timeout => 30);' "$VMID" "$1" "$2" </dev/null 2>/dev/null || return 1
  [ "$(guest "shasum -a 256 '$2' | cut -d' ' -f1")" = "$(sha256sum "$1" | cut -d' ' -f1)" ]
}
usb_disk() {   # usb_disk add IMAGE | del: the image as a USB drive in the running VM, on the EHCI bus (macOS ignores
  # a drive on the XHCI's hub); QEMU drops the drive with the device, and both are gone at the VM's next start
  if [ "$1" = add ]; then
    local o
    o=$(hmp "drive_add 0 if=none,id=venera-upg,file=$2,format=raw,readonly=on"
      hmp "device_add usb-storage,drive=venera-upg,id=venera-upgdev,bus=ehci.0,removable=on")
    if grep -q -i -E 'error|could not|not found|duplicate|not running|died' <<<"$o"; then echo "$o" >&2; return 1; fi
    return 0
  fi
  hmp "device_del venera-upgdev" >/dev/null 2>&1 || true
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
  local st cur="" video=0 app=0 agent=1 webgl=0 user="" HASDEV=0 nodes=() n img mnt out k
  [ -n "$GPKG" ] || die "no guest package beside this script: run it from the unpacked Venera-host folder"
  echo; echo "== Upgrade VM $VMID to Venera ${VER:-?}"
  qm status "$VMID" | grep -q running || die "VM $VMID isn't running: start it (the upgrade goes in through the guest agent), then run this again"
  qm guest cmd "$VMID" ping >/dev/null 2>&1 || die "VM $VMID's guest agent doesn't answer: copy $(basename "$GPKG") into macOS and open it instead"
  st=$(guest 'V="/Library/Application Support/Venera"; [ -e "$V/VERSION" ] && echo "version $(cat "$V/VERSION")"; [ -e "$V/VIDEO" ] && echo video; [ -d /Applications/Venera.app ] && echo app; [ -e "$V/NO_SYSVOL" ] && echo nosysvol; [ -e "$V/NO_AGENT" ] && echo noagent; csrutil authenticated-root status 2>/dev/null | grep -qi disabled && echo authroot-off; stat -f %Su /dev/console')
  cur=$(sed -n 's/^version //p' <<<"$st")
  [ -n "$cur" ] || die "Venera isn't installed in VM $VMID's macOS: open Install Venera there (Ready for Venera makes the disk)"
  grep -qx video <<<"$st" && video=1
  grep -qx app <<<"$st" && app=1
  grep -qx noagent <<<"$st" && agent=0
  grep -qx authroot-off <<<"$st" && ! grep -qx nosysvol <<<"$st" && webgl=1
  user=$(tail -1 <<<"$st"); [ "$user" = root ] && user=""
  case " $(qm config "$VMID" | sed -n 's/^args: //p') " in *"/run/venera-video-$VMID.sock"*) HASDEV=1 ;; esac
  echo "  macOS has Venera $cur: hardware video $([ $video = 1 ] && echo on || echo off), the Venera app $([ $app = 1 ] && echo on || echo off), the guest agent $([ $agent = 1 ] && echo on || echo off), Safari WebGL (the system-volume copy) $([ $webgl = 1 ] && echo on || echo off)"
  if [ $HASDEV = 1 ]; then
    [ -n "$HOSTKIT" ] || die "VM $VMID has hardware video but Venera's host half isn't beside this script"
    for n in $(vm_other_nodes); do no_yes "The host half on $n too (HA may start the VM there)?" && nodes+=("$n"); done
  fi
  echo; echo "== The plan"
  [ $HASDEV = 1 ] && echo "  - the host half: install-host.sh --vm $VMID here${nodes[*]:+ and on ${nodes[*]}} (running VMs keep their video connections)"
  echo "  - in macOS: $(basename "$GPKG") through the guest agent, with the same choices, then a restart"
  echo "    (an older guest agent that can't take it: from a USB disk, while someone is logged in with the screen unlocked)"
  [ -z "$user" ] || echo "    ($user is logged in: the restart closes their apps, and anything unsaved is lost)"
  yes_no "Go ahead?" || die "nothing changed"
  for n in "${nodes[@]}"; do   # the other nodes first: the VM needs its socket wherever it starts
    echo "== the host half on $n"
    tar -C "$(dirname "$HOSTKIT")" -cz "$(basename "$HOSTKIT")" | on_node "$n" "mkdir -p /root/venera && tar -C /root/venera -xz"
    on_node "$n" "/root/venera/$(basename "$HOSTKIT")/install-host.sh --vm $VMID" | sed 's/^/   /'
  done
  if [ $HASDEV = 1 ]; then echo "== the host half here"; "$HOSTKIT/install-host.sh" --vm "$VMID" | sed 's/^/   /'; fi
  echo "== the guest package"
  local via=agent pkg=/private/var/tmp/venera-upgrade.pkg
  if agent_put "$GPKG" "$pkg"; then
    echo "   copied in through the guest agent"; mnt=$pkg
  else
    via=usb; guest "rm -f '$pkg'" >/dev/null
    echo "   the guest agent couldn't take it: a USB disk instead"
    usb_upgrade_disk || exit 1
  fi
  guest "printf '%s' '$(choices_xml $video $app $webgl $agent)' > /private/var/tmp/venera-choices.xml" >/dev/null
  out=$(guest_rc 900 "/usr/sbin/installer -pkg '$mnt' -target / -applyChoiceChangesXML /private/var/tmp/venera-choices.xml 2>&1; rm -f /private/var/tmp/venera-choices.xml")
  sed 's/^/   /' <<<"$out" | grep -v '^   rc='
  if [ $via = usb ]; then guest "diskutil eject '$(dirname "$mnt")' >/dev/null 2>&1" >/dev/null; sleep 2; usb_disk del; rm -f "$img"
  else guest "rm -f '$pkg'" >/dev/null; fi
  grep -qx 'rc=0' <<<"$out" || die "the install failed: its log is /Library/Application Support/Venera/install.log in macOS; nothing restarted"
}
usb_upgrade_disk() {   # the guest package on a USB disk in the running VM, mounted by macOS: sets img and mnt
  mkdir -p /root/venera; img=/root/venera/venera-upgrade-$VMID.iso
  venera_disk "$img"
  while :; do   # loginwindow turns the disk away (and ejects it) while the screen is locked or nobody is logged in
    case $(screen_state) in
      locked) ask k "macOS's screen is locked, and it won't take a USB disk then: unlock it (the VM's console or Screen Sharing), then press Enter" ;;
      nobody) ask k "nobody is logged in to macOS, and it won't take a USB disk then: log in (the VM's console or Screen Sharing), then press Enter" ;;
      *) break ;;
    esac
  done
  usb_disk add "$img" || { rm -f "$img"; die "the USB disk didn't attach"; }
  mnt=""; for n in $(seq 1 24); do
    mnt=$(guest "ls -d /Volumes/*/'$(basename "$GPKG")' 2>/dev/null | head -1"); [ -n "$mnt" ] && break; sleep 5
  done
  if [ -z "$mnt" ]; then usb_disk del; rm -f "$img"; die "macOS didn't mount the USB disk in 2 minutes (did its screen lock?): nothing installed"; fi
}
upgrade_restart() {   # after upgrade_vm: macOS restarted, and what runs once it's back
  echo "== restarting macOS"
  qm guest exec "$VMID" --timeout 10 -- /sbin/shutdown -r now >/dev/null 2>&1 || true
  sleep 30
  for n in $(seq 1 60); do qm guest cmd "$VMID" ping >/dev/null 2>&1 && break; sleep 5; done
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
  echo "    2  Ready for Venera: an older macOS VM gets Venus graphics, a sound device and the Venera Tools CD"
  echo "    3  Its model and Mac identity (generate new serials, or yours, for iCloud)"
  echo "    4  Upgrade Venera${VER:+ to $VER}: the host half on every node, then the guest package in macOS, and a restart"
  echo "    5  OpenCore ${OCVER:-?}: move the VM (stopped) to Venera's OpenCore, keeping its settings and identity"
  echo "    6  Startup settings: screen size, verbose startup, OpenCore's menu, Venera on or off, boot-args"
  ask WHAT "Which" "1"
  case $WHAT in
    1) finish_vm; exit 0 ;;
    2) host_versions; [ "$GPU_KIND" != none ] || die "no GPU the host can render on: Venera needs one"; ready_vm; exit 0 ;;
    3) ;;
    4) upgrade_vm; upgrade_restart; exit 0 ;;
    5 | 6) ;;
    *) die "nothing changed" ;;
  esac
  if ! qm status "$VMID" | grep -q stopped; then
    yes_no "VM $VMID is running: shut it down now (from macOS, as the Apple menu does)?" ||
      die "shut VM $VMID down first (Proxmox's Shutdown, or Apple menu > Shut Down), then run this again"
    stop_vm
  fi
  OCVOL=$(disk_of ide2); [ -n "$OCVOL" ] || die "VM $VMID has no OpenCore disk on ide2"
  OCIMG=$(pvesm path "$OCVOL"); MODE=identity
  if [ "$WHAT" = 6 ]; then
    startup_settings
    if [ $DO_ID = 0 ]; then
      no_yes "Start VM $VMID now?" && qm start "$VMID" && echo "== VM $VMID is starting."
      exit 0
    fi
  fi
  if [ "$WHAT" != 5 ]; then oc_mount; eval "$(oc_read "$MNT/EFI/OC/config.plist")"; oc_umount; fi
  if [ "$WHAT" = 5 ]; then
    [ -n "$OCSRC" ] || die "Venera's OpenCore image isn't beside this script (the host package's opencore/ folder)"
    echo; echo "== The plan"
    echo "  - VM $VMID's OpenCore disk ($OCVOL): OpenCore $OCVER, Venera's config and VeneraHide in place of the old EFI"
    echo "    folder; kept: Venera's kexts and their entries, boot-args and SIP, the Mac identity, the screen size"
    echo "  - the old disk saved first, to /root"
    yes_no "Go ahead?" || die "nothing changed"
    [[ $OCIMG == /dev/* ]] && lvchange -ay "$OCIMG"
    BK=/root/opencore-$NAME-$(date +%Y%m%d-%H%M%S).img; dd if="$OCIMG" of="$BK" bs=1M status=none
    update_opencore
    echo "== Done (the previous OpenCore disk is saved as $BK; dd it back to undo). Start VM $VMID."; exit 0
  fi
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
  TRIM=off
  if storage_thin "$STORAGE"; then
    no_yes "TRIM: give the space macOS frees back to $STORAGE (it's thin storage)?" && TRIM=on
  else echo "  ($STORAGE is $(pvesm status | awk -v s="$STORAGE" '$1 == s {print $2}'): no TRIM, it can't take space back)"; fi
  if [ -n "$(other_nodes)" ]; then
    if storage_shared "$STORAGE"; then
      for n in $(other_nodes); do no_yes "Set up node $n too (HA may start the VM there)?" && NODES+=("$n"); done
    else echo "  ($STORAGE is this node's own: the VM stays here, the other nodes aren't set up)"; fi
  fi
  echo; echo "  ISO storage (the VM's OpenCore image and macOS's recovery from Apple go there, ~2.5 GB):"; pvesm status --content iso | sed 's/^/    /'
  ask ISOSTORE "Storage for the downloads" "local"
  pvesm status --content iso | awk 'NR>1{print $1}' | grep -qx "$ISOSTORE" || die "$ISOSTORE can't hold ISO images"
  ISO=$(dirname "$(pvesm path "$ISOSTORE:iso/probe.iso")")
  echo; echo "  Network bridges:"; ip -br link show type bridge | awk '$1 ~ /^vmbr/ {print "    " $1}'
  ask BRIDGE "Bridge" "vmbr0"
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "no bridge $BRIDGE"
  ask VLAN "VLAN tag (empty for none)" ""
  [ -z "$VLAN" ] || num "$VLAN" "the VLAN tag"
  ask VMID "VM number" "$(pvesh get /cluster/nextid)"; num "$VMID" "the VM number"
  # a number another VM (or container) has, anywhere in the cluster, is refused before anything is made
  TAKEN=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if str(r.get("vmid")) == sys.argv[1]: print(r.get("name", "?"), "on", r.get("node", "?")); break' "$VMID" || true)
  [ -z "$TAKEN" ] || die "$VMID is taken ($TAKEN): pick a free number (Enter takes the next free one)"
  qm status "$VMID" >/dev/null 2>&1 && die "VM $VMID already exists"
  compgen -G "/etc/pve/nodes/*/qemu-server/$VMID.conf" >/dev/null && die "VM $VMID already exists on another node"
  ask CORES "Cores" "4"; num "$CORES" "cores"
  ask MEM "Memory in MB" "8192"; num "$MEM" "memory"
  [ $VENERA = 0 ] || [ "$MEM" -ge 8192 ] || die "Venera needs 8192 MB or more"
  ask DISK "Disk in GB" "64"; num "$DISK" "the disk size"
  ask RES "Screen size$([ $VENERA = 1 ] && echo " (up to 1920x1200)")" "1280x800"
  screen_size "$RES" $VENERA
  # where macOS comes from: Apple's recovery, or a disk or installer of your own in an ISO or import folder
  BYO_DISK="" BYO_INST="" SRCS=()
  mapfile -t SRCS < <(macos_sources)
  if [ ${#SRCS[@]} -gt 0 ]; then
    echo "  Where macOS comes from:"
    echo "    1  macOS Tahoe's recovery from Apple (installs the newest Tahoe over the network)"
    for i in "${!SRCS[@]}"; do
      IFS=$'\t' read -r f k g <<<"${SRCS[$i]}"
      echo "    $((i + 2))  $f ($g GB): $([ "$k" = disk ] && echo "a disk with macOS on it, used as the VM's disk" || echo "a macOS installer or recovery image, booted to install")"
    done
    ask SRC "Which" "1"; num "$SRC" "the choice"
    if [ "$SRC" -ge 2 ] && [ "$SRC" -le $((${#SRCS[@]} + 1)) ]; then
      IFS=$'\t' read -r f k g <<<"${SRCS[$((SRC - 2))]}"
      case ${f,,} in *.iso|*.img|*.cdr|*.raw)
        if [ "$k" = disk ]; then no_yes "$(basename "$f") is $g GB: a disk with macOS installed on it?" || k=installer
        else yes_no "$(basename "$f") is $g GB: an installer or recovery image (No: a disk with macOS installed)?" || k=disk; fi ;;
      esac
      if [ "$k" = disk ]; then BYO_DISK=$f; [ "$g" -le "$DISK" ] || DISK=$g; else BYO_INST=$f; fi
    elif [ "$SRC" != 1 ]; then die "no choice $SRC"; fi
  else
    echo "  (macOS from Apple's recovery: no disk or installer image of your own in an ISO storage's template/iso or import folder)"
  fi
  # Apple's SMC key, the same for every Mac (published by the open-source macOS VM projects). The OpenCore image has no
  # VirtualSMC, so without it macOS can't decrypt WindowServer and boot stalls at "busy timeout ... AppleACPICPU".
  OSK="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
  [ -n "$OCSRC" ] || die "Venera's OpenCore image isn't beside this script (the host package's opencore/ folder)"
  OCIMG=$ISO/OpenCore-$NAME.img REC=$ISO/Tahoe-recovery.img
  [ ! -f "$OCIMG" ] || die "$OCIMG is there already (another VM's?): pick another name, or remove it"
  BOOTARGS="keepsyms=1" CSR=""
  if [ $VENERA = 1 ]; then
    BOOTARGS="keepsyms=1 amfi_get_out_of_my_way=1"
    if [ $WEBGL = 1 ]; then CSR=030A0000; else CSR=03020000; fi   # 0xA03 / 0x203, little-endian
  fi
fi

echo; echo "  The VM's Mac identity (its model, serial, board serial and Wi-Fi MAC address):"
[ -n "$MACSERIAL" ] && echo "    g  generate one for this VM: a serial and board serial made for the model and for each other, and a"
[ -n "$MACSERIAL" ] && echo "       Wi-Fi MAC address. Unique, but registered with no one: macOS is fine, iCloud and iMessage may refuse it"
echo "    m  enter your Mac's, to sign into iCloud with it (from System Settings > General > About on that Mac)"
echo "    s  skip: OpenCore's shared sample identity (never sign into iCloud with it)"
SERIAL="" MLB="" ROM="" GENERATED=0
ask MODEL "Model identifier (one macOS Tahoe supports)" "${CUR_MODEL:-iMac20,1}"
ask IDWAY "Generate, your Mac's, or skip (g/m/s)" "$([ -n "$MACSERIAL" ] && [ $MODE != identity ] && echo g || echo m)"
case $IDWAY in
g | G)
  [ -n "$MACSERIAL" ] || die "no macserial beside this script (the host package's opencore/ folder): enter your Mac's"
  gen_identity
  echo "  generated: $MODEL, serial $SERIAL, board serial $MLB, Wi-Fi MAC $ROM"
  ;;
m | M)
  ask SERIAL "Serial number"
  SERIAL=${SERIAL^^}; [[ $SERIAL =~ ^[A-Z0-9]{10,12}$ ]] || die "that serial doesn't look like a Mac serial"
  # the serial names a model: the identity is only consistent when the VM claims to be that model
  SM=$(serial_model "$SERIAL")
  if [ -n "$SM" ] && [ "$SM" != "$MODEL" ]; then
    warn "that serial is for model $SM, not $MODEL"
    if no_yes "Make the VM's model $SM (macOS Tahoe must support it)?"; then MODEL=$SM; fi
  fi
  ask MLB "Board serial (MLB)"; MLB=${MLB^^}; [[ $MLB =~ ^[A-Z0-9]{13,17}$ ]] || die "that MLB doesn't look right (13-17 letters and digits)"
  ask ROM "Wi-Fi MAC address (aa:bb:cc:dd:ee:ff)"; ROM=${ROM,,}
  [[ $ROM =~ ^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$ ]] || die "that MAC address doesn't look right"
  ;;
*) [ $MODE = identity ] && die "no identity given: nothing changed" ;;
esac

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
  if [ -n "$BYO_DISK" ]; then echo "  - OpenCore $OCVER (Venera's own image, from this package), and your macOS disk $BYO_DISK as the VM's disk"
    echo "    (imported, at least $DISK GB; it must be an Intel (x86) macOS; Venera is made for macOS 26 Tahoe)"
  elif [ -n "$BYO_INST" ]; then echo "  - OpenCore $OCVER (Venera's own image, from this package), and your installer $BYO_INST to install from"
  else echo "  - OpenCore $OCVER (Venera's own image, from this package) and macOS Tahoe's recovery from Apple, into $ISO"; fi
  echo "  - VM $VMID '$NAME': $CORES cores${PCORES:+ on the performance cores ($PCORES)}, $MEM MB, $DISK GB on $STORAGE$([ $TRIM = on ] && echo ", TRIM on")"
  echo "    (the OpenCore$([ -n "$BYO_DISK" ] || echo " and $([ -n "$BYO_INST" ] && echo installer || echo recovery)") image$([ -n "$BYO_DISK" ] || echo s) imported as small disks there too)"
  echo "  - network: $BRIDGE${VLAN:+, VLAN $VLAN}; starts with the host"
  echo "  - SMC: QEMU applesmc with Apple's SMC key; CPU: the host's own; OpenCore with VeneraHide, $RES"
  if [ $VENERA = 1 ]; then
    echo "  - Venera: display virtio-gl with Venus, host-phys-bits-limit=40; in OpenCore SIP 0x$([ $WEBGL = 1 ] && echo A03 || echo 203)"
    echo "    and amfi_get_out_of_my_way=1$([ $WEBGL = 1 ] && echo " (authenticated root off, for Safari WebGL)")"
    if [ -n "$GPKG" ]; then echo "  - the Venera Tools CD with $(basename "$GPKG"), to open once macOS is installed"; fi
    [ $VIDEO = 1 ] && echo "  - hardware video: set up at Finish (the device waits for VeneraVideo.kext in macOS)"
  else
    echo "  - display: VMware SVGA (no Venera)"
  fi
  [ $AUDIO = 1 ] && echo "  - a USB sound device (plays in Proxmox's SPICE console)"
  echo "  - a guest agent port (virtio) for Venera's guest agent"
fi
if [ -n "$SERIAL" ]; then echo "  - Mac identity$([ $GENERATED = 1 ] && echo " (generated)"): $MODEL, serial ${SERIAL:0:4}..., MAC $ROM"
else echo "  - Mac identity: the sample one from OpenCore$([ $MODE = create ] && echo ", model $MODEL") (no iCloud until you add yours)"; fi
yes_no "Go ahead?" || die "nothing changed"

if [ $MODE = identity ]; then
  [[ $OCIMG == /dev/* ]] && lvchange -ay "$OCIMG"
  BK=/root/opencore-$NAME-$(date +%Y%m%d-%H%M%S).img; dd if="$OCIMG" of="$BK" bs=1M status=none
  apply_identity
  if [ $GENERATED = 1 ]; then echo "== Done (the previous OpenCore disk is saved as $BK). Start VM $VMID: it has its generated identity."
  else echo "== Done (the previous OpenCore disk is saved as $BK). Start VM $VMID, then sign into your Apple Account inside it."; fi
  exit 0
fi

# ---- a new VM ------------------------------------------------------------------------------------------------------
echo "== this host"
host_prep $NEED || die "the packages didn't install (apt-get install $(missing_pkgs $NEED))"
for n in "${NODES[@]}"; do echo "== node $n"; on_node "$n" "$(declare -f missing_pkgs host_prep); host_prep $VENUS_PKGS" || die "$n's packages didn't install (apt on $n)"; done

echo "== OpenCore image"
mkdir -p "$ISO"
cp "$OCSRC" "$OCIMG"; prepare_opencore

if [ -n "$BYO_INST" ]; then
  echo "== your installer: $BYO_INST"
  case ${BYO_INST,,} in
    *.dmg) REC=$ISO/$(basename "${BYO_INST%.*}").img
           [ -f "$REC" ] || { dmg2img "$BYO_INST" "$REC.part" >/dev/null && mv "$REC.part" "$REC"; } || die "dmg2img couldn't read $BYO_INST" ;;
    *) REC=$BYO_INST ;;
  esac
fi
[ -n "$BYO_DISK" ] || [ -n "$BYO_INST" ] || echo "== macOS Tahoe recovery, from Apple"
if [ -z "$BYO_DISK" ] && [ ! -f "$REC" ]; then
  W=$(mktemp -d); cd "$W"
  if [ -f "$HERE/macrecovery.py" ]; then cp "$HERE/macrecovery.py" .; else curl -fsL "$MACREC_URL" -o macrecovery.py; fi   # the package carries it
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
if [ $VENERA = 1 ]; then VGA=virtio-gl,clipboard=vnc; ARGS=$(screen_args "$(venera_args "$ARGS" $AUDIO)" "$RES")
elif [ $AUDIO = 1 ]; then ARGS="$ARGS -audiodev spice,id=vsnd -device usb-audio,audiodev=vsnd"; fi
qm create "$VMID" --name "$NAME" --ostype other --machine q35 --bios ovmf \
  --cores "$CORES" --sockets 1 ${PCORES:+--affinity "$PCORES"} --memory "$MEM" --balloon 0 \
  --vga $VGA --tablet 0 --agent enabled=1,type=virtio \
  --net0 "vmxnet3,bridge=$BRIDGE${VLAN:+,tag=$VLAN},firewall=0" \
  --efidisk0 "$STORAGE:1,efitype=4m,pre-enrolled-keys=0" \
  $([ -n "$BYO_DISK" ] || echo --virtio0 "$STORAGE:$DISK,cache=none$([ $TRIM = on ] && echo ,discard=on)") --onboot 1 \
  --description "macOS Tahoe, made by proxmox-macos-vm.sh${VER:+ (Venera $VER)}" >/dev/null
if [ -n "$BYO_DISK" ]; then
  echo "== importing the OpenCore image and your macOS disk"
  qm disk import "$VMID" "$OCIMG" "$STORAGE" --format raw >/dev/null
  qm disk import "$VMID" "$BYO_DISK" "$STORAGE" >/dev/null || die "Proxmox couldn't import $BYO_DISK (qm disk import)"
  OCDISK=$(qm config "$VMID" | sed -n 's/^unused0: //p'); MDISK=$(qm config "$VMID" | sed -n 's/^unused1: //p')
  [ -n "$OCDISK" ] && [ -n "$MDISK" ] || die "the imported disks didn't show up (qm config $VMID)"
  qm set "$VMID" --ide2 "$OCDISK,cache=unsafe" --virtio0 "$MDISK,cache=none$([ $TRIM = on ] && echo ,discard=on)" --boot order=ide2 --args "$ARGS" >/dev/null
  CUR=$(qm config "$VMID" | sed -n 's/^virtio0: .*size=\([0-9]*\)G.*/\1/p')
  [ -z "$CUR" ] || [ "$CUR" -ge "$DISK" ] || qm disk resize "$VMID" virtio0 "${DISK}G" >/dev/null
else
  echo "== importing the OpenCore and $([ -n "$BYO_INST" ] && echo installer || echo recovery) images as disks"
  qm disk import "$VMID" "$OCIMG" "$STORAGE" --format raw >/dev/null
  qm disk import "$VMID" "$REC" "$STORAGE" --format raw >/dev/null
  OCDISK=$(qm config "$VMID" | sed -n 's/^unused0: //p'); RECDISK=$(qm config "$VMID" | sed -n 's/^unused1: //p')
  [ -n "$OCDISK" ] && [ -n "$RECDISK" ] || die "the imported disks didn't show up (qm config $VMID)"
  qm set "$VMID" --ide2 "$OCDISK,cache=unsafe" --ide0 "$RECDISK,cache=unsafe" --boot order=ide2 --args "$ARGS" >/dev/null
fi
[ $VENERA = 1 ] && attach_venera_disk

if [ -n "$BYO_DISK" ]; then
  echo "== Done: VM $VMID ($NAME), on your macOS disk. Start it from the Proxmox web page and open its Console: OpenCore's"
  echo "   menu lists the disk's macOS (pick it if it isn't first). A disk from another hypervisor may want its old tools"
  echo "   (VMware Tools, Parallels Tools) removed in macOS. If the disk was made bigger, Disk Utility can grow its container."
else
echo "== Done: VM $VMID ($NAME). Start it from the Proxmox web page, open its Console, and install macOS Tahoe:"
echo "   at OpenCore's menu pick $([ -n "$BYO_INST" ] && echo "your installer (Install macOS ..., or macOS Base System)" || echo "the macOS Base System"); Disk Utility > View > Show All Devices > erase the VirtIO disk"
if [ $VENERA = 1 ] && [ -n "$TOOLS" ]; then   # the release's CD carries install-venera
  echo "   (APFS, GUID Partition Map) > back. Then either Reinstall macOS Tahoe, or, to have Venera from the first startup:"
  echo "   Utilities > Terminal, run \"/Volumes/Venera Tools/install-venera\" and pick the disk you erased (it installs macOS"
  echo "   with Venera added)."
else
  echo "   (APFS, GUID Partition Map) > back, Reinstall macOS Tahoe."
fi
echo "   It restarts a few times, and OpenCore follows it by itself (into the installer, then Macintosh HD). Without"
echo "   Venera, Setup Assistant can stop on its last screen with no graphics driver yet: if it hasn't moved in a few"
echo "   minutes, restart the VM (Reboot, or Stop and Start); the account is made, and macOS starts at the login window."
fi
echo "   After setup, in macOS: automatic updates off (Venera is tested on 26.7.3; a newer macOS may keep the software"
echo "   desktop); never sleep; set time automatically."
if [ $VENERA = 1 ]; then
  if [ -n "$GPKG" ]; then echo "   Then (unless install-venera put it in already) open Install Venera on the Venera Tools CD (on the desktop) and"
    echo "   restart when it says so; its Proxmox guest agent choice (on) gives Proxmox clean shutdowns and the VM's addresses."
  else echo "   Then copy Venera's guest package (Install Venera VERSION.pkg) into macOS, open it, and restart when it says so."; fi
  echo "   Then run this again and choose Finish$([ $VIDEO = 1 ] && echo ": it turns on hardware video (on every node you set up),") takes out the"
  echo "   installer disks and restarts the VM."
fi
[ -n "$SERIAL" ] || echo "   Do not sign into an Apple Account in it until you have run this script again with a Mac identity (choice 3)."
[ $GENERATED = 1 ] && echo "   Its Mac identity is generated: for iCloud and iMessage, your own Mac's is the safe one (this script, choice 3)."
echo "   Undo: qm destroy $VMID --purge; rm $OCIMG (and $REC, which the next VM can use; /etc/modprobe.d/kvm-macos.conf)"
