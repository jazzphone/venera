#!/bin/bash
# A macOS Sequoia VM for an earlier project.
# Creates the VM; for an existing one, adds its Mac identity, or finishes it once macOS and its guest agent are in.
# Turns on KVM's ignore_msrs, which macOS needs and the other VMs don't mind. Touches nothing else. Asks first.
# What each piece is for (each one a dead end without it, found 2026-11-12):
#   the SMC key             - without it boot stops at "busy timeout ... AppleACPICPU" (WindowServer can't be decrypted)
#   VMHide + Lilu 1.7       - without it the Apple Account sign-in sees a VM and fails ("Verification failed")
#   -cpu host (+hypervisor) - hiding the hypervisor from the CPU stops the kernel; VMHide hides it from Apple's checks only
#   no TRIM on the disk     - Disk Utility's erase TRIMs the whole disk, which shared iSCSI storage clears 2 MB at a time
#   1280x800                - enough for the timer service (2.0); the screen fallback scrolls to a tile (at 1920x1440
#                             the Home window shows every speaker and a screen read never scrolls, but drawing it all
#                             costs a VM without graphics acceleration far more)
#   the guest agent         - clean shutdowns (the clock: Date & Time > Set time automatically, in macOS)
set -euo pipefail
ask() { local v; read -r -p "  $2${3:+ [$3]}: " v; printf -v "$1" '%s' "${v:-${3:-}}"; }
yes_no() { local v; read -r -p "  $1 [y/N]: " v; [[ $v =~ ^[Yy] ]]; }
die() { echo "STOP: $*"; exit 1; }
num() { [[ $1 =~ ^[0-9]+$ ]] || die "$2 is a number"; }

