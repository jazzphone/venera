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
#                             (an AMD host, experimental: an Intel model, Haswell, in its place)
#   TRIM only on thin storage - Disk Utility's erase TRIMs the whole disk, which shared iSCSI storage clears 2 MB at a
#                             time; on thin storage (local-lvm, ZFS, Ceph, a file) TRIM gives freed space back
#   the guest agent         - Venera's (a Customize choice, on by default) on the virtio agent port: clean shutdowns,
#                             the VM's addresses in Proxmox, and Finish and Upgrade work through it
#   virtio-gl + Venus       - the GPU the guest's Metal runs on (vga: virtio-gl, -global virtio-vga-gl.venus/blob/hostmem)
#   host-phys-bits-limit=40 - without it the firmware can put the GPU's memory window above 2^44, which macOS's kernel
#                             can't address: the driver finds no GPU memory
#   a USB sound device      - Safari won't start streaming video (YouTube) without an audio output; macOS has no driver
#                             for QEMU's HDA but drives USB audio itself
#   the balloon device      - statistics only (VeneraBalloon.kext; never inflates, its minimum is the VM's memory):
#                             without it Proxmox shows the QEMU process's memory, which macOS's caches fill
#   SIP 0x203, AMFI off     - set in OpenCore before macOS is installed, so Venera installs in one pass (otherwise its
#                             installer changes them first and finishes after a restart)
#   the video device last   - added at Finish: without VeneraVideo.kext, macOS hangs on it and finds no OpenCore disk
set -euo pipefail
die() { echo "STOP: $*"; exit 1; }
# --answers FILE: the questions answered from FILE (KEY=value lines; vm/answers.example has every key), for a VM made
# with nobody at the keyboard. A question FILE doesn't answer takes its default; "Go ahead?" is yes.
declare -A ANS=(); ANSWERS=""
load_answers() {
  local line k v
  [ -r "$1" ] || die "can't read the answers file $1"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
    [[ $v == \#* ]] && v=""                                   # an empty value, then a comment
    [[ $v == \"* || $v == \'* ]] || v=${v%%[[:space:]]#*}   # a comment after an unquoted value
    v=${v%"${v##*[![:space:]]}"}
    if [[ $v =~ ^\"(.*)\"$ ]] || [[ $v =~ ^\'(.*)\'$ ]]; then v=${BASH_REMATCH[1]}; fi
    ANS[$k]=$v
  done <"$1"
  ANSWERS=$1
}
ask() {   # ask VAR QUESTION [DEFAULT]: VAR is also the answers file's key
  local v
  if [ -n "$ANSWERS" ]; then
    if [ -n "${ANS[$1]+x}" ]; then v=${ANS[$1]}; else v=${3:-}; fi
    echo "  $2: $v"
  else read -r -p "  $2${3:+ [$3]}: " v; v=${v:-${3:-}}; fi
  printf -v "$1" '%s' "$v"
}
# yes_no / no_yes QUESTION [KEY]: No / Yes unless answered. KEY is its key in an answers file (y or n); NODE:name
# reads NODES there (the nodes to set up, or "all").
answer() {   # answer DEFAULT QUESTION [KEY]: prints y or n
  local d=$1 q=$2 k=${3:-} v
  if [ -z "$ANSWERS" ]; then
    read -r -p "  $q [$([ "$d" = y ] && echo Y/n || echo y/N)]: " v
    case $v in [Yy]*) echo y ;; [Nn]*) echo n ;; *) echo "$d" ;; esac
    return 0
  fi
  if [[ $k == NODE:* ]]; then
    if [ -z "${ANS[NODES]+x}" ]; then v=$d
    elif [ "${ANS[NODES]}" = all ] || [[ " ${ANS[NODES]} " == *" ${k#NODE:} "* ]]; then v=y; else v=n; fi
  elif [ "$q" = "Go ahead?" ]; then v=y
  elif [ -n "$k" ] && [ -n "${ANS[$k]+x}" ]; then case ${ANS[$k]} in [Yy1]* | on | true) v=y ;; *) v=n ;; esac
  else v=$d; fi
  echo "  $q $v" >&2
  echo "$v"
}
yes_no() { [ "$(answer n "$1" "${2:-}")" = y ]; }
no_yes() { [ "$(answer y "$1" "${2:-}")" = y ]; }
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
    *host-phys-bits=on*) echo "  ! the VM's -cpu takes the host's address width: add host-phys-bits-limit=40 to it by hand" >&2 ;;
    *) ;;   # a named CPU model (an AMD host's): QEMU gives it 40 address bits already
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
mine = ("VirtioGPU.kext", "VeneraVideo.kext", "VeneraConsole.kext", "VeneraBalloon.kext")
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
  for k in VirtioGPU VeneraVideo VeneraConsole VeneraBalloon; do [ -d "$MNT/EFI/OC/Kexts/$k.kext" ] && cp -R "$MNT/EFI/OC/Kexts/$k.kext" "$w/old/"; done
  echo "   the old EFI folder's kexts: $old"
  rm -rf "$MNT/EFI"
  cp -R "$w/src/EFI" "$MNT/"
  for k in "$w"/old/*.kext; do [ -d "$k" ] && cp -R "$k" "$MNT/EFI/OC/Kexts/"; done
  oc_transplant "$w/old/config.plist" "$MNT/EFI/OC/config.plist"
  oc_umount
  umount "$w/src"; rm -rf "$w"
}

# A full SMC (0.1.9): Venera's OpenCore image carries acidanthera's Lilu and VirtualSMC. QEMU's applesmc has only the
# keys macOS needs to boot and can't list them; PerfPowerServices asks for every key by index at its start and spun a
# core for good. A VM on Venera's older image gets the two kexts at its Upgrade.
oc_kexts_running() {   # the running VM's OpenCore disk: its kexts, one per line (read-only; nothing if it can't tell)
  local vol img loop m start i; vol=$(disk_of ide2); [ -n "$vol" ] || return 0
  img=$(pvesm path "$vol" 2>/dev/null) && [ -e "$img" ] || return 0
  loop=$(losetup -frP --show "$img" 2>/dev/null) || return 0
  m=$(mktemp -d)
  for i in $(seq 1 30); do [ -b "${loop}p1" ] && break; udevadm settle 2>/dev/null || sleep 0.1; done
  start=$(partx -g -o START -n 1 "$loop" 2>/dev/null || true)
  if { [ -b "${loop}p1" ] && mount -o ro "${loop}p1" "$m" 2>/dev/null; } ||
     { [ -n "$start" ] && mount -o ro,offset=$((start * 512)) "$loop" "$m" 2>/dev/null; }; then
    ls "$m/EFI/OC/Kexts" 2>/dev/null
    umount "$m"
  fi
  rmdir "$m"; losetup -d "$loop"
}
# VirtualSMC steps aside when Apple's AppleSMC is already attached to another SMC device, and QEMU's applesmc is one
# (an ACPI device AppleSMC matches first): with VirtualSMC in OpenCore, QEMU's goes. VirtualSMC carries the OSK keys
# macOS decrypts its own apps with, which QEMU's device was there for.
no_applesmc() { sed -E 's/ ?-device isa-applesmc(,[^ "]*("[^"]*")?[^ ]*)?//; s/^ +//' <<<"$1"; }   # args without QEMU's SMC
smc_plan() {   # the running VM: SMC_KEXTS=1 when its OpenCore (Venera's) needs Lilu and VirtualSMC from this package,
               # SMC_ARGS=1 when QEMU's applesmc then goes from its args
  SMC_KEXTS=0 SMC_ARGS=0
  local k a; k=$(oc_kexts_running); a=$(qm config "$VMID" | sed -n 's/^args: //p')
  [ -n "$OCSRC" ] && grep -qx VeneraHide.kext <<<"$k" && ! grep -qx VirtualSMC.kext <<<"$k" && SMC_KEXTS=1
  if [[ $a == *isa-applesmc* ]] && { [ $SMC_KEXTS = 1 ] || grep -qx VirtualSMC.kext <<<"$k"; }; then SMC_ARGS=1; fi
}
smc_args_off() {   # the VM stopped: QEMU's applesmc out of its args
  local a; a=$(qm config "$VMID" | sed -n 's/^args: //p')
  [[ $a == *isa-applesmc* ]] || return 0
  qm set "$VMID" --args "$(no_applesmc "$a")" >/dev/null && echo "   QEMU's applesmc out of the VM's args (VirtualSMC is its SMC now)"
}
oc_smc_merge() {   # SRC-config DST-config: SRC's Lilu and VirtualSMC entries first in DST's Kernel/Add (once)
  python3 - "$1" "$2" <<'PY'
import plistlib, sys
src = plistlib.load(open(sys.argv[1], "rb")); dst = plistlib.load(open(sys.argv[2], "rb"))
names = ("Lilu.kext", "VirtualSMC.kext")
ours = [k for k in src["Kernel"]["Add"] if k.get("BundlePath") in names]
dst["Kernel"]["Add"] = ours + [k for k in dst["Kernel"]["Add"] if k.get("BundlePath") not in names]
plistlib.dump(dst, open(sys.argv[2], "wb"))
print("   OpenCore: " + ", ".join(k["BundlePath"] for k in dst["Kernel"]["Add"]))
PY
}
oc_add_smc() {   # the VM stopped, OCIMG its OpenCore disk: Lilu and VirtualSMC from this package's image, first in Kernel/Add
  local w; w=$(mktemp -d)
  mount -o ro,loop,offset=$((2048 * 512)) "$OCSRC" "$w"   # its EFI partition starts at sector 2048 (build.sh)
  [ -d "$w/EFI/OC/Kexts/VirtualSMC.kext" ] || { umount "$w"; rmdir "$w"; warn "this package's OpenCore image has no VirtualSMC"; return 1; }
  oc_mount
  rm -rf "$MNT/EFI/OC/Kexts/Lilu.kext" "$MNT/EFI/OC/Kexts/VirtualSMC.kext"
  cp -R "$w/EFI/OC/Kexts/Lilu.kext" "$w/EFI/OC/Kexts/VirtualSMC.kext" "$MNT/EFI/OC/Kexts/"
  oc_smc_merge "$w/EFI/OC/config.plist" "$MNT/EFI/OC/config.plist"
  oc_umount
  umount "$w"; rmdir "$w"
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
# 1280x800 when not given); VirtioGPUFramebuffer offers it among its modes, up to 3840x2400 (Retina: 2560x1600 is
# offered as "looks like 1280x800" at twice the pixels). OpenCore's resolution is
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
  [ "$2" != 1 ] || { [ "${BASH_REMATCH[1]}" -le 3840 ] && [ "${BASH_REMATCH[2]}" -le 2400 ]; } ||
    die "Venera's display goes up to 3840x2400"
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
    echo "    1  Screen size: $S$([ $ven = 1 ] && echo "   (macOS's desktop, up to 3840x2400, Retina from 2560x1440; Recovery and OpenCore's menu too)")"
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
# Proxmox's memory figure for the VM comes from its balloon device's statistics (VeneraBalloon.kext reports them; it
# never inflates). The balloon's minimum is the VM's memory, so Proxmox never asks for any back; QEMU adds the device
# only when the VM starts.
vm_memory() { local m; m=$(qm config "$VMID" | sed -n 's/^memory: //p'); m=${m#current=}; m=${m%%,*}; echo "${m:-2048}"; }
no_balloon() { [ "$(qm config "$VMID" | sed -n 's/^balloon: //p')" = 0 ]; }   # the device off (older Venera VMs)
balloon_on() { qm set "$VMID" --balloon "$(vm_memory)" >/dev/null && echo "   balloon device on (minimum $(vm_memory) MB: Proxmox's memory figure from macOS)"; }
backup_conf() { mkdir -p /root/macos-vm-backup; cp "/etc/pve/qemu-server/$VMID.conf" "/root/macos-vm-backup/$VMID.conf.$(date +%Y%m%d-%H%M%S)"; }
ha_service() { ha-manager config 2>/dev/null | grep -qx "vm:$VMID"; }   # the VM is one of HA's services
stop_vm() {   # shuts the VM down (from macOS, as the Apple menu does) and waits; HA's VMs through HA
  qm status "$VMID" | grep -q stopped && return 0
  echo "== shutting VM $VMID down"
  # HA's own state to stopped first: HA starts a VM that shut down behind its back again at once, and a change made
  # then goes in as pending while the VM comes back as it was (VM 107's agent port, 2026-11-20). qm start asks HA to
  # start it again.
  if ha_service; then ha-manager set "vm:$VMID" --state stopped >/dev/null 2>&1 || true; fi
  # through the guest agent when it answers: macOS at Setup Assistant (and while it starts up) doesn't act on the
  # power button Proxmox's shutdown presses, and the wait ran its full 10 minutes (2026-11-20)
  if qm guest cmd "$VMID" ping >/dev/null 2>&1; then
    qm guest exec "$VMID" --timeout 10 -- /sbin/shutdown -h now >/dev/null 2>&1 || true
    local w; for w in $(seq 1 24); do qm status "$VMID" 2>/dev/null | grep -q stopped && return 0; sleep 5; done
  fi
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

tools_cd_slot() {   # the slot holding a Venera Tools CD (ide1 as the script puts it, or another a person chose)
  qm config "$VMID" | sed -n 's/^\(ide[0-3]\|sata[0-5]\|scsi[0-9]*\): \([^,]*Venera-Tools-[^,]*\.iso\),.*/\1/p' | head -1
}
tools_cd_old() {   # the VM's Venera Tools CD when it is another release's, else nothing
  local slot cur; slot=$(tools_cd_slot); [ -n "$slot" ] || return 0
  cur=$(disk_of "$slot")
  [[ $cur != *"/Venera-Tools-${VER:-guest}.iso" ]] && echo "$cur"
}
two_tablets() {   # the args' usb-tablet and Proxmox's own (tablet: 1, the default) both: an older VM's config
  local c; c=$(qm config "$VMID")
  grep -q -- '-device usb-tablet' <<<"$c" && ! grep -q '^tablet: 0' <<<"$c" && echo yes
}
swap_tools_cd() {   # this release's Venera Tools CD in place of an older one (a running VM's CD changes at once); the
                    # old ISO removed when no VM's config (snapshots included) names it any more
  local cur st new path slot; cur=$(tools_cd_old); [ -n "$cur" ] || return 0
  slot=$(tools_cd_slot); st=${cur%%:*}; new="Venera-Tools-${VER:-guest}.iso"
  path=$(pvesm path "$st:iso/$new" 2>/dev/null) || return 0
  [ -f "$path" ] || venera_disk "$path"
  qm set "$VMID" --"$slot" "$st:iso/$new,media=cdrom" >/dev/null || { warn "the Venera Tools CD couldn't be changed: $cur stays"; return 0; }
  echo "   $slot: the Venera Tools CD is now $st:iso/$new"
  # the whole volume id (storage:iso/name) as a disk's first field: another storage's ISO of the same name isn't it
  if ! sed -n 's/^[a-z]*[0-9]*: \([^,]*\).*/\1/p' /etc/pve/nodes/*/qemu-server/*.conf 2>/dev/null | grep -qxF "$cur"; then
    pvesm free "$cur" >/dev/null 2>&1 && echo "   $cur removed (no VM uses it)"
  fi
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
  local VIDEO=0 drops=() HASDEV=0 RESTART=0 VIRTIO_AGENT=0 CLIP=0 BALLOON=0
  case " $(qm config "$VMID" | sed -n 's/^args: //p') " in *"/run/venera-video-$VMID.sock"*) HASDEV=1 ;; esac
  gpu_scan
  if [ "$GPU_KIND" = intel ] && [ -n "$HOSTKIT" ]; then
    if [ -z "$st" ] || [[ $st == *"video choice"* ]]; then
      no_yes "Hardware video (the host's Intel GPU decodes and encodes for the VM)?" "VIDEO" && VIDEO=1
    else   # without VeneraVideo.kext the device hangs macOS's boot
      warn "Venera in macOS was installed without its video choice: install it again with it before turning this on"
      yes_no "Hardware video anyway?" "VIDEO" && VIDEO=1
    fi
  elif [ "$GPU_KIND" = intel ]; then
    echo "  (hardware video: run this from the unpacked Venera-host folder; it carries the host's half)"
  fi
  if [ $VIDEO = 1 ]; then for n in $(vm_other_nodes); do no_yes "Hardware video on $n too (HA may start the VM there)?" "NODE:$n" && nodes+=("$n"); done; fi
  local keepcd="" cdslot; cdslot=$(tools_cd_slot)
  # the recovery: a disk in ide0 (not an ISO)
  case $(disk_of ide0) in "" | *:iso/*) ;; *) yes_no "Take out ide0 ($(disk_of ide0): the macOS recovery, deleted)?" "TAKE_OUT" && drops+=(ide0) ;; esac
  if [ -n "$cdslot" ]; then
    # the Venera Tools CD stays (Extras, install-venera, the package): macOS shows it on the desktop. On a node's own
    # storage in a cluster it would keep HA from starting the VM elsewhere, so that one is asked about.
    local cdst; cdst=$(disk_of "$cdslot"); cdst=${cdst%%:*}
    if [ -n "$(vm_other_nodes 2>/dev/null)" ] && ! storage_shared "$cdst"; then
      yes_no "Take out the Venera Tools CD (on $cdst, this node's own storage: HA can't start the VM elsewhere with it in)?" "TAKE_OUT" && drops+=("$cdslot")
    else
      keepcd="$cdslot, $(disk_of "$cdslot")"
    fi
  fi
  if [ -n "$(disk_of ide1)" ] && [ "$cdslot" != ide1 ]; then
    yes_no "Take out ide1 ($(disk_of ide1))?" "TAKE_OUT" && drops+=(ide1)
  fi
  # Venera's agent answers on either port; the virtio one is ten times faster than the ISA serial port
  if [[ $st == *"guest agent"* ]] && ! qm config "$VMID" | grep -q '^agent:.*type=virtio'; then VIRTIO_AGENT=1; fi
  # Proxmox's memory figure: the balloon device for VeneraBalloon.kext, which comes with Venera's agent
  if [[ $st == *"guest agent"* ]] && no_balloon; then BALLOON=1; fi
  # the Proxmox console's clipboard (Venera's clipboard agent on the other end), where live migration keeps working
  if [[ $st == *"guest agent"* ]] && ! qm config "$VMID" | grep -q '^vga:.*clipboard=vnc'; then
    if clipboard_ok; then CLIP=1; else echo "  (the console's clipboard: not on a VM pinned below machine 10.1, which then couldn't live-migrate)"; fi
  fi
  { [ $VIDEO = 1 ] && [ $HASDEV = 0 ]; } || [ ${#drops[@]} -gt 0 ] || [ $VIRTIO_AGENT = 1 ] || [ $CLIP = 1 ] || [ $BALLOON = 1 ] && RESTART=1
  echo; echo "== The plan"
  [ $VIDEO = 1 ] && echo "  - hardware video: install-host.sh --vm $VMID here${nodes[*]:+ and on ${nodes[*]}}$([ $HASDEV = 1 ] && echo " (the VM has its device: this updates the service)")"
  [ ${#drops[@]} -gt 0 ] && echo "  - take out ${drops[*]} (the recovery disk is deleted; the Venera Tools ISO stays in its storage)"
  [ -n "$keepcd" ] && echo "  - the Venera Tools CD stays in ($keepcd): its Extras folder and the package, on macOS's desktop"
  [ $VIRTIO_AGENT = 1 ] && echo "  - the guest agent on its virtio port (faster than the ISA serial port)"
  [ $CLIP = 1 ] && echo "  - the Proxmox console's clipboard shared with macOS (display: clipboard=vnc)"
  [ $BALLOON = 1 ] && echo "  - the balloon device on, minimum $(vm_memory) MB (never inflates): Proxmox shows macOS's own memory use"
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
  [ $BALLOON = 0 ] || balloon_on
  [ $RESTART = 0 ] || { echo "== starting VM $VMID"; qm start "$VMID"; }
  echo "== Done. In macOS, the Venera app (Applications) shows what runs. The config before: /root/macos-vm-backup/."
}

ready_vm() {   # an existing macOS VM (stopped): the host's packages, the display, the args, the Venera Tools CD
  local cur new AUDIO=1 nodes=() n
  qm status "$VMID" | grep -q stopped || die "shut VM $VMID down first, then run this again"
  STORAGE=$(qm config "$VMID" | sed -n 's/^virtio0: \([^:]*\):.*/\1/p'); [ -n "$STORAGE" ] || STORAGE=local-lvm
  cur=$(qm config "$VMID" | sed -n 's/^args: //p')
  case " $cur " in *usb-audio*) ;; *) no_yes "A sound device (USB audio; YouTube needs one)?" "AUDIO" || AUDIO=0 ;; esac
  new=$(venera_args "$cur" $AUDIO)
  for n in $(vm_other_nodes); do no_yes "Set up $n too (HA may start the VM there)?" "NODE:$n" && nodes+=("$n"); done
  echo; echo "== The plan"
  echo "  - here${nodes[*]:+ and on ${nodes[*]}}: install $(missing_pkgs $VENUS_PKGS genisoimage)(those missing), KVM ignore_msrs on"
  echo "  - VM $VMID: display virtio-gl (was $(qm config "$VMID" | sed -n 's/^vga: //p'))"
  [ "$new" = "$cur" ] || echo "  - its args gain: $(comm -13 <(tr ' ' '\n' <<<"$cur" | sort -u) <(tr ' ' '\n' <<<"$new" | sort -u) | tr '\n' ' ')"
  no_balloon && echo "  - the balloon device on, minimum $(vm_memory) MB (never inflates): with Venera, Proxmox shows macOS's own memory use"
  [ -n "$GPKG" ] && echo "  - the Venera Tools CD in ide1 with $(basename "$GPKG")"
  echo "  (the config is backed up to /root/macos-vm-backup first)"
  yes_no "Go ahead?" || die "nothing changed"
  echo "== the host"; host_prep $VENUS_PKGS genisoimage || die "the packages didn't install (apt)"
  for n in "${nodes[@]}"; do echo "== $n"; on_node "$n" "$(declare -f missing_pkgs host_prep); host_prep $VENUS_PKGS" || die "$n's packages didn't install (apt on $n)"; done
  backup_conf
  qm set "$VMID" --vga "virtio-gl$(clipboard_ok && echo ,clipboard=vnc)" --args "$new" >/dev/null; echo "   display virtio-gl, args updated"
  ! no_balloon || balloon_on
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

