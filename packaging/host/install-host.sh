#!/bin/bash
# Venera's host half: hardware video decoding and encoding for macOS VMs on a Proxmox host with an Intel GPU. Run as root on the
# host, from the unpacked Venera-host-VERSION folder.
#
#   ./install-host.sh --vm VMID [--vm VMID...]   install (or update), and give each VM its video device
#   ./install-host.sh --remove-vm VMID           take one VM's video device out (the rest stays)
#   ./install-host.sh --uninstall                take everything out again, every VM's device first
#   ./install-host.sh --status                   what is installed and running
#   ./install-host.sh --check                    after a Proxmox update: the host's graphics and video stack against
#                                                the versions this release was tested on (TESTED), and how to go back
#   ./install-host.sh --hold | --unhold          keep those packages at their versions through updates (or stop)
#   ./install-host.sh --record                   print this host's versions in TESTED's form (for a release)
#   add --dry-run to see the steps without doing them
#
# What it changes (and --uninstall undoes):
#   - the packages intel-media-va-driver (Intel's VA-API driver) and libva-drm2, those not installed yet: the only
#     downloads, from the host's own apt sources. --uninstall removes only the ones this script installed.
#   - /opt/venera/video: venera-videod and the FFmpeg libraries it was built with (nothing else on the host uses them)
#   - /etc/systemd/system/venera-videod@.socket and @.service, one instance per VM (venera-videod@VMID): systemd holds
#     the socket from boot and starts the service when the VM connects. The service runs sandboxed (its own dynamic
#     user, the GPU's render node only, no network, read-only system); a restart keeps the VM's connection.
#   - /etc/apt/apt.conf.d/80venera, a hook (/opt/venera/apt-check) that warns before apt installs a newer version of
#     a package Venera was tested with (/opt/venera/TESTED: QEMU, virglrenderer, Mesa's Vulkan driver, VA-API's);
#     it only warns, apt always goes on
#   - each VM's `args:` line gains its video device:
#       -chardev socket,path=/run/venera-video-VMID.sock,id=vvideo -device ivshmem-doorbell,chardev=vvideo,vectors=1
#     (the VM's config is backed up to /opt/venera/backup first). Nothing else in the VM's config changes.
# A VM picks up a new device when QEMU starts again: shut it down and start it (or `qm reboot VMID`); a restart from
# inside the guest keeps the old QEMU. The guest's half is the Install Venera package's "Hardware video".
#
# Important: a VM with the device needs its socket (venera-videod@VMID.socket, enabled at boot) to start; QEMU waits
# for the service to answer. --remove-vm or --uninstall take the device out first.
# An older hand-made setup (venera-videod.service, /run/venera-video.sock in the VM's args) is replaced.
# In a cluster, run it on every node the VM may run on (HA can start it on any of them): on the node that holds the VM
# it also adds the device to the VM's config (which the cluster shares and moves with the VM); on the others it sets up
# only the socket and service, so the VM can start there. A VM with the device can't live-migrate (QEMU's ivshmem and
# Venus devices don't migrate): HA moves it by shutting it down and starting it on the other node.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=/opt/venera
UNIT=/etc/systemd/system/venera-videod@.service
SOCK=/etc/systemd/system/venera-videod@.socket
LEGACY_UNIT=/etc/systemd/system/venera-videod.service
APTHOOK=/etc/apt/apt.conf.d/80venera
LEGACY_ARGS="-chardev socket,path=/run/venera-video.sock,id=vvideo -device ivshmem-doorbell,chardev=vvideo,vectors=1"
STATE=$PREFIX/state
PKGS="intel-media-va-driver libva-drm2"
DRY=0
MODE=install
VMS=()

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
run() {
  say "  + $*"
  [ $DRY = 1 ] || "$@"
}
dev_args() { echo "-chardev socket,path=/run/venera-video-$1.sock,id=vvideo -device ivshmem-doorbell,chardev=vvideo,vectors=1"; }
# a VM is this node's when its config is in /etc/pve/qemu-server (this node's folder of /etc/pve/nodes); a VM of the
# cluster's other nodes is read from their folders, and changed only on its own node
vm_local() { [ -e "/etc/pve/qemu-server/$1.conf" ]; }
vm_conf() { # the config file of VM $1 on another node
  local f
  for f in /etc/pve/nodes/*/qemu-server/"$1".conf; do [ -e "$f" ] && { echo "$f"; return 0; }; done
  return 1
}
vm_node() { local f; f=$(vm_conf "$1") || return 1; f=${f#/etc/pve/nodes/}; echo "${f%%/*}"; }
vm_args() {
  local f
  if vm_local "$1"; then qm config "$1" 2>/dev/null | sed -n 's/^args: //p'
  elif f=$(vm_conf "$1"); then sed -n '/^\[/q; s/^args: //p' "$f"   # the current config, not a snapshot's
  fi
}
state_get() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -1; }
state_set() {
  [ $DRY = 1 ] && return
  mkdir -p "$PREFIX"
  { grep -v "^$1=" "$STATE" 2>/dev/null; echo "$1=$2"; } >"$STATE.new" && mv "$STATE.new" "$STATE"
}

while [ $# -gt 0 ]; do
  case $1 in
  --vm) [ -n "${2:-}" ] || die "--vm needs a VM id"; VMS+=("$2"); shift ;;
  --remove-vm) [ -n "${2:-}" ] || die "--remove-vm needs a VM id"; MODE=remove; VMS+=("$2"); shift ;;
  --uninstall) MODE=uninstall ;;
  --status) MODE=status ;;
  --check) MODE=check ;;
  --record) MODE=record ;;
  --hold) MODE=hold ;;
  --unhold) MODE=unhold ;;
  --dry-run) DRY=1 ;;
  -h | --help) sed -n '2,30p' "$0"; exit 0 ;;
  *) die "unknown option $1 (--help)" ;;
  esac
  shift
done
for v in "${VMS[@]}"; do
  case $v in '' | *[!0-9]*) die "a VM id is a number: $v" ;; esac
done

# ---- the host's stack: what Venera depends on and doesn't control (Proxmox's packages) ------------------------------
# Venus needs QEMU's virtio-gpu, virglrenderer and its render server, and Mesa's Vulkan driver for the host's GPU to
# speak the protocol the guest's driver speaks; hardware video needs Intel's VA-API driver. A Proxmox update can
# change any of them. TESTED (beside this script) has the versions this release was tested with.
STACK="pve-qemu-kvm libvirglrenderer1 virgl-server mesa-vulkan-drivers libgl1 libegl1 intel-media-va-driver libva-drm2"
HOLD="pve-qemu-kvm libvirglrenderer1 virgl-server mesa-vulkan-drivers"
pkg_ver() { dpkg-query -W -f '${Version}' "$1" 2>/dev/null || true; }
stack_record() {
  local p
  echo "# the host stack this release was tested on (install-host.sh --record on the test host, $(date +%F))"
  for p in $STACK; do echo "$p $(pkg_ver "$p")"; done
  echo "kernel $(uname -r)"
}
stack_check() {   # prints what differs from TESTED, checks the pieces; returns 1 when something is wrong
  local p want have bad=0 diff=0 rs gpu
  say "== the host's graphics and video stack"
  for p in $STACK kernel; do
    if [ "$p" = kernel ]; then have=$(uname -r); else have=$(pkg_ver "$p"); fi
    want=$(awk -v p="$p" '$1 == p {print $2}' "$HERE/TESTED" 2>/dev/null)
    if [ -z "$have" ]; then
      case $p in intel-media-va-driver|libva-drm2) say "  $p: not installed (only hardware video needs it)" ;;
        *) say "  $p: NOT INSTALLED"; bad=1 ;; esac
    elif [ -z "$want" ] || [ "$want" = "$have" ]; then say "  $p: $have${want:+ (as tested)}"
    else say "  $p: $have (tested: $want)"; diff=1; fi
  done
  rs=$(dpkg -L virgl-server 2>/dev/null | grep -m1 'virgl_render_server$' || true)
  if [ -z "$rs" ]; then say "  Venus's render server: missing (virgl-server)"; bad=1
  elif ldd "$rs" | grep -q "not found"; then say "  Venus's render server: libraries missing: $(ldd "$rs" | grep "not found" | tr -s ' ' | tr '\n' ';')"; bad=1
  else say "  Venus's render server: $rs, its libraries all found"; fi
  gpu=$(ls /dev/dri/renderD* 2>/dev/null | head -1)
  if [ -z "$gpu" ]; then say "  GPU render node: none (/dev/dri/renderD*)"; bad=1; else say "  GPU render node: $gpu"; fi
  ls /usr/share/vulkan/icd.d/*.json >/dev/null 2>&1 && say "  Vulkan drivers: $(ls /usr/share/vulkan/icd.d/ | sed 's/_icd.*//' | tr '\n' ' ')" ||
    { say "  Vulkan drivers: none (mesa-vulkan-drivers)"; bad=1; }
  if [ -x "$HERE/bin/vaprofiles" ] && [ -n "$gpu" ]; then
    local va; va=$(LIBVA_MESSAGING_LEVEL=0 LD_LIBRARY_PATH=$HERE/lib "$HERE/bin/vaprofiles" "$gpu" 2>/dev/null)
    say "  VA-API (hardware video): $(head -1 <<<"$va"): $(grep -c "^  decode" <<<"$va") decode and $(grep -c "^  encode" <<<"$va") encode profiles"
  fi
  if [ $diff = 1 ]; then
    say ""
    say "  Something changed since this release was tested. Start a macOS VM and look: if its desktop or video broke, go"
    say "  back to the tested versions (Proxmox keeps older ones in its repository), then start the VMs again:"
    for p in $STACK; do
      want=$(awk -v p="$p" '$1 == p {print $2}' "$HERE/TESTED" 2>/dev/null); have=$(pkg_ver "$p")
      [ -n "$want" ] && [ -n "$have" ] && [ "$want" != "$have" ] && say "    apt install $p=$want"
    done
    say "  and keep them there until a Venera release is tested on the new ones: ./install-host.sh --hold"
  fi
  [ $bad = 0 ]
}