apply_identity() {   # write MODEL/SERIAL/MLB/ROM into the OpenCore config on $OCIMG (a file or a VM disk)
  local loop mnt
  [[ $OCIMG == /dev/* ]] && lvchange -ay "$OCIMG"   # shared LVM keeps a stopped VM's disks inactive
  loop=$(losetup -fP --show "$OCIMG"); mnt=$(mktemp -d)
  mount "${loop}p1" "$mnt"
  MODEL=$MODEL SERIAL=$SERIAL MLB=$MLB ROM=$ROM python3 - "$mnt/EFI/OC/config.plist" <<'PY'
import os, plistlib, sys, uuid
p = sys.argv[1]
with open(p, "rb") as f: c = plistlib.load(f)
g = c["PlatformInfo"]["Generic"]
g["SystemProductName"] = os.environ["MODEL"]; g["SystemSerialNumber"] = os.environ["SERIAL"]; g["MLB"] = os.environ["MLB"]
g["ROM"] = bytes.fromhex(os.environ["ROM"].replace(":", "").replace("-", ""))
g["SystemUUID"] = str(uuid.uuid4()).upper()
c["PlatformInfo"]["Automatic"] = True; c["PlatformInfo"]["UpdateSMBIOSMode"] = "Create"
with open(p, "wb") as f: plistlib.dump(c, f)
print("   identity written:", g["SystemProductName"], g["SystemSerialNumber"][:4] + "...", "ROM", g["ROM"].hex(":"))
PY
  sync; umount "$mnt"; losetup -d "$loop"; rmdir "$mnt"
  [[ $OCIMG == /dev/* ]] && lvchange -an "$OCIMG" || true
}

LILU_URL=https://github.com/acidanthera/Lilu/releases/download/1.7.2/Lilu-1.7.2-RELEASE.zip
LILU_SHA=53967d7dcfaab01023a33df2e969a89522f13d6654a6a56ac4711b62dabf3ab8
VMHIDE_URL=https://github.com/Carnations-Botanica/VMHide/releases/download/2.0.0/VMHide-2.0.0-RELEASE.zip
VMHIDE_SHA=31ffb861192eea52ad166fc0629b411ae48d8507c75935ab875bc61aebaa8dbb

prepare_opencore() {   # on the OpenCore image file $OCIMG: Lilu 1.7.2 + VMHide, 1280x800, a 5 s boot menu, a quiet boot
  local loop mnt w; w=$(mktemp -d)
  command -v unzip >/dev/null || apt-get install -y unzip
  curl -fsL "$LILU_URL" -o "$w/lilu.zip"; curl -fsL "$VMHIDE_URL" -o "$w/vmhide.zip"
  echo "$LILU_SHA  $w/lilu.zip" | sha256sum -c --quiet || die "Lilu download doesn't match its checksum"
  echo "$VMHIDE_SHA  $w/vmhide.zip" | sha256sum -c --quiet || die "VMHide download doesn't match its checksum"
  unzip -q "$w/lilu.zip" -d "$w/lilu"; unzip -q "$w/vmhide.zip" -d "$w/vmhide"
  loop=$(losetup -fP --show "$OCIMG"); mnt=$(mktemp -d); mount "${loop}p1" "$mnt"
  rm -rf "$mnt/EFI/OC/Kexts/Lilu.kext"
  cp -R "$(find "$w/lilu" -maxdepth 2 -name Lilu.kext | head -1)" "$(find "$w/vmhide" -maxdepth 2 -name VMHide.kext | head -1)" "$mnt/EFI/OC/Kexts/"
  python3 - "$mnt/EFI/OC/config.plist" <<'PYOC'
import plistlib, sys
p = sys.argv[1]
with open(p, "rb") as f: c = plistlib.load(f)
add = c["Kernel"]["Add"]
if not any(k["BundlePath"] == "VMHide.kext" for k in add):
    i = [k["BundlePath"] for k in add].index("Lilu.kext")
    e = dict(add[i]); e.update({"BundlePath": "VMHide.kext", "ExecutablePath": "Contents/MacOS/VMHide", "PlistPath": "Contents/Info.plist",
                                "Comment": "VMHide: hide the VM from Apple Account sign-in", "MinKernel": "", "MaxKernel": "", "Enabled": True})
    add.insert(i + 1, e)
c["UEFI"]["Output"]["Resolution"] = "1280x800@32"
c["Misc"]["Boot"]["Timeout"] = 5
c["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]["boot-args"] = "keepsyms=1"
with open(p, "wb") as f: plistlib.dump(c, f)
print("   OpenCore: Lilu 1.7.2 + VMHide, 1280x800, boot menu 5 s")
PYOC
  sync; umount "$mnt"; losetup -d "$loop"; rmdir "$mnt"; rm -rf "$w"
}

finish_vm() {   # macOS installed, signed in, the guest agent running: set its clock once and free the core it wastes
  qm agent "$VMID" ping >/dev/null 2>&1 || die "VM $VMID's guest agent doesn't answer: install mac-guest-agent in macOS first (see the end of a create run)"
  qm guest exec "$VMID" --timeout 20 -- /usr/bin/sntp -sS time.apple.com >/dev/null
  # Apple's power logging held a core at ~90% in the VM; disabling it survives reboots (undo: launchctl enable)
  qm guest exec "$VMID" --timeout 20 -- /bin/launchctl disable system/com.apple.PerfPowerServices >/dev/null
  qm guest exec "$VMID" --timeout 20 -- /bin/launchctl bootout system/com.apple.PerfPowerServices >/dev/null 2>&1 || true
  if qm config "$VMID" | grep -q '^ide0:'; then echo "  (the installer disk ide0 can go: qm set $VMID --delete ide0, with the VM stopped)"; fi
  echo "== Done: clock set, PerfPowerServices off. Keep Date & Time > Set time automatically on in macOS."
}

echo; echo "== A macOS Sequoia VM for the home device timer reader"
echo "  VMs now:"; qm list | sed 's/^/    /'
ask NAME "VM name" "macos"
EXIST=$(qm list | awk -v n="$NAME" '$2 == n {print $1}' | head -1)
MODE=create
if [ -n "$EXIST" ]; then
  VMID=$EXIST; echo "  $NAME is VM $VMID already."
  if yes_no "Finish it (macOS installed and signed in, guest agent running): set the clock and PerfPowerServices off?"; then
    finish_vm; exit 0
  fi
  yes_no "Add or change its Mac identity only?" || die "nothing changed"
  qm status $VMID | grep -q stopped || die "shut VM $VMID down first (Proxmox's Shutdown, or Apple menu > Shut Down), then run this again"
  OCVOL=$(qm config $VMID | sed -n 's/^ide2: \([^,]*\).*/\1/p'); [ -n "$OCVOL" ] || die "VM $VMID has no OpenCore disk on ide2"
  OCIMG=$(pvesm path "$OCVOL"); MODE=identity
else
  echo; echo "  VM storage (its disks):"; pvesm status --content images | sed 's/^/    /'
  ask STORAGE "Storage for the VM's disks" "local-lvm"
  pvesm status --content images | awk 'NR>1{print $1}' | grep -qx "$STORAGE" || die "$STORAGE can't hold VM disks"
  echo; echo "  ISO storage (where the OpenCore and macOS recovery images are downloaded, ~1.1 GB):"; pvesm status --content iso | sed 's/^/    /'
  ask ISOSTORE "Storage for the downloads" "local"
  pvesm status --content iso | awk 'NR>1{print $1}' | grep -qx "$ISOSTORE" || die "$ISOSTORE can't hold ISO images"
  ISO=$(dirname "$(pvesm path "$ISOSTORE:iso/probe.iso")")
  echo; echo "  Network bridges:"; ip -br link show type bridge | awk '$1 ~ /^vmbr/ {print "    " $1}'
  ask BRIDGE "Bridge" "vmbr0"
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "no bridge $BRIDGE"
  ask VLAN "VLAN tag (the home devices' network; empty for none)" "50"
  [ -z "$VLAN" ] || num "$VLAN" "the VLAN tag"
  ask VMID "VM number" "$(pvesh get /cluster/nextid)"; num "$VMID" "the VM number"
  qm status "$VMID" >/dev/null 2>&1 && die "VM $VMID already exists"
  ask CORES "Cores" "4"; num "$CORES" "cores"
  ask MEM "Memory in MB" "8192"; num "$MEM" "memory"
  ask DISK "Disk in GB" "64"; num "$DISK" "the disk size"
  # Apple's SMC key, the same for every Mac (published by the open-source macOS VM projects). The OpenCore image has no
  # VirtualSMC, so without it macOS can't decrypt WindowServer and boot stalls at "busy timeout ... AppleACPICPU".
  OSK="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
  BASE=$ISO/OpenCore-v21.iso OCIMG=$ISO/OpenCore-$NAME.iso REC=$ISO/Sequoia-recovery.img
fi

echo; echo "  Your MacBook's identity, used to sign into iCloud. Press Enter at the serial to skip it for now:"
echo "  the VM then keeps the shared sample identity from OpenCore and must NOT be signed into iCloud until you run this again."
SERIAL="" MLB="" ROM=""
ask MODEL "Model identifier" "MacBookPro14,1"
ask SERIAL "Serial number"
if [ -n "$SERIAL" ]; then
  SERIAL=${SERIAL^^}; [[ $SERIAL =~ ^[A-Z0-9]{10,12}$ ]] || die "that serial doesn't look like a Mac serial"
  ask MLB "Board serial (MLB)"; MLB=${MLB^^}; [[ $MLB =~ ^[A-Z0-9]{13,17}$ ]] || die "that MLB doesn't look right (13-17 letters and digits)"
  ask ROM "Wi-Fi MAC address (aa:bb:cc:dd:ee:ff)"; ROM=${ROM,,}
  [[ $ROM =~ ^([0-9a-f]{2}[:-]){5}[0-9a-f]{2}$ ]] || die "that MAC address doesn't look right"
elif [ $MODE = identity ]; then die "no identity given: nothing changed"
fi

echo; echo "== The plan"
if [ $MODE = create ]; then
  PCORES=$(cat /sys/devices/cpu_core/cpus 2>/dev/null || echo "0-7")
  echo "  - KVM ignore_msrs on (now and after reboots)"
  echo "  - download the OpenCore image (thenickdude/KVM-Opencore v21) and macOS Sequoia's recovery from Apple into $ISO"
  echo "  - VM $VMID '$NAME': $CORES cores on the performance cores ($PCORES), $MEM MB, $DISK GB on $STORAGE"
  echo "    (the OpenCore and recovery images are imported as two small disks there too)"
  echo "  - network: $BRIDGE${VLAN:+, VLAN $VLAN}; starts with the host"
  echo "  - SMC: QEMU applesmc with Apple's SMC key; CPU: the host's own; OpenCore with Lilu 1.7.2 + VMHide, 1280x800"
  echo "  - a guest agent port (ISA serial) for mac-guest-agent"
fi
if [ -n "$SERIAL" ]; then echo "  - Mac identity: $MODEL, serial ${SERIAL:0:4}..., MAC $ROM"
else echo "  - Mac identity: the sample one from OpenCore (no iCloud until you add yours)"; fi
yes_no "Go ahead?" || die "nothing changed"

if [ $MODE = identity ]; then
  [[ $OCIMG == /dev/* ]] && lvchange -ay "$OCIMG"
  BK=/root/opencore-$NAME-$(date +%Y%m%d-%H%M%S).img; dd if="$OCIMG" of="$BK" bs=1M status=none
  apply_identity
  echo "== Done (the previous OpenCore disk is saved as $BK). Start VM $VMID, then sign into your Apple Account inside it."; exit 0
fi

echo "== KVM: ignore_msrs on"
echo 1 > /sys/module/kvm/parameters/ignore_msrs
echo 0 > /sys/module/kvm/parameters/report_ignored_msrs 2>/dev/null || true
[ -f /etc/modprobe.d/kvm-macos.conf ] || echo "options kvm ignore_msrs=1 report_ignored_msrs=0" > /etc/modprobe.d/kvm-macos.conf

echo "== OpenCore image"
mkdir -p "$ISO"
if [ ! -f "$BASE" ]; then
  curl -fL https://github.com/thenickdude/KVM-Opencore/releases/download/v21/OpenCore-v21.iso.gz -o /tmp/OpenCore-v21.iso.gz
  gunzip -c /tmp/OpenCore-v21.iso.gz > "$BASE" && rm /tmp/OpenCore-v21.iso.gz
fi
[ -f "$OCIMG" ] || { cp "$BASE" "$OCIMG"; prepare_opencore; }
[ -z "$SERIAL" ] || apply_identity

echo "== macOS Sequoia recovery, from Apple"
if [ ! -f "$REC" ]; then
  command -v dmg2img >/dev/null || apt-get install -y dmg2img
  W=$(mktemp -d); cd "$W"
  curl -fsL https://raw.githubusercontent.com/acidanthera/OpenCorePkg/1.0.8/Utilities/macrecovery/macrecovery.py -o macrecovery.py
  python3 macrecovery.py -b Mac-7BA5B2D9E42DDD94 -m 00000000000000000 download
  dmg2img com.apple.recovery.boot/BaseSystem.dmg "$REC"
  cd /; rm -rf "$W"
fi

echo "== VM $VMID"
qm create $VMID --name "$NAME" --ostype other --machine q35 --bios ovmf \
  --cores $CORES --sockets 1 --affinity "$PCORES" --memory $MEM --balloon 0 \
  --vga vmware --tablet 1 --agent enabled=1,type=isa \
  --net0 "vmxnet3,bridge=$BRIDGE${VLAN:+,tag=$VLAN},firewall=0" \
  --efidisk0 $STORAGE:1,efitype=4m,pre-enrolled-keys=0 \
  --virtio0 $STORAGE:$DISK,cache=none --onboot 1   # no discard: a TRIM over iSCSI crawls
echo "== importing the OpenCore and recovery images as disks"
qm disk import $VMID "$OCIMG" $STORAGE --format raw >/dev/null
qm disk import $VMID "$REC" $STORAGE --format raw >/dev/null
OCDISK=$(qm config $VMID | sed -n 's/^unused0: //p'); RECDISK=$(qm config $VMID | sed -n 's/^unused1: //p')
[ -n "$OCDISK" ] && [ -n "$RECDISK" ] || die "the imported disks didn't show up (qm config $VMID)"
qm set $VMID --ide2 "$OCDISK,cache=unsafe" --ide0 "$RECDISK,cache=unsafe" --boot order=ide2 >/dev/null
qm set $VMID --args "-smbios type=2 -device qemu-xhci -device usb-kbd -device usb-tablet -global nec-usb-xhci.msi=off -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off -cpu host,vendor=GenuineIntel,+invtsc,+hypervisor,kvm=on,vmware-cpuid-freq=on -device isa-applesmc,osk=\"$OSK\"" >/dev/null
echo "== Done: VM $VMID ($NAME). Start it from the Proxmox web page, open its Console, and install macOS Sequoia:"
echo "   macOS Base System > Disk Utility > View > Show All Devices > erase the VirtIO disk (APFS, GUID) > Reinstall."
echo "   After setup, in macOS: no Messages or FaceTime sign-in; iCloud: only Home and Keychain; automatic updates off;"
echo "   set time automatically; never sleep; automatic login (FileVault off); Accessibility > Display > Reduce motion and transparency;"
echo "   Dock: hide automatically; sudo mdutil -a -i off. The guest agent: build mac-guest-agent (MIT, v2.5.6) from source"
echo "   and run its --install. Then run this script again and choose Finish. The reader: ~/src/an-earlier-project."
[ -n "$SERIAL" ] || echo "   Do not sign into an Apple Account in it until you have run this script again with your MacBook's identity."
echo "   Undo: qm destroy $VMID --purge; rm /etc/modprobe.d/kvm-macos.conf; rm $OCIMG $BASE $REC"