# ---- macOS installed with nobody at the keyboard -------------------------------------------------------------------
# The VM boots macOS's recovery (OpenCore starts it by itself); this waits until its window is up (the screen no
# longer the black of the boot, and still), opens Terminal from the menu bar with the keyboard (Control-F2, Utilities,
# Terminal: no mouse, any screen size), and types install-venera's auto command (Venera Tools CD): it erases the empty
# disk and starts macOS's installer with Venera. The disk's first writes say the command ran; if none come, it tries
# again. Then macOS installs (it restarts a few times, OpenCore follows it), Venera installs at its first startup, and
# the guest agent answers at Setup Assistant: then Finish.
KEYS_PL='use PVE::QemuServer::Monitor qw(mon_cmd); use Time::HiRes qw(usleep);
my $vm = shift;
my %sym = (" " => "spc", "-" => "minus", "=" => "equal", "/" => "slash", "." => "dot", "," => "comma", ";" => "semicolon",
  "\x27" => "apostrophe", "\\" => "backslash", "\x60" => "grave_accent", "[" => "bracket_left", "]" => "bracket_right");
my %sh = ("_" => "minus", "+" => "equal", "?" => "slash", ">" => "dot", "<" => "comma", ":" => "semicolon", "\"" => "apostrophe",
  "|" => "backslash", "~" => "grave_accent", "{" => "bracket_left", "}" => "bracket_right", "!" => "1", "@" => "2", "#" => "3",
  "\$" => "4", "%" => "5", "^" => "6", "&" => "7", "*" => "8", "(" => "9", ")" => "0");