[ "$(id -u)" = 0 ] || die "run as root"
command -v qm >/dev/null && command -v pveversion >/dev/null || die "this is for a Proxmox VE host (no qm / pveversion)"

# ---- each VM's device ----------------------------------------------------------------------------------------------
# check_vm ID: 0 when the VM can take our device (or has it), else dies saying why; nothing changes
check_vm() {
  local id=$1 cur want
  if vm_local "$id"; then qm config "$id" >/dev/null 2>&1 || die "no VM $id on this host"
  else vm_conf "$id" >/dev/null || die "no VM $id on this host or the cluster's other nodes"
  fi
  cur=$(vm_args "$id")
  want=$(dev_args "$id")
  case " $cur " in
  *" $want "* | *" $LEGACY_ARGS "*) ;;
  *ivshmem-doorbell*chardev=vvideo* | *"id=vvideo"*)
    die "VM $id has another video device line in its args (\"$cur\"): take it out by hand first" ;;
  esac
}
add_vm() {
  local id=$1 cur want new
  check_vm "$id"
  cur=$(vm_args "$id")
  want=$(dev_args "$id")
  if ! vm_local "$id"; then   # its config is changed on its own node; this node only needs the socket
    case " $cur " in
    *" $want "*) say "VM $id (on $(vm_node "$id")): has its video device; this host's socket is ready for when it runs here" ;;
    *) say "VM $id is on $(vm_node "$id"): its device goes in there (./install-host.sh --vm $id on that node); this host's socket is ready for when it runs here" ;;
    esac
    return
  fi
  case " $cur " in
  *" $want "*) say "VM $id: has its video device already"; return ;;
  esac
  case " $cur " in
  *" $LEGACY_ARGS "*)
    say "VM $id: replacing the older hand-made video device line"
    cur=$(printf '%s' " $cur " | sed "s# $LEGACY_ARGS # #; s/^ *//; s/ *$//")
    ;;
  esac
  new="${cur:+$cur }$want"
  run mkdir -p "$PREFIX/backup"
  run cp "/etc/pve/qemu-server/$id.conf" "$PREFIX/backup/$id.conf.$(date +%Y%m%d-%H%M%S)"
  run qm set "$id" --args "$new"
  say "VM $id: video device added; shut the VM down and start it again to use it"
}
remove_vm() {
  local id=$1 cur want new
  cur=$(vm_args "$id")
  want=$(dev_args "$id")
  if ! vm_local "$id" && vm_conf "$id" >/dev/null; then   # its config is changed on its own node, not here
    case " $cur " in
    *" $want "*) warn "VM $id is on $(vm_node "$id") and keeps its device: it can't start on this host now (take the device out there: ./install-host.sh --remove-vm $id)" ;;
    *) say "VM $id (on $(vm_node "$id")): this host's socket for it off" ;;
    esac
  else
    case " $cur " in
    *" $want "*)
      new=$(printf '%s' " $cur " | sed "s# $want # #; s/^ *//; s/ *$//")
      run mkdir -p "$PREFIX/backup"
      run cp "/etc/pve/qemu-server/$id.conf" "$PREFIX/backup/$id.conf.$(date +%Y%m%d-%H%M%S)"
      if [ -n "$new" ]; then run qm set "$id" --args "$new"; else run qm set "$id" --delete args; fi
      say "VM $id: video device taken out (its QEMU keeps it until the VM stops)"
      ;;
    *) say "VM $id: no video device of ours" ;;
    esac
  fi
  if systemctl list-unit-files 'venera-videod@.service' >/dev/null 2>&1; then
    run systemctl disable --now "venera-videod@$id.socket" "venera-videod@$id.service"
    run systemctl clean --what=fdstore --what=state "venera-videod@$id.service"
  fi
}
# the VMs whose args carry our device
our_vms() {
  local f id
  for f in /etc/pve/qemu-server/*.conf; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .conf)
    grep -q "^args:.*path=/run/venera-video-$id.sock,id=vvideo" "$f" && echo "$id"
  done
}

# the VMs of the cluster's other nodes that this host has a socket for
other_nodes_vms() {
  local u id
  for u in $(systemctl list-units --all --plain --no-legend 'venera-videod@*.socket' 2>/dev/null | awk '{print $1}'); do
    case $u in venera-videod@*.socket) ;; *) continue ;; esac
    id=${u#venera-videod@}; id=${id%.socket}
    vm_local "$id" || echo "$id"
  done
}

case $MODE in
check)
  stack_check && say "" && say "OK: everything Venera needs is there." || { say ""; say "Something Venera needs is missing (above)."; exit 1; }
  exit 0 ;;
record) stack_record; exit 0 ;;
hold | unhold)
  say "apt-mark $MODE $HOLD"
  [ $DRY = 1 ] || apt-mark "$MODE" $HOLD
  [ $DRY = 0 ] && [ $MODE = hold ] && say "Held: Proxmox updates leave them as they are (their security fixes too) until ./install-host.sh --unhold."
  exit 0 ;;
status)
  say "Venera host: $(cat "$PREFIX/VERSION" 2>/dev/null || echo 'not installed')"
  for p in $PKGS; do
    say "  $p: $(dpkg-query -W -f='${Version}' $p 2>/dev/null || echo 'not installed')$(case " $(state_get apt_installed) " in *" $p "*) echo ' (installed by Venera)' ;; esac)"
  done
  say "  render node: $(ls /dev/dri/renderD* 2>/dev/null | tr '\n' ' ')"
  for id in $(our_vms); do
    say "  VM $id: device in its args; socket $(systemctl is-active "venera-videod@$id.socket" 2>/dev/null), service $(systemctl is-active "venera-videod@$id.service" 2>/dev/null); VM $(qm status "$id" 2>/dev/null | cut -d' ' -f2)"
  done
  for id in $(other_nodes_vms); do
    say "  VM $id (on $(vm_node "$id")): socket $(systemctl is-active "venera-videod@$id.socket" 2>/dev/null), ready for when it runs here"
  done
  exit 0
  ;;
remove)
  for id in "${VMS[@]}"; do remove_vm "$id"; done
  exit 0
  ;;
uninstall)
  for id in $(our_vms); do remove_vm "$id"; done
  for id in $(other_nodes_vms); do remove_vm "$id"; done
  for u in $(systemctl list-units --all --plain --no-legend 'venera-videod@*' 2>/dev/null | awk '{print $1}'); do
    run systemctl disable --now "$u"
  done
  for f in "$UNIT" "$SOCK" "$APTHOOK"; do
    [ -e "$f" ] && run rm -f "$f"
  done
  run systemctl daemon-reload
  mine=$(state_get apt_installed)
  if [ -n "$mine" ]; then
    say "removing what this script installed: $mine"
    run apt-get remove -y $mine
  fi
  for p in $PKGS; do
    case " $mine " in *" $p "*) ;; *) say "$p: left installed (it was there before Venera)" ;; esac
  done
  run rm -rf "$PREFIX/video" "$PREFIX/VERSION" "$PREFIX/state" "$PREFIX/TESTED" "$PREFIX/apt-check" "$PREFIX/install-host.sh"
  run rm -rf /var/lib/private/venera-video /var/lib/venera-video
  say "Venera's host half removed. VM config backups stay in $PREFIX/backup (rm -rf $PREFIX when no longer wanted)."
  say "A VM that is running keeps its device until it stops."
  exit 0
  ;;
esac

# ---- install -------------------------------------------------------------------------------------------------------
[ ${#VMS[@]} -gt 0 ] || die "name the VM(s): --vm VMID (--help)"
for id in "${VMS[@]}"; do check_vm "$id"; done   # every VM checked before anything changes
for f in bin/venera-videod lib venera-videod@.service venera-videod@.socket VERSION TESTED apt-check; do
  [ -e "$HERE/$f" ] || die "$f is missing: run this from the unpacked Venera-host folder"
done
[ "$(uname -m)" = x86_64 ] || die "x86_64 hosts only"
ls /dev/dri/renderD* >/dev/null 2>&1 || die "no GPU render node (/dev/dri/renderD*): the host needs its Intel GPU's i915/xe driver"
grep -qi intel /sys/class/drm/renderD*/device/vendor 2>/dev/null ||
  grep -q 0x8086 /sys/class/drm/renderD*/device/vendor 2>/dev/null ||
  warn "no Intel render node found: VA-API decoding needs an Intel GPU (iHD driver)"
say "host: $(pveversion 2>/dev/null | head -1)"

# 1. Intel's VA-API driver and libva's DRM half
missing=
for p in $PKGS; do
  dpkg-query -W -f='${Status}' $p 2>/dev/null | grep -q 'install ok installed' || missing="$missing $p"
done
if [ -z "$missing" ]; then
  say "packages: $PKGS installed already"
else
  say "packages: installing$missing from the host's apt sources"
  run apt-get install -y $missing || die "apt-get couldn't install$missing (run apt-get update first?)"
  state_set apt_installed "$(echo "$(state_get apt_installed)$missing" | xargs)"
fi

# 2. the program
run mkdir -p "$PREFIX/video"
run rm -rf "$PREFIX/video/bin" "$PREFIX/video/lib"
run cp -R "$HERE/bin" "$HERE/lib" "$PREFIX/video/"
run chown -R root:root "$PREFIX/video"
[ $DRY = 1 ] || cp "$HERE/VERSION" "$PREFIX/VERSION"
if [ $DRY = 0 ]; then
  prof=$("$PREFIX/video/bin/vaprofiles" 2>&1)
  if echo "$prof" | grep -q "decode: VAProfileH264"; then
    enc=$(echo "$prof" | grep -E 'encode.*(VAProfileH264High|VAProfileHEVCMain)$' | sed -E 's/.*VAProfile(H264High|HEVCMain)$/\1/' |
      sed 's/H264High/H.264/; s/HEVCMain/HEVC/' | sort -u | tr '\n' ' ' | sed 's/ $//')
    say "VA-API: $(echo "$prof" | grep -m1 '^VA-API' | sed 's/^VA-API //'); decodes $(echo "$prof" | grep -c 'decode:') profiles; encodes ${enc:-nothing (the guest encodes in software)}"
  else
    warn "VA-API can't decode H.264 on this GPU (vaprofiles: $(echo "$prof" | head -2 | tr '\n' ' '))"
  fi
fi

# the apt hook: a warning before a Proxmox update replaces a package this release was tested with (and this script,
# with TESTED, for its --check afterwards)
run install -m 755 "$HERE/apt-check" "$HERE/install-host.sh" "$PREFIX/"
run install -m 644 "$HERE/TESTED" "$PREFIX/"
if [ $DRY = 0 ]; then
  printf '%s\n' "// Venera (install-host.sh): warns before apt replaces a package Venera was tested with; --uninstall removes it" \
    'DPkg::Pre-Install-Pkgs { "/opt/venera/apt-check"; };' >"$APTHOOK"
else say "  + write $APTHOOK"; fi

# 3. the socket and service, one instance per VM
run cp "$HERE/venera-videod@.service" "$UNIT"
run cp "$HERE/venera-videod@.socket" "$SOCK"
legacy=0
if [ -e "$LEGACY_UNIT" ]; then   # the older hand-made setup: its VM connects to it until it restarts
  say "replacing the older hand-made venera-videod.service"
  run systemctl disable --now venera-videod.service
  run mkdir -p "$PREFIX/backup"
  run mv "$LEGACY_UNIT" "$PREFIX/backup/venera-videod.service.$(date +%Y%m%d-%H%M%S)"
  legacy=1
fi
run systemctl daemon-reload
for id in "${VMS[@]}"; do
  if systemctl is-active --quiet "venera-videod@$id.service"; then
    # an update: the new program carries on with the VM's connection (systemd keeps it across the restart)
    run systemctl restart "venera-videod@$id.service"
  fi
  run systemctl enable --now "venera-videod@$id.socket"
  [ $DRY = 1 ] || systemctl is-active --quiet "venera-videod@$id.socket" ||
    die "venera-videod@$id.socket didn't start: journalctl -u venera-videod@$id.socket"
done

# 4. each VM's device
for id in "${VMS[@]}"; do add_vm "$id"; done

say ""
say "Venera host $(cat "$HERE/VERSION") installed for VM(s) ${VMS[*]}."
say "In each VM: install Venera with Hardware video chosen, then shut the VM down and start it again."
[ $legacy = 1 ] && say "A VM that ran on the older setup has no hardware video until it is shut down and started again."
say "Updating later keeps running VMs' connections: systemd holds them while the service restarts."
