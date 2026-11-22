#!/bin/bash
# The VM script's own pieces, without a Proxmox host: the args Venera adds, a cluster node's address, and OpenCore's
# config.plist: Venera's (vm/opencore/config.py over OpenCorePkg's Sample.plist, $1), the VM script's edits on it, and
# moving an older VM's config ($2, KVM-Opencore v21's, say) onto it. Runs anywhere with bash 4+ and python3, e.g.
#   bash vm/test.sh SAMPLE [OLD-CONFIG]   (on a Proxmox host, say, or GitHub's checks: .github/workflows/checks.yml)
set -u
SAMPLE=${1:?the Docs/Sample.plist of the OpenCorePkg release vm/opencore/build.sh uses}
OLDCFG=${2:-$SAMPLE}   # an older OpenCore config.plist to move (KVM-Opencore v21's, say); OpenCorePkg's sample stands in
MACOS_VM_TEST=1 . "$(dirname "$0")/proxmox-macos-vm.sh"
set +e
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
W=$(mktemp -d)

OSK='osk="the(c)key"'   # a stand-in for the SMC key older VMs' args carry
NEW="-smbios type=2 -device qemu-xhci -cpu host,vendor=GenuineIntel,+invtsc,+hypervisor,kvm=on,vmware-cpuid-freq=on -device isa-applesmc,$OSK"
A=$(venera_args "$NEW" 1)
check "the address width goes into -cpu host" '[[ $A == *" -cpu host,host-phys-bits-limit=40,vendor=GenuineIntel,+invtsc,"* ]]'
check "Venus's three globals and the sound device" '[[ $A == *"-global virtio-vga-gl.venus=on -global virtio-vga-gl.blob=on -global virtio-vga-gl.hostmem=2G -audiodev spice,id=vsnd -device usb-audio,audiodev=vsnd" ]]'
check "the rest kept as it was" '[[ $A == "-smbios type=2 -device qemu-xhci -cpu host,"*"-device isa-applesmc,$OSK -global"* ]]'
check "a second pass adds nothing" '[ "$(venera_args "$A" 1)" = "$A" ]'
check "QEMU's applesmc out of the args (its quoted key too), the rest kept" '[ "$(no_applesmc "$NEW -global x=1")" = "-smbios type=2 -device qemu-xhci -cpu host,vendor=GenuineIntel,+invtsc,+hypervisor,kvm=on,vmware-cpuid-freq=on -global x=1" ] && [ "$(no_applesmc "-device isa-applesmc -cpu host")" = "-cpu host" ] && [ "$(no_applesmc "-cpu host")" = "-cpu host" ]'
check "no sound device when not asked" '[[ $(venera_args "$NEW" 0) != *usb-audio* ]]'
V107="-smbios type=2 -cpu host,host-phys-bits-limit=40,vendor=GenuineIntel -global virtio-vga-gl.venus=on -global virtio-vga-gl.blob=on -global virtio-vga-gl.hostmem=2G -audiodev spice,id=vsnd -device usb-audio,audiodev=vsnd -chardev socket,path=/run/venera-video-107.sock,id=vvideo"
check "a VM that has it all is left alone" '[ "$(venera_args "$V107" 1)" = "$V107" ]'
check "-cpu host at the end of the line" '[ "$(venera_args "-smbios type=2 -cpu host" 0)" = "-smbios type=2 -cpu host,host-phys-bits-limit=40 -global virtio-vga-gl.venus=on -global virtio-vga-gl.blob=on -global virtio-vga-gl.hostmem=2G" ]'
O=$(venera_args "-cpu Skylake-Client,host-phys-bits=on" 0 2>&1 >/dev/null)
check "a -cpu with the host's address width is reported, not changed" '[[ $O == *"add host-phys-bits-limit=40 to it by hand"* ]] && [[ $(venera_args "-cpu Skylake-Client,host-phys-bits=on" 0 2>/dev/null) == "-cpu Skylake-Client,host-phys-bits=on -global"* ]]'
O=$(venera_args "-cpu Haswell-noTSX,vendor=GenuineIntel" 0 2>&1 >/dev/null)
check "a named model (an AMD host's) is left as it is, quietly" '[ -z "$O" ] && [[ $(venera_args "-cpu Haswell-noTSX,vendor=GenuineIntel" 0) == "-cpu Haswell-noTSX,vendor=GenuineIntel -global"* ]]'

