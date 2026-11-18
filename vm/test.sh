#!/bin/bash
# The VM script's own pieces, without a Proxmox host: the args Venera adds, a cluster node's address, and OpenCore's
# config.plist edits (against KVM-Opencore v21's own config.plist, $1). Runs anywhere with bash 4+ and python3, e.g.
#   docker run --rm --platform linux/amd64 -v ~/src:/src venera-hostvideo-build /src/macos-virtio-gpu/vm/test.sh CONFIG
set -u
CFG=${1:?the stock config.plist from OpenCore-v21.iso (EFI/OC/config.plist)}
MACOS_VM_TEST=1 . "$(dirname "$0")/proxmox-macos-vm.sh"
set +e
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
W=$(mktemp -d)

OSK='osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"'
NEW="-smbios type=2 -device qemu-xhci -cpu host,vendor=GenuineIntel,+invtsc,+hypervisor,kvm=on,vmware-cpuid-freq=on -device isa-applesmc,$OSK"
A=$(venera_args "$NEW" 1)
check "the address width goes into -cpu host" '[[ $A == *" -cpu host,host-phys-bits-limit=40,vendor=GenuineIntel,+invtsc,"* ]]'
check "Venus's three globals and the sound device" '[[ $A == *"-global virtio-vga-gl.venus=on -global virtio-vga-gl.blob=on -global virtio-vga-gl.hostmem=2G -audiodev spice,id=vsnd -device usb-audio,audiodev=vsnd" ]]'
check "the rest kept as it was" '[[ $A == "-smbios type=2 -device qemu-xhci -cpu host,"*"-device isa-applesmc,$OSK -global"* ]]'
check "a second pass adds nothing" '[ "$(venera_args "$A" 1)" = "$A" ]'
check "no sound device when not asked" '[[ $(venera_args "$NEW" 0) != *usb-audio* ]]'
V107="-smbios type=2 -cpu host,host-phys-bits-limit=40,vendor=GenuineIntel -global virtio-vga-gl.venus=on -global virtio-vga-gl.blob=on -global virtio-vga-gl.hostmem=2G -audiodev spice,id=vsnd -device usb-audio,audiodev=vsnd -chardev socket,path=/run/venera-video-107.sock,id=vvideo"
check "a VM that has it all is left alone" '[ "$(venera_args "$V107" 1)" = "$V107" ]'
check "-cpu host at the end of the line" '[ "$(venera_args "-smbios type=2 -cpu host" 0)" = "-smbios type=2 -cpu host,host-phys-bits-limit=40 -global virtio-vga-gl.venus=on -global virtio-vga-gl.blob=on -global virtio-vga-gl.hostmem=2G" ]'
O=$(venera_args "-cpu Skylake-Client" 0 2>&1 >/dev/null)
check "another -cpu is reported, not changed" '[[ $O == *"add host-phys-bits-limit=40 to it by hand"* ]] && [[ $(venera_args "-cpu Skylake-Client" 0 2>/dev/null) == "-cpu Skylake-Client -global"* ]]'

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
check "a node's address from corosync" '[ "$(COROSYNC=$W/corosync.conf node_ip pve-a)" = 192.0.2.11 ] && [ "$(COROSYNC=$W/corosync.conf node_ip pve-b)" = 192.0.2.12 ] && [ -z "$(COROSYNC=$W/corosync.conf node_ip pve-c)" ]'

ok_plist() { python3 - "$@" <<'PY'
import plistlib, sys
c = plistlib.load(open(sys.argv[1], "rb")); what = sys.argv[2]; G = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
nv, gen, add = c["NVRAM"], c["PlatformInfo"]["Generic"], [k["BundlePath"] for k in c["Kernel"]["Add"]]
s = plistlib.load(open(sys.argv[3], "rb"))
if what == "create":
    ok = (add.index("VMHide.kext") == add.index("Lilu.kext") + 1 and add.count("VMHide.kext") == 1
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
OC_RES=1920x1080 OC_ARGS="keepsyms=1 amfi_get_out_of_my_way=1" OC_CSR=03020000 MODEL=iMac20,1 SERIAL="" MLB="" ROM="" oc_config "$W/c.plist" >"$W/oc.log"
check "a new VM's OpenCore: VMHide after Lilu, the screen, SIP 0x203, AMFI, the model" 'ok_plist "$W/c.plist" create "$CFG"'
cp "$W/c.plist" "$W/c1.plist"
OC_RES=1920x1080 OC_ARGS="keepsyms=1 amfi_get_out_of_my_way=1" OC_CSR=03020000 MODEL=iMac20,1 SERIAL="" MLB="" ROM="" oc_config "$W/c.plist" >/dev/null
check "OpenCore edited twice is the same" 'python3 -c "import plistlib,sys; sys.exit(plistlib.load(open(\"$W/c.plist\",\"rb\")) != plistlib.load(open(\"$W/c1.plist\",\"rb\")))"'
check "it says what it set" 'grep -q "SIP: csr-active-config 0x203" "$W/oc.log" && grep -q "model: iMac20,1" "$W/oc.log"'
cp "$CFG" "$W/i.plist"
MODEL=iMac20,1 SERIAL=C02ABCDEFGHJ MLB=C02123456789ABCDE ROM=aa:bb:cc:dd:ee:ff oc_config "$W/i.plist" >/dev/null
check "the identity alone changes only PlatformInfo" 'ok_plist "$W/i.plist" identity "$CFG"'
cp "$CFG" "$W/w.plist"
OC_RES=1280x800 OC_ARGS="keepsyms=1 amfi_get_out_of_my_way=1" OC_CSR=030A0000 MODEL=iMac20,1 SERIAL="" oc_config "$W/w.plist" | grep -q "0xA03"
check "Safari WebGL's SIP is 0xA03" '[ $? = 0 ]'

check "a package that isn't installed is missing" '[ "$(missing_pkgs bash no-such-package-here)" = "no-such-package-here " ]'
rm -rf "$W"
[ $fail = 0 ] && echo "all passed"
exit $fail
