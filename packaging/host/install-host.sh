#!/bin/bash
# Venera's host half: hardware video decoding for macOS VMs on a Proxmox host with an Intel GPU. Run as root on the
# host, from the unpacked Venera-host-VERSION folder.
#
#   ./install-host.sh --vm VMID [--vm VMID...]   install (or update), and give each VM its video device
#   ./install-host.sh --remove-vm VMID           take one VM's video device out (the rest stays)
#   ./install-host.sh --uninstall                take everything out again, every VM's device first
#   ./install-host.sh --status                   what is installed and running
#   add --dry-run to see the steps without doing them
#
# What it changes (and --uninstall undoes):
#   - the packages intel-media-va-driver (Intel's VA-API driver) and libva-drm2, those not installed yet: the only
#     downloads, from the host's own apt sources. --uninstall removes only the ones this script installed.
#   - /opt/venera/video: venera-videod and the FFmpeg libraries it was built with (nothing else on the host uses them)
#   - /etc/systemd/system/venera-videod@.socket and @.service, one instance per VM (venera-videod@VMID): systemd holds
#     the socket from boot and starts the service when the VM connects. The service runs sandboxed (its own dynamic
#     user, the GPU's render node only, no network, read-only system); a restart keeps the VM's connection.
#   - each VM's `args:` line gains its video device:
#       -chardev socket,path=/run/venera-video-VMID.sock,id=vvideo -device ivshmem-doorbell,chardev=vvideo,vectors=1
#     (the VM's config is backed up to /opt/venera/backup first). Nothing else in the VM's config changes.
# A VM picks up a new device when QEMU starts again: shut it down and start it (or `qm reboot VMID`); a restart from
# inside the guest keeps the old QEMU. The guest's half is the Install Venera package's "Hardware video decoding".
#
# Important: a VM with the device needs its socket (venera-videod@VMID.socket, enabled at boot) to start; QEMU waits
# for the service to answer. --remove-vm or --uninstall take the device out first.
# An older hand-made setup (venera-videod.service, /run/venera-video.sock in the VM's args) is replaced.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=/opt/venera
UNIT=/etc/systemd/system/venera-videod@.service
SOCK=/etc/systemd/system/venera-videod@.socket
LEGACY_UNIT=/etc/systemd/system/venera-videod.service
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
vm_args() { qm config "$1" 2>/dev/null | sed -n 's/^args: //p'; }
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
  --dry-run) DRY=1 ;;
  -h | --help) sed -n '2,30p' "$0"; exit 0 ;;
  *) die "unknown option $1 (--help)" ;;
  esac
  shift
done
for v in "${VMS[@]}"; do
  case $v in '' | *[!0-9]*) die "a VM id is a number: $v" ;; esac
done

[ "$(id -u)" = 0 ] || die "run as root"
command -v qm >/dev/null && command -v pveversion >/dev/null || die "this is for a Proxmox VE host (no qm / pveversion)"

# ---- each VM's device ----------------------------------------------------------------------------------------------
# check_vm ID: 0 when the VM can take our device (or has it), else dies saying why; nothing changes
check_vm() {
  local id=$1 cur want
  qm config "$id" >/dev/null 2>&1 || die "no VM $id on this host"
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

case $MODE in
status)
  say "Venera host: $(cat "$PREFIX/VERSION" 2>/dev/null || echo 'not installed')"
  for p in $PKGS; do
    say "  $p: $(dpkg-query -W -f='${Version}' $p 2>/dev/null || echo 'not installed')$(case " $(state_get apt_installed) " in *" $p "*) echo ' (installed by Venera)' ;; esac)"
  done
  say "  render node: $(ls /dev/dri/renderD* 2>/dev/null | tr '\n' ' ')"
  for id in $(our_vms); do
    say "  VM $id: device in its args; socket $(systemctl is-active "venera-videod@$id.socket" 2>/dev/null), service $(systemctl is-active "venera-videod@$id.service" 2>/dev/null); VM $(qm status "$id" 2>/dev/null | cut -d' ' -f2)"
  done
  exit 0
  ;;
remove)
  for id in "${VMS[@]}"; do remove_vm "$id"; done
  exit 0
  ;;
uninstall)
  for id in $(our_vms); do remove_vm "$id"; done
  for u in $(systemctl list-units --all --plain --no-legend 'venera-videod@*' 2>/dev/null | awk '{print $1}'); do
    run systemctl disable --now "$u"
  done
  for f in "$UNIT" "$SOCK"; do
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
  run rm -rf "$PREFIX/video" "$PREFIX/VERSION" "$PREFIX/state"
  run rm -rf /var/lib/private/venera-video /var/lib/venera-video
  say "Venera's host half removed. VM config backups stay in $PREFIX/backup (rm -rf $PREFIX when no longer wanted)."
  say "A VM that is running keeps its device until it stops."
  exit 0
  ;;
esac

# ---- install -------------------------------------------------------------------------------------------------------
[ ${#VMS[@]} -gt 0 ] || die "name the VM(s): --vm VMID (--help)"
for id in "${VMS[@]}"; do check_vm "$id"; done   # every VM checked before anything changes
for f in bin/venera-videod lib venera-videod@.service venera-videod@.socket VERSION; do
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
    say "VA-API: $(echo "$prof" | head -1); decodes $(echo "$prof" | grep -c 'decode:') profiles"
  else
    warn "VA-API can't decode H.264 on this GPU (vaprofiles: $(echo "$prof" | head -2 | tr '\n' ' '))"
  fi
fi

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
say "In each VM: install Venera with Hardware video decoding chosen, then shut the VM down and start it again."
[ $legacy = 1 ] && say "A VM that ran on the older setup has no video decoding until it is shut down and started again."
say "Updating later keeps running VMs' connections: systemd holds them while the service restarts."