X=$(choices_xml 1 0 1)
check "the upgrade's choices are a property list Installer reads" 'python3 -c "import plistlib,sys; a=plistlib.loads(sys.argv[1].encode()); assert [(d[\"choiceIdentifier\"], d[\"attributeSetting\"], d[\"choiceAttribute\"]) for d in a] == [(\"video\",1,\"selected\"),(\"app\",0,\"selected\"),(\"webgl\",1,\"selected\"),(\"agent\",1,\"selected\")]" "$X"'
X=$(choices_xml 1 0 1 0)
check "the guest agent left out when it was" 'python3 -c "import plistlib,sys; a=plistlib.loads(sys.argv[1].encode()); assert [(d[\"choiceIdentifier\"], d[\"attributeSetting\"], d[\"choiceAttribute\"]) for d in a] == [(\"video\",1,\"selected\"),(\"app\",0,\"selected\"),(\"webgl\",1,\"selected\"),(\"agent\",0,\"selected\")]" "$X"'
qm() { echo "machine: $MOCK_MACHINE"; }   # clipboard_ok reads the VM's machine
cb() { MOCK_MACHINE=$1; VMID=999 clipboard_ok && echo on || echo off; }
check "the console's clipboard where live migration keeps working (machine 10.1 up, or unpinned)" '[ "$(cb q35)" = on ] && [ "$(cb pc-q35-10.1+pve0)" = on ] && [ "$(cb pc-q35-11.1)" = on ] && [ "$(cb pc-q35-9.2+pve1)" = off ] && [ "$(cb pc-i440fx-8.1)" = off ]'
qm() { echo "ide1: $MOCK_IDE1,media=cdrom"; }   # tools_cd_old reads the VM's CD slots
oldcd() { MOCK_IDE1=$1; VER=$2 VMID=999 tools_cd_old; }
check "two tablets: the args' and Proxmox's default" '[ "$(qm() { printf "args: -device qemu-xhci -device usb-tablet\nostype: osx\n"; }; VMID=9 two_tablets)" = yes ]'
check "one tablet once Proxmox's is off" '[ -z "$(qm() { printf "args: -device usb-tablet\ntablet: 0\n"; }; VMID=9 two_tablets)" ]'
check "a Tools CD in ide0 is found too" '[ "$(qm() { echo "ide0: diskstation:iso/Venera-Tools-0.1.9.iso,media=cdrom"; }; VMID=9 tools_cd_slot)" = ide0 ]'
check "an older release's Tools CD is found, this release's and another ISO aren't" '[ "$(oldcd diskstation:iso/Venera-Tools-0.1.9.iso 0.1.10)" = diskstation:iso/Venera-Tools-0.1.9.iso ] && [ -z "$(oldcd diskstation:iso/Venera-Tools-0.1.10.iso 0.1.10)" ] && [ -z "$(oldcd local:iso/ubuntu.iso 0.1.10)" ]'
unset -f qm
LK='[{"kCGSSessionOnConsoleKey":true,"CGSSessionScreenIsLocked":true}]' NB='[{"kCGSSessionOnConsoleKey":false}]' OP='[{"kCGSSessionOnConsoleKey":true}]'
check "a locked screen, nobody, and an open one" '[ "$(screen_says <<<"$LK")" = locked ] && [ "$(screen_says <<<"$NB")" = nobody ] && [ "$(screen_says <<<"$OP")" = open ] && [ "$(screen_says <<<"")" = open ]'

cat >"$W/corosync.conf" <<'C'
nodelist {
  node {
    name: pve-a
    nodeid: 1
    quorum_votes: 1
    ring0_addr: 192.0.2.11
  }
  node {
    name: pve-b
    nodeid: 2
    ring0_addr: 192.0.2.12
  }
}
C
CFG=$(mktemp); python3 "$(dirname "$0")/opencore/config.py" "$SAMPLE" "$CFG"
check "a node's address from corosync" '[ "$(COROSYNC=$W/corosync.conf node_ip pve-a)" = 192.0.2.11 ] && [ "$(COROSYNC=$W/corosync.conf node_ip pve-b)" = 192.0.2.12 ] && [ -z "$(COROSYNC=$W/corosync.conf node_ip pve-c)" ]'

