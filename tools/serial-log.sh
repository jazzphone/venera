#!/bin/bash
# serial-log: a macOS VM's kernel log over a serial port, recorded on the Proxmox host one file per boot (round 21).
# macOS's own log keeps the kexts' lines across restarts, but not the last seconds before a hang or a panic; the
# kernel writes its console to the serial port as it goes, so this keeps those too (it found Recovery's missing
# picture, round 20). For debugging: it adds a device and a boot-arg, and the console output costs a little speed.
#
#   serial-log.sh VMID on       a serial port (serial0: socket) and serial=3 in OpenCore's boot-args (through the guest
#                               agent); both start at the VM's next stop and start (Proxmox adds devices only then)
#   serial-log.sh VMID record   record it: /var/log/venera/serial-VMID-DATE.log, a new file each time the VM starts,
#                               until stopped (Ctrl-C); run it in the background with nohup, or in tmux
#   serial-log.sh VMID off      take both out again (at the next stop and start)
# Runs on the Proxmox node the VM is on, as root. Needs socat (apt install socat).
set -u
VM=${1:?usage: serial-log.sh VMID on|record|off}
CMD=${2:?usage: serial-log.sh VMID on|record|off}
GUID=7C436110-AB2A-4BBB-A880-FE41995C9F82
die() { echo "serial-log: $*" >&2; exit 1; }
qm status "$VM" >/dev/null 2>&1 || die "no VM $VM on this node"

# boot_args ADD|DEL: serial=3 in or out of OpenCore's boot-args, from inside macOS through the guest agent
boot_args() {
  # OpenCore: the EFI partition (or Venera's OPENCORE disk) holding EFI/OC/config.plist, as uninstall.sh finds it
  local sh='d=""; mp=""
for p in $(diskutil list | awk "/ EFI |OPENCORE/ {print \$NF}"); do
  m=$(diskutil info "$p" | awk -F": *" "/Mount Point/ {print \$2}"); fresh=""
  if [ -z "$m" ]; then diskutil mount "$p" >/dev/null 2>&1 || continue; m=$(diskutil info "$p" | awk -F": *" "/Mount Point/ {print \$2}"); fresh=1; fi
  if [ -f "$m/EFI/OC/config.plist" ]; then d=$p; mp=$m; break; fi
  [ -n "$fresh" ] && diskutil unmount "$p" >/dev/null 2>&1
done
[ -n "$d" ] || { echo "no OpenCore found" >&2; exit 3; }
c="$mp/EFI/OC/config.plist"; k=NVRAM.Add.'$GUID'.boot-args
a=$(plutil -extract "$k" raw -o - "$c" 2>/dev/null); n=""
for x in $a; do [ "$x" = serial=3 ] || n="$n $x"; done
[ '"$1"' = ADD ] && n="$n serial=3"
cp "$c" "$c.venera-serial"; plutil -replace "$k" -string "${n# }" "$c" && plutil -extract "$k" raw -o - "$c"
diskutil unmount "$d" >/dev/null 2>&1; true'
  qm guest exec "$VM" --timeout 60 -- /bin/bash -c "$sh" | python3 -I -c '
import json, sys
r = json.load(sys.stdin)
sys.stdout.write(r.get("out-data", "")); sys.stderr.write(r.get("err-data", ""))
sys.exit(r.get("exitcode", 1))' || die "couldn't change OpenCore's boot-args (is the VM running, with the guest agent?)"
}

case $CMD in
on)
  qm config "$VM" | grep -q '^serial0:' || qm set "$VM" --serial0 socket >/dev/null || die "qm set failed"
  out=$(boot_args ADD) || exit 1
  echo "boot-args now: $out"
  echo "Stop and start VM $VM (a restart inside macOS isn't enough for the new port), then: $0 $VM record"
  ;;
off)
  out=$(boot_args DEL) || exit 1
  echo "boot-args now: $out"
  qm set "$VM" --delete serial0 >/dev/null 2>&1
  echo "Both go at VM $VM's next stop and start."
  ;;
record)
  command -v socat >/dev/null || die "needs socat: apt install socat"
  SOCK=/var/run/qemu-server/$VM.serial0
  mkdir -p /var/log/venera
  echo "recording VM $VM's serial port into /var/log/venera/ (a file per boot); Ctrl-C to stop"
  while true; do
    if [ -S "$SOCK" ]; then
      f=/var/log/venera/serial-$VM-$(date +%Y%m%d-%H%M%S).log
      echo "  $f"
      socat -u UNIX-CONNECT:"$SOCK" CREATE:"$f" 2>/dev/null   # returns when the VM stops (the socket goes away)
      [ -s "$f" ] || rm -f "$f"
    fi
    sleep 2
  done
  ;;
*) die "usage: serial-log.sh VMID on|record|off" ;;
esac