sub press { mon_cmd($vm, "send-key", keys => [map { { type => "qcode", data => $_ } } @_], "hold-time" => 40); usleep(60000); }
for my $it (@ARGV) {
  if ($it =~ /^sleep:([\d.]+)$/) { usleep($1 * 1e6); next; }
  if ($it =~ /^text:(.*)$/s) {
    for my $c (split //, $1) {
      if ($c =~ /^[a-z0-9]$/) { press($c) } elsif ($c =~ /^[A-Z]$/) { press("shift", lc $c) }
      elsif (exists $sym{$c}) { press($sym{$c}) } elsif (exists $sh{$c}) { press("shift", $sh{$c}) }
      else { die "no key for $c\n" }
    }
    next;
  }
  press(split /-(?=.)/, $it);
}'
vm_keys() { perl -e "$KEYS_PL" "$VMID" "$@"; }   # vm_keys ctrl-f2 right "text:..." ret sleep:1
disk_writes() {   # the VM's disk (virtio0): writes so far, and bytes written
  perl -MPVE::QemuServer::Monitor=mon_cmd -e 'for (@{mon_cmd($ARGV[0], "query-blockstats")}) {
    print "$_->{stats}{wr_operations} $_->{stats}{wr_bytes}\n" if ($_->{qdev} // "") =~ m{/virtio0/} }' "$VMID" 2>/dev/null | head -1
}
screen_now() {   # the screen: "MEAN CHANGED" (mean brightness 0-255; % of sampled pixels changed since the last call)
  local f=/run/venera-screen-$VMID
  perl -MPVE::QemuServer::Monitor=mon_cmd -e 'mon_cmd($ARGV[0], "screendump", filename => $ARGV[1], format => "ppm")' \
    "$VMID" "$f.new.ppm" 2>/dev/null || { echo "0 100"; return 0; }
  python3 -I - "$f.new.ppm" "$f.ppm" <<'PY'
import os, sys
def px(p):
    d = open(p, "rb").read(); parts = d.split(b"\n", 3)   # QEMU writes P6, W H, 255, then the pixels
    return parts[3][::48]                                 # every 16th pixel's first byte (gray enough)
a = px(sys.argv[1])
mean = sum(a) / max(len(a), 1)
b = px(sys.argv[2]) if os.path.exists(sys.argv[2]) else b""
changed = 100.0 if len(b) != len(a) else 100.0 * sum(1 for x, y in zip(a, b) if abs(x - y) > 8) / max(len(a), 1)
print("%d %.1f" % (mean, changed))
PY
  mv "$f.new.ppm" "$f.ppm"
}
recovery_up() {   # waits (up to 8 minutes) for the recovery's window: not the boot's black, and still for 15 s
  local i still=0 m c
  rm -f "/run/venera-screen-$VMID.ppm"
  for i in $(seq 1 96); do
    sleep 5; read -r m c <<<"$(screen_now)"
    if [ "${m:-0}" -ge 12 ] && [ "${c%.*}" -lt 1 ]; then still=$((still + 1)); else still=0; fi
    [ $still -ge 3 ] && [ $i -ge 8 ] && return 0
  done
  return 1
}
auto_install() {   # the VM (running or not) has its recovery and the Venera Tools CD, and an empty disk
  local cmd try w0 w i t0 mins last=-1
  cmd="\"/Volumes/Venera Tools/install-venera\" auto --agree-to-license --name \"${MACOS_VOLUME:-Macintosh HD}\""
  [ "${IVIDEO:-1}" = 1 ] || cmd="$cmd --no-video"
  [ "${IAPP:-1}" = 1 ] || cmd="$cmd --no-app"
  [ "${IWEBGL:-0}" = 1 ] && cmd="$cmd --webgl"
  echo; echo "== Installing macOS Tahoe with Venera onto VM $VMID, with nobody at the keyboard"
  echo "   (about an hour: macOS downloads several GB from Apple; watch it in the VM's Console if you like, without"
  echo "   typing there until it reaches Setup Assistant)"
  qm status "$VMID" | grep -q running || qm start "$VMID" >/dev/null
  for try in 1 2 3; do
    recovery_up || die "the recovery's window didn't come up in 8 minutes: open the VM's Console and do it by hand (vm/README.md)"
    w0=$(disk_writes); w0=${w0%% *}
    echo "   the recovery is up: Terminal, then install-venera auto (try $try)"
    vm_keys esc sleep:0.5 ctrl-f2 sleep:0.7 right right right right sleep:0.5 down sleep:0.7 text:Terminal sleep:0.5 ret sleep:5
    vm_keys "text:$cmd" ret
    for i in $(seq 1 24); do
      sleep 5; w=$(disk_writes); w=${w%% *}
      [ "${w:-0}" -gt "${w0:-0}" ] && break
    done
    [ "${w:-0}" -gt "${w0:-0}" ] && break
    [ $try = 3 ] && die "install-venera didn't start (no writes to the disk): open the VM's Console and run it by hand"
    echo "   no writes to the disk yet: trying again"
  done
  echo "   it started: the disk is erased and macOS's installer is on its way"
  t0=$(date +%s)
  while :; do   # the guest agent comes with Venera, at macOS's first startup
    # Venera's version file, and macOS started again after Venera's install (it writes the file first, then restarts
    # macOS: Finish began during that restart, found no Venera and asked a booting macOS to shut down, 2026-11-20)
    if qm guest cmd "$VMID" ping >/dev/null 2>&1 &&
       [ "$(guest 'V="/Library/Application Support/Venera"; [ -s "$V/VERSION" ] && [ -f "$V/install.log" ] && [ "$(sysctl -n kern.boottime | sed -E "s/^[^0-9]*([0-9]+).*/\1/")" -gt "$(stat -f %m "$V/install.log")" ] && echo up')" = up ]; then break; fi
    mins=$((($(date +%s) - t0) / 60))
    if [ $((mins / 5)) != $last ]; then
      last=$((mins / 5)); w=$(disk_writes)
      echo "   $mins min: $(awk '{printf "%.1f GB", $2 / 1e9}' <<<"${w:-0 0}") written to the disk"
    fi
    [ $mins -lt 180 ] || die "macOS hasn't come up with Venera's guest agent in 3 hours: look at the VM's Console"
    sleep 20
  done
  echo "   macOS is installed, with Venera $(guest 'cat "/Library/Application Support/Venera/VERSION"') and its guest agent"
}
license_ok() {   # Apple's macOS license, agreed to by whoever runs this: MACOS_LICENSE=agree, or typed
  local a=""
  echo "  macOS installs under Apple's license (macOS Tahoe's: https://www.apple.com/legal/sla/)."
  if [ -n "$ANSWERS" ]; then a=${ANS[MACOS_LICENSE]-}; echo "  macOS's license: ${a:-not agreed to (MACOS_LICENSE=agree)}"
  else read -r -p "  Type agree to agree to it: " a; fi
  [ "$a" = agree ]
}
finish_auto() {   # Finish right after an unattended install, with its own answers: video as chosen, installer disks out
  ANSWERS=${ANSWERS:-auto}
  ANS[VIDEO]=$IVIDEO; [ -n "${ANS[TAKE_OUT]+x}" ] || ANS[TAKE_OUT]=y
  if [ "${ANS[FINISH]:-y}" = n ]; then echo "== Done (FINISH=n): run this again and choose Finish when you're ready."; return 0; fi
  finish_vm
  echo "   macOS is at Setup Assistant on the host's GPU: open the VM's Console to set it up."
}
install_choice() {   # choice 7: an existing VM with its recovery, the Venera Tools CD and an empty disk
  [ -n "$(disk_of ide0)" ] || die "VM $VMID has no recovery disk (ide0) to install from"
  [[ $(disk_of ide1) == *Venera-Tools* ]] || die "VM $VMID has no Venera Tools CD in ide1 (Ready for Venera, choice 2, adds it)"
  qm config "$VMID" | grep -q '^agent:.*enabled=1' || qm config "$VMID" | grep -q '^agent: 1' ||
    die "VM $VMID's guest agent option is off (Options > QEMU Guest Agent): the install is followed through it"
  gpu_scan
  IVIDEO=0; [ "$GPU_KIND" = intel ] && no_yes "Hardware video (the host's Intel GPU decodes and encodes for the VM)?" "VIDEO" && IVIDEO=1
  IAPP=1; no_yes "The Venera app (tells you when something needs you)?" "APP" || IAPP=0
  IWEBGL=0; yes_no "Safari WebGL (SIP's authenticated root off too)?" "WEBGL" && IWEBGL=1
  ask MACOS_VOLUME "The macOS volume's name" "Macintosh HD"
  license_ok || die "nothing changed (without agreeing to Apple's license, install macOS by hand: vm/README.md)"
  echo; echo "== The plan"
  echo "  - start VM $VMID into its recovery, open Terminal there with the keyboard, and run install-venera auto: it erases"
  echo "    the empty disk (never one with macOS on it) and installs macOS Tahoe with Venera; about an hour"
  echo "  - then Finish: $([ $IVIDEO = 1 ] && echo "hardware video, ")the installer disks out, a restart to Setup Assistant"
  yes_no "Go ahead?" || die "nothing changed"
  auto_install
  finish_auto
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
  smc_plan
  # Venera's agent answers on either port; the ISA serial one is ten times slower and drops big requests (the package
  # through the agent timed out on VM 107): virtio, as Finish and new VMs have it, which QEMU adds only at a start
  VIRTIO_AGENT=0
  if [ $agent = 1 ] && ! qm config "$VMID" | grep -q '^agent:.*type=virtio'; then VIRTIO_AGENT=1; fi
  # Proxmox's memory figure (after 0.1.15): VeneraBalloon.kext comes with the agent and reports through the balloon device,
  # which Venera's VMs were made without; QEMU adds it at a start
  BALLOON=0
  if [ $agent = 1 ] && no_balloon; then BALLOON=1; fi
  echo "  macOS has Venera $cur: hardware video $([ $video = 1 ] && echo on || echo off), the Venera app $([ $app = 1 ] && echo on || echo off), the guest agent $([ $agent = 1 ] && echo on || echo off), Safari WebGL (the system-volume copy) $([ $webgl = 1 ] && echo on || echo off)"
  if [ $HASDEV = 1 ]; then
    [ -n "$HOSTKIT" ] || die "VM $VMID has hardware video but Venera's host half isn't beside this script"
    for n in $(vm_other_nodes); do no_yes "The host half on $n too (HA may start the VM there)?" "NODE:$n" && nodes+=("$n"); done
  fi
  echo; echo "== The plan"
  [ $HASDEV = 1 ] && echo "  - the host half: install-host.sh --vm $VMID here${nodes[*]:+ and on ${nodes[*]}} (running VMs keep their video connections)"
  if [ $SMC_KEXTS = 1 ] || [ $SMC_ARGS = 1 ] || [ $VIRTIO_AGENT = 1 ] || [ $BALLOON = 1 ]; then
    echo "  - in macOS: $(basename "$GPKG") through the guest agent, with the same choices"
    [ $SMC_KEXTS = 1 ] && echo "  - OpenCore: acidanthera's Lilu and VirtualSMC added, the OpenCore disk saved to /root first"
    if [ $SMC_KEXTS = 1 ] || [ $SMC_ARGS = 1 ]; then
      echo "  - the VM's SMC: VirtualSMC in place of QEMU's applesmc (with QEMU's alone, macOS's power logger can spin a CPU"
      echo "    core for good)"
    fi
    [ $VIRTIO_AGENT = 1 ] && echo "  - the guest agent on its virtio port (the ISA serial port is ten times slower and drops big requests)"
    [ $BALLOON = 1 ] && echo "  - the balloon device on, minimum $(vm_memory) MB (never inflates): Proxmox shows macOS's own memory use"
    echo "    so the restart is a shut-down and a start$(ha_service && echo " (through HA: it may start the VM on another node)")"
  else
    echo "  - in macOS: $(basename "$GPKG") through the guest agent, with the same choices, then a restart"
  fi
  echo "    (an older guest agent that can't take it: from a USB disk, while someone is logged in with the screen unlocked)"
  [ -z "$user" ] || echo "    ($user is logged in: the restart closes their apps, and anything unsaved is lost)"
  [ -n "$(tools_cd_old)" ] && echo "  - the Venera Tools CD in $(tools_cd_slot): this release's in place of $(tools_cd_old)"
  [ -n "$(two_tablets)" ] && echo "  - Proxmox's tablet off: the args' own is the VM's mouse (two, and the console's mouse can stop)"
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
  # the result through a file: the package starts its guest agent in place of the running one once it has finished,
  # and the installer's answer can go with the old agent (VM 109, 0.1.11: the Upgrade stopped there, macOS installed)
  local res=/private/var/tmp/venera-install.out n
  guest_rc 900 "/usr/sbin/installer -pkg '$mnt' -target / -applyChoiceChangesXML /private/var/tmp/venera-choices.xml >$res 2>&1; echo rc=\$? >>$res; rm -f /private/var/tmp/venera-choices.xml" >/dev/null
  out=""; for n in $(seq 1 24); do
    out=$(guest "cat $res 2>/dev/null"); grep -q '^rc=' <<<"$out" && break; sleep 5
  done
  guest "rm -f $res" >/dev/null
  sed 's/^/   /' <<<"$out" | grep -v '^   rc=' || true
  if [ $via = usb ]; then guest "diskutil eject '$(dirname "$mnt")' >/dev/null 2>&1" >/dev/null; sleep 2; usb_disk del; rm -f "$img"
  else guest "rm -f '$pkg'" >/dev/null; fi
  grep -qx 'rc=0' <<<"$out" || die "the install failed: its log is /Library/Application Support/Venera/install.log in macOS; nothing restarted"
  swap_tools_cd
  if [ -n "$(two_tablets)" ]; then   # taken out of the running VM, no restart needed
    qm set "$VMID" --tablet 0 >/dev/null && echo "   Proxmox's tablet off (the args' usb-tablet stays the mouse)"
  fi
}
usb_upgrade_disk() {   # the guest package on a USB disk in the running VM, mounted by macOS: sets img and mnt
  mkdir -p /root/venera; img=/root/venera/venera-upgrade-$VMID.iso
  # made from the package being installed, not the kit's Tools CD: a kit whose package was replaced (a fix, a build)
  # put the CD's older package on VM 107 (2026-11-20)
  if command -v genisoimage >/dev/null; then TOOLS="" venera_disk "$img"; else venera_disk "$img"; fi
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
  if [ "${SMC_KEXTS:-0}" = 1 ] || [ "${SMC_ARGS:-0}" = 1 ] || [ "${VIRTIO_AGENT:-0}" = 1 ] || [ "${BALLOON:-0}" = 1 ]; then
    stop_vm
    local smc_ok=1
    if [ "${SMC_KEXTS:-0}" = 1 ]; then
      OCVOL=$(disk_of ide2); OCIMG=$(pvesm path "$OCVOL")
      [[ $OCIMG == /dev/* ]] && lvchange -ay "$OCIMG"
      BK=/root/opencore-$NAME-$(date +%Y%m%d-%H%M%S).img; dd if="$OCIMG" of="$BK" bs=1M status=none
      echo "== OpenCore: Lilu and VirtualSMC (the old disk saved as $BK)"
      oc_add_smc || { smc_ok=0; warn "OpenCore wasn't changed (Venera's OpenCore, choice 5, brings them too): QEMU's applesmc stays"; }
    fi
    if [ "${SMC_KEXTS:-0}" = 1 ] || [ "${SMC_ARGS:-0}" = 1 ]; then [ $smc_ok = 0 ] || smc_args_off; fi
    if [ "${VIRTIO_AGENT:-0}" = 1 ]; then
      qm set "$VMID" --agent enabled=1,type=virtio >/dev/null && echo "   guest agent port: virtio"
    fi
    [ "${BALLOON:-0}" = 0 ] || balloon_on
    echo "== starting VM $VMID"
    qm start "$VMID" >/dev/null
    sleep 30
    local n; for n in $(seq 1 60); do qm guest cmd "$VMID" ping >/dev/null 2>&1 && break; sleep 5; done
    upgrade_status
    return
  fi
  echo "== restarting macOS"
  # the installer can restart the guest agent just then, and the request goes nowhere: by macOS's boot time, a restart
  # that didn't happen is asked for again
  local b0 b try
  b0=$(guest 'sysctl -n kern.boottime | cut -d, -f1')
  for try in 1 2 3; do
    qm guest exec "$VMID" --timeout 10 -- /sbin/shutdown -r now >/dev/null 2>&1 || true
    sleep 30
    for n in $(seq 1 60); do qm guest cmd "$VMID" ping >/dev/null 2>&1 && break; sleep 5; done   # (qm agent ping misses)
    b=$(guest 'sysctl -n kern.boottime | cut -d, -f1')
    [ -n "$b" ] && [ "$b" != "$b0" ] && break
    if [ $try = 3 ]; then warn "macOS didn't restart: restart it yourself (Apple menu > Restart) to finish the upgrade"
    else echo "   macOS hasn't restarted yet: asking again"; fi
  done
  upgrade_status
}
upgrade_status() {   # what runs in macOS after the upgrade's restart
  sleep 20
  st=$(guest 'V="/Library/Application Support/Venera"; echo "Venera $(cat "$V/VERSION")"; kextstat 2>/dev/null | grep -o "VeneraVideo ([0-9.]*)"; kextstat 2>/dev/null | grep -o "VirtualSMC ([0-9.]*)"; ioreg -rc VeneraBalloon -d1 -w0 2>/dev/null | sed -n "s/.*\"VeneraBalloonState\" = \"\(.*\)\"/memory figure for Proxmox: \1/p"; ioreg -rc VirtioGPUAccel -d1 2>/dev/null | sed -n "s/.*\"VirtioGPUArmState\" = \"\(.*\)\"/desktop: \1/p"')
  if [ -n "$st" ]; then sed 's/^/   /' <<<"$st"; else warn "macOS's guest agent hasn't answered since the restart: check the VM's console"; fi
  echo "== Done. In macOS, the Venera app (Applications) shows what runs."
}

# ---- the questions -------------------------------------------------------------------------------------------------
[ -z "${MACOS_VM_TEST:-}" ] || return 0   # vm/test.sh sources the functions above
while [ $# -gt 0 ]; do
  case $1 in
    --answers | -a) load_answers "${2:?--answers needs a file}"; shift 2 ;;
    -h | --help) echo "usage: $0 [--answers FILE]   (vm/README.md; vm/answers.example has the keys)"; exit 0 ;;
    *) die "unknown option $1 (--answers FILE)" ;;
  esac
done
[ "$(id -u)" = 0 ] || die "run as root on the Proxmox host"
command -v qm >/dev/null && command -v pvesm >/dev/null || die "this is for a Proxmox VE host (no qm / pvesm)"
# the VM's CPU: the host's own on an Intel host (an Intel Mac's); on an AMD host (EXPERIMENTAL, untested), an Intel
# model KVM presents instead (Haswell, as macOS VMs on AMD Proxmox hosts commonly use: no kernel patches in OpenCore),
# slower than the host's own, and with the host's AVX-512 and newer instructions hidden
CPU_ARG="-cpu host,vendor=GenuineIntel,+invtsc,+hypervisor,kvm=on,vmware-cpuid-freq=on" CPU_SAYS="the host's own"
if ! grep -q -m1 GenuineIntel /proc/cpuinfo; then
  grep -q -m1 AuthenticAMD /proc/cpuinfo || die "this makes macOS VMs on Intel CPUs (and, experimentally, AMD ones); this host's CPU is neither"
  warn "an AMD CPU: EXPERIMENTAL and UNTESTED (nobody has tried Venera on an AMD host yet). The VM gets an Intel CPU"
  warn "model (Haswell, presented by KVM) instead of the host's own: slower, and an app that needs newer instructions may"
  warn "not start. Please report what happens: https://github.com/jazzphone/venera/issues"
  yes_no "Go on with an AMD CPU (experimental, untested)?" "AMD" || die "nothing changed"
  CPU_ARG="-cpu Haswell-noTSX,vendor=GenuineIntel,+invtsc,+hypervisor,kvm=on,vmware-cpuid-freq=on,+pcid,+ssse3,+sse4.2,+popcnt,+avx,+avx2,+aes,+fma,+bmi1,+bmi2,+xsave,+xsaveopt,check"
  CPU_SAYS="an Intel model (Haswell) on this AMD host: EXPERIMENTAL"
fi
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
  echo "    7  Install macOS: onto the VM's empty disk, with Venera, by itself (then Finish)"
  ask WHAT "Which" "1"
  case $WHAT in
    1) finish_vm; exit 0 ;;
    2) host_versions; [ "$GPU_KIND" != none ] || die "no GPU the host can render on: Venera needs one"; ready_vm; exit 0 ;;
    3) ;;
    4) upgrade_vm; upgrade_restart; exit 0 ;;
    7) install_choice; exit 0 ;;
    5 | 6) ;;
    *) die "nothing changed" ;;
  esac
  if ! qm status "$VMID" | grep -q stopped; then
    yes_no "VM $VMID is running: shut it down now (from macOS, as the Apple menu does)?" "SHUTDOWN" ||
      die "shut VM $VMID down first (Proxmox's Shutdown, or Apple menu > Shut Down), then run this again"
    stop_vm
  fi
  OCVOL=$(disk_of ide2); [ -n "$OCVOL" ] || die "VM $VMID has no OpenCore disk on ide2"
  OCIMG=$(pvesm path "$OCVOL"); MODE=identity
  if [ "$WHAT" = 6 ]; then
    startup_settings
    if [ $DO_ID = 0 ]; then
      no_yes "Start VM $VMID now?" "START" && qm start "$VMID" && echo "== VM $VMID is starting."
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
    [[ $(qm config "$VMID" | sed -n 's/^args: //p') == *isa-applesmc* ]] &&
      echo "  - QEMU's applesmc out of the VM's args: the image's VirtualSMC is its SMC"
    yes_no "Go ahead?" || die "nothing changed"
    [[ $OCIMG == /dev/* ]] && lvchange -ay "$OCIMG"
    BK=/root/opencore-$NAME-$(date +%Y%m%d-%H%M%S).img; dd if="$OCIMG" of="$BK" bs=1M status=none
    update_opencore
    smc_args_off
    echo "== Done (the previous OpenCore disk is saved as $BK; dd it back to undo, and put QEMU's applesmc back in the"
    echo "   VM's args). Start VM $VMID."; exit 0
  fi
else
  MODE=create
  host_versions
  VENERA=0 VIDEO=0 WEBGL=0 AUDIO=1 NODES=()
  if [ "$GPU_KIND" != none ]; then no_yes "Set it up for Venera (Metal and OpenGL on the host's GPU)?" "VENERA" && VENERA=1; fi
  if [ $VENERA = 1 ]; then
    [ "$GPU_KIND" = intel ] && no_yes "Hardware video (the host's Intel GPU decodes H.264, HEVC and VP9 and encodes H.264 and HEVC)?" "VIDEO" && VIDEO=1
    yes_no "Safari WebGL (SIP's authenticated root off too, so the driver can go on the system volume)?" "WEBGL" && WEBGL=1
  fi
  no_yes "A sound device (USB audio over SPICE; YouTube needs one)?" "AUDIO" || AUDIO=0
  echo; echo "  VM storage (its disks):"; pvesm status --content images | sed 's/^/    /'
  ask STORAGE "Storage for the VM's disks" "local-lvm"
  pvesm status --content images | awk 'NR>1{print $1}' | grep -qx "$STORAGE" || die "$STORAGE can't hold VM disks"
  TRIM=off
  if storage_thin "$STORAGE"; then
    no_yes "TRIM: give the space macOS frees back to $STORAGE (it's thin storage)?" "TRIM" && TRIM=on
  else echo "  ($STORAGE is $(pvesm status | awk -v s="$STORAGE" '$1 == s {print $2}'): no TRIM, it can't take space back)"; fi
  if [ -n "$(other_nodes)" ]; then
    if storage_shared "$STORAGE"; then
      for n in $(other_nodes); do no_yes "Set up node $n too (HA may start the VM there)?" "NODE:$n" && NODES+=("$n"); done
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
  ask RES "Screen size$([ $VENERA = 1 ] && echo " (up to 3840x2400; 2560x1600 for Retina)")" "1280x800"
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
  INSTALL=0
  if [ $VENERA = 1 ] && [ -z "$BYO_DISK" ]; then
    if yes_no "Install macOS with Venera now, by itself (about an hour, nobody at the keyboard)?" "INSTALL"; then
      IVIDEO=$VIDEO IWEBGL=$WEBGL IAPP=1
      no_yes "The Venera app (tells you when something needs you)?" "APP" || IAPP=0
      ask MACOS_VOLUME "The macOS volume's name" "Macintosh HD"
      license_ok || die "nothing changed (without agreeing to Apple's license, leave the install out: INSTALL=n)"
      INSTALL=1
    fi
  fi
  [ -n "$OCSRC" ] || die "Venera's OpenCore image isn't beside this script (the host package's opencore/ folder)"
  OCIMG=$ISO/OpenCore-$NAME.img REC=$ISO/Tahoe-recovery.img
  OC_LEFT=0
  if [ -f "$OCIMG" ]; then   # a VM by this name had one: replaced only when no VM (a snapshot included) names it now
    grep -qsF "OpenCore-$NAME.img" /etc/pve/nodes/*/qemu-server/*.conf &&
      die "$OCIMG is there already, and a VM uses it: pick another name"
    OC_LEFT=1
  fi
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
    if no_yes "Make the VM's model $SM (macOS Tahoe must support it)?" "MODEL_FROM_SERIAL"; then MODEL=$SM; fi
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
  [ "${OC_LEFT:-0}" = 1 ] && echo "    (OpenCore-$NAME.img there is left from a VM since removed: replaced)"
  echo "  - VM $VMID '$NAME': $CORES cores${PCORES:+ on the performance cores ($PCORES)}, $MEM MB, $DISK GB on $STORAGE$([ $TRIM = on ] && echo ", TRIM on")"
  echo "    (the OpenCore$([ -n "$BYO_DISK" ] || echo " and $([ -n "$BYO_INST" ] && echo installer || echo recovery)") image$([ -n "$BYO_DISK" ] || echo s) imported as small disks there too)"
  echo "  - network: $BRIDGE${VLAN:+, VLAN $VLAN}; starts with the host"
  echo "  - SMC: VirtualSMC (in OpenCore); CPU: $CPU_SAYS; OpenCore with Lilu, VirtualSMC and VeneraHide, $RES"
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
  [ $INSTALL = 1 ] && echo "  - then macOS Tahoe with Venera, installed by itself (the recovery's Terminal, typed through the VM's keyboard), and Finish"
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
ARGS="-smbios type=2 -device qemu-xhci -device usb-kbd -device usb-tablet -global nec-usb-xhci.msi=off -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off $CPU_ARG"   # the SMC: VirtualSMC, in OpenCore
VGA=vmware
if [ $VENERA = 1 ]; then VGA=virtio-gl,clipboard=vnc; ARGS=$(screen_args "$(venera_args "$ARGS" $AUDIO)" "$RES")
elif [ $AUDIO = 1 ]; then ARGS="$ARGS -audiodev spice,id=vsnd -device usb-audio,audiodev=vsnd"; fi
qm create "$VMID" --name "$NAME" --ostype other --machine q35 --bios ovmf \
  --cores "$CORES" --sockets 1 ${PCORES:+--affinity "$PCORES"} --memory "$MEM" --balloon "$([ $VENERA = 1 ] && echo "$MEM" || echo 0)" \
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
if [ $INSTALL = 1 ]; then
  [ -n "$TOOLS" ] || die "no Venera Tools CD was attached (it carries install-venera): install macOS by hand, below"
  auto_install
  finish_auto
  exit 0
fi

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