ok_plist() { python3 - "$@" <<'PY'
import plistlib, sys
c = plistlib.load(open(sys.argv[1], "rb")); what = sys.argv[2]; G = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
nv, gen, add = c["NVRAM"], c["PlatformInfo"]["Generic"], [k["BundlePath"] for k in c["Kernel"]["Add"]]
s = plistlib.load(open(sys.argv[3], "rb"))
if what == "create":
    ok = (add == ["Lilu.kext", "VirtualSMC.kext", "VeneraHide.kext"] and gen["SystemUUID"] != "00000000-0000-0000-0000-000000000000"
          and c["UEFI"]["Output"]["Resolution"] == "1920x1080@32" and c["Misc"]["Boot"]["Timeout"] == 5
          and nv["Add"][G]["boot-args"] == "keepsyms=1 amfi_get_out_of_my_way=1"
          and nv["Add"][G]["csr-active-config"] == bytes.fromhex("03020000")
          and {"boot-args", "csr-active-config"} <= set(nv["Delete"][G])
          and gen["SystemProductName"] == "iMac20,1" and gen["SystemSerialNumber"] == s["PlatformInfo"]["Generic"]["SystemSerialNumber"])
elif what == "identity":
    ok = (gen["SystemProductName"] == "iMac20,1" and gen["SystemSerialNumber"] == "C02ABCDEFGHJ" and gen["MLB"] == "C02123456789ABCDE"
          and gen["ROM"] == bytes.fromhex("aabbccddeeff") and c["PlatformInfo"]["UpdateSMBIOSMode"] == "Create"
          and nv == s["NVRAM"] and c["Kernel"] == s["Kernel"])
sys.exit(0 if ok else 1)
PY
}
cp "$CFG" "$W/c.plist"
NEWUUID=1 OC_RES=1920x1080 OC_TIMEOUT=5 OC_ARGS="keepsyms=1 amfi_get_out_of_my_way=1" OC_CSR=03020000 MODEL=iMac20,1 SERIAL="" MLB="" ROM="" oc_config "$W/c.plist" >"$W/oc.log"
check "a new VM's OpenCore: Lilu, VirtualSMC and VeneraHide, its own UUID, the screen, SIP 0x203, AMFI, the model" 'ok_plist "$W/c.plist" create "$CFG"'
cp "$W/c.plist" "$W/c1.plist"
OC_RES=1920x1080 OC_TIMEOUT=5 OC_ARGS="keepsyms=1 amfi_get_out_of_my_way=1" OC_CSR=03020000 MODEL=iMac20,1 SERIAL="" MLB="" ROM="" oc_config "$W/c.plist" >/dev/null
check "OpenCore edited twice is the same" 'python3 -c "import plistlib,sys; sys.exit(plistlib.load(open(\"$W/c.plist\",\"rb\")) != plistlib.load(open(\"$W/c1.plist\",\"rb\")))"'
check "it says what it set" 'grep -q "SIP: csr-active-config 0x203" "$W/oc.log" && grep -q "model: iMac20,1" "$W/oc.log"'
cp "$CFG" "$W/i.plist"
MODEL=iMac20,1 SERIAL=C02ABCDEFGHJ MLB=C02123456789ABCDE ROM=aa:bb:cc:dd:ee:ff oc_config "$W/i.plist" >/dev/null
check "the identity alone changes only PlatformInfo" 'ok_plist "$W/i.plist" identity "$CFG"'
cp "$CFG" "$W/w.plist"
OC_RES=1280x800 OC_ARGS="keepsyms=1 amfi_get_out_of_my_way=1" OC_CSR=030A0000 MODEL=iMac20,1 SERIAL="" oc_config "$W/w.plist" | grep -q "0xA03"
check "Safari WebGL's SIP is 0xA03" '[ $? = 0 ]'
# the startup settings (choice 6): read back what was written, the display's size in the args, the sizes it takes
cp "$CFG" "$W/s.plist"
OC_RES=1440x900 OC_TIMEOUT=8 OC_TRIM=on OC_ARGS="keepsyms=1 debug=0x100 amfi_get_out_of_my_way=1 vgpuaccel=4 -v" oc_config "$W/s.plist" >/dev/null
eval "$(oc_read "$W/s.plist")"
check "TRIM written and read back" '[ "$CUR_TRIM" = on ] && OC_TRIM=off oc_config "$W/s.plist" >/dev/null && eval "$(oc_read "$W/s.plist")" && [ "$CUR_TRIM" = off ]'
eval "$(oc_read "$W/s.plist")"
check "startup settings read back as written" '[ "$CUR_RES" = 1440x900 ] && [ "$CUR_TIMEOUT" = 8 ] && [ "$CUR_ARGS" = "keepsyms=1 debug=0x100 amfi_get_out_of_my_way=1 vgpuaccel=4 -v" ] && [ -n "$CUR_MODEL" ]'
check "the display's size into the args, once, the rest kept" '[ "$(screen_args "-cpu host -global virtio-vga-gl.xres=1280 -global virtio-vga-gl.yres=800 -global virtio-vga-gl.venus=on" 1920x1080)" = "-cpu host -global virtio-vga-gl.venus=on -global virtio-vga-gl.xres=1920 -global virtio-vga-gl.yres=1080" ] && [ "$(screen_args "-cpu host" 1440x900)" = "-cpu host -global virtio-vga-gl.xres=1440 -global virtio-vga-gl.yres=900" ]'
check "screen sizes: up to 3840x2400 with Venera, larger without" '(screen_size 3840x2400 1) && ! (screen_size 5120x2880 1 >/dev/null) && (screen_size 5120x2880 0) && ! (screen_size 1920 1 >/dev/null) && ! (screen_size 320x200 0 >/dev/null)'

# an older VM's config (with Venera's kexts and its own identity) moved onto Venera's
python3 - "$OLDCFG" "$W/old.plist" <<'PY'
import plistlib, sys
c = plistlib.load(open(sys.argv[1], "rb"))
for k in ("VirtioGPU", "VeneraVideo", "VeneraBalloon"):
    c["Kernel"]["Add"].append({"Arch": "x86_64", "BundlePath": k + ".kext", "Comment": "Venera", "Enabled": True,
                               "ExecutablePath": "Contents/MacOS/" + k, "MaxKernel": "", "MinKernel": "", "PlistPath": "Contents/Info.plist"})
c["NVRAM"]["Add"]["7C436110-AB2A-4BBB-A880-FE41995C9F82"]["boot-args"] = "keepsyms=1 vgpuaccel=4"
c["PlatformInfo"]["Generic"]["SystemSerialNumber"] = "C02OWNSERIAL"
c["UEFI"]["Output"]["Resolution"] = "1280x800@32"
plistlib.dump(c, open(sys.argv[2], "wb"))
PY
cp "$CFG" "$W/moved.plist"; oc_transplant "$W/old.plist" "$W/moved.plist" >/dev/null
check "an older VM moved to Venera's OpenCore: its kexts, boot-args, identity and screen kept, the old extras gone" 'python3 -c "
import plistlib, sys
c = plistlib.load(open(\"$W/moved.plist\", \"rb\")); add = [k[\"BundlePath\"] for k in c[\"Kernel\"][\"Add\"]]
sys.exit(not (add == [\"Lilu.kext\", \"VirtualSMC.kext\", \"VeneraHide.kext\", \"VirtioGPU.kext\", \"VeneraVideo.kext\", \"VeneraBalloon.kext\"]
    and c[\"NVRAM\"][\"Add\"][\"7C436110-AB2A-4BBB-A880-FE41995C9F82\"][\"boot-args\"] == \"keepsyms=1 vgpuaccel=4\"
    and c[\"PlatformInfo\"][\"Generic\"][\"SystemSerialNumber\"] == \"C02OWNSERIAL\" and c[\"UEFI\"][\"Output\"][\"Resolution\"] == \"1280x800@32\"
    and c[\"Misc\"][\"Boot\"][\"PickerMode\"] == \"Builtin\" and not c[\"UEFI\"][\"Drivers\"][1][\"Path\"].startswith(\"OpenCanopy\")))"'
# an older Venera VM's config (VeneraHide and Venera's kexts, no VirtualSMC) gets Lilu and VirtualSMC first, once
python3 - "$CFG" "$W/smc.plist" <<'PY'
import plistlib, sys
c = plistlib.load(open(sys.argv[1], "rb"))
c["Kernel"]["Add"] = [k for k in c["Kernel"]["Add"] if k["BundlePath"] == "VeneraHide.kext"]
c["Kernel"]["Add"].append(dict(c["Kernel"]["Add"][0], BundlePath="VirtioGPU.kext", ExecutablePath="Contents/MacOS/VirtioGPU"))
plistlib.dump(c, open(sys.argv[2], "wb"))
PY
oc_smc_merge "$CFG" "$W/smc.plist" >/dev/null; oc_smc_merge "$CFG" "$W/smc.plist" >/dev/null
check "an older Venera VM's OpenCore gets Lilu and VirtualSMC first, once" 'python3 -c "
import plistlib, sys
add = [k[\"BundlePath\"] for k in plistlib.load(open(\"$W/smc.plist\", \"rb\"))[\"Kernel\"][\"Add\"]]
sys.exit(add != [\"Lilu.kext\", \"VirtualSMC.kext\", \"VeneraHide.kext\", \"VirtioGPU.kext\"])"'
# a generated Mac identity (macserial beside the script, in opencore/, as the host package has it)
if [ -n "$MACSERIAL" ]; then
  mlb_ok() {   # a 17-character MLB's checksum (macserial's FORMAT.md)
    python3 -c '
import sys
a = "0123456789ABCDEFGHJKLMNPQRSTUVWXYZ"; m = sys.argv[1]
sys.exit(not (len(m) == 17 and all(ch in a for ch in m) and
              sum(((i & 1) == (len(m) & 1)) * 2 * a.index(ch) + a.index(ch) for i, ch in enumerate(m)) % 34 == 0))' "$1"
  }
  MODEL=iMac20,1; gen_identity; S1=$SERIAL M1=$MLB R1=$ROM
  check "a generated identity: the serial is the model's, the board serial's checksum holds, made at the same factory" '[ "$(serial_model "$S1")" = iMac20,1 ] && mlb_ok "$M1" && [ "${S1:0:3}" = "${M1:0:3}" ] && [ $GENERATED = 1 ]'
  check "its Wi-Fi MAC: an Apple prefix, six bytes" '[[ $R1 =~ ^(00:16:cb|00:1b:63|00:1e:c2|00:23:df|00:25:00|28:cf:e9|3c:07:54|40:6c:8f|68:5b:35|70:cd:60|7c:6d:62|88:63:df|a4:83:e7|ac:87:a3|c8:2a:14|f0:18:98)(:[0-9a-f]{2}){3}$ ]]'
  gen_identity
  check "each VM its own: a second one differs" '[ "$SERIAL" != "$S1" ] && [ "$MLB" != "$M1" ] && [ "$ROM" != "$R1" ]'
  MODEL=MacBookPro16,1; gen_identity
  check "another model gets its own model code" '[ "$(serial_model "$SERIAL")" = MacBookPro16,1 ] && mlb_ok "$MLB"'
  O=$( (MODEL=NoSuchMac1,1; gen_identity) 2>&1)
  check "a model macserial doesn't know stops with a reason" '[[ $O == *"macserial has no identity for model NoSuchMac1,1"* ]]'
else
  echo "skip the generated identity (no macserial in opencore/ beside the script)"
fi
# the answers file: vm/answers.example as the script reads it (comments, a value with a space, empty values)
load_answers "$(dirname "$0")/answers.example"
check "answers.example reads as documented" '[ "${ANS[NAME]}" = macos ] && [ "${ANS[MACOS_VOLUME]}" = "Macintosh HD" ] && [ -z "${ANS[VLAN]}" ] && [ -n "${ANS[NODES]+x}" ] && [ -z "${ANS[NODES]}" ] && [ "${ANS[INSTALL]}" = n ] && [ -z "${ANS[VMID]+x}" ] && [ -z "${ANS[MACOS_LICENSE]+x}" ]'
ask CORES "Cores" 2 >/dev/null
check "an answered question takes the file's value, a missing key its default" '[ "$CORES" = 4 ] && { ask NOSUCHKEY "x" dflt >/dev/null; [ "$NOSUCHKEY" = dflt ]; }'
check "yes/no from the file, nodes from NODES, and Go ahead is yes" '! no_yes "q" INSTALL 2>/dev/null && no_yes "q" VENERA 2>/dev/null && ! no_yes "q" NODE:pve2 2>/dev/null && yes_no "Go ahead?" 2>/dev/null'
ANSWERS=""
check "a package that isn't installed is missing" '[ "$(missing_pkgs bash no-such-package-here)" = "no-such-package-here " ]'
# the balloon device (Proxmox's memory figure): its minimum is the VM's memory, in either form Proxmox writes it
VMID=999
qm() { printf '%s\n' "${QMCONF[@]}"; }
QMCONF=("memory: 8192" "balloon: 0")
check "an older Venera VM: no balloon device, 8192 MB" 'no_balloon && [ "$(vm_memory)" = 8192 ]'
QMCONF=("memory: current=16384,max=32768")
check "memory as current=...: its current size; the balloon on by default" '! no_balloon && [ "$(vm_memory)" = 16384 ]'
QMCONF=("balloon: 8192")
check "no memory line: Proxmox's default 2048" '! no_balloon && [ "$(vm_memory)" = 2048 ]'
unset -f qm
rm -rf "$W" "$CFG"
[ $fail = 0 ] && echo "all passed"
exit $fail
