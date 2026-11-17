#!/bin/bash
# test-install-host (in the container): install-host.sh against fake VMs, every mode, checking each VM's args.
set -u
. /test/shims.sh
cd /work/Venera-host-*/ || exit 1
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
args() { sed -n 's/^args: //p' /etc/pve/qemu-server/$1.conf; }
DEV108="-chardev socket,path=/run/venera-video-108.sock,id=vvideo -device ivshmem-doorbell,chardev=vvideo,vectors=1"
printf 'args: -cpu host,vendor=GenuineIntel -smbios type=2\ncores: 4\nmemory: 8192\n' >/etc/pve/qemu-server/108.conf
printf 'cores: 2\nmemory: 4096\n' >/etc/pve/qemu-server/109.conf
printf 'cores: 1\n' >/etc/pve/qemu-server/200.conf
cp /etc/pve/qemu-server/200.conf /tmp/200.before

./install-host.sh --dry-run --vm 108 >/tmp/dry.log 2>&1
check "dry run changes nothing" '[ "$(args 108)" = "-cpu host,vendor=GenuineIntel -smbios type=2" ] && [ ! -e /opt/venera ] && [ ! -e /var/log/shim/apt ]'
./install-host.sh --vm 108 >/tmp/i1.log 2>&1; echo "install exit $?"
check "108 gains its device" '[ "$(args 108)" = "-cpu host,vendor=GenuineIntel -smbios type=2 $DEV108" ]'
check "only the missing package installed" '[ "$(cat /var/log/shim/apt)" = "apt-get install -y intel-media-va-driver" ]'
check "state records it" 'grep -qx "apt_installed=intel-media-va-driver" /opt/venera/state'
check "program and unit in place" '[ -x /opt/venera/video/bin/venera-videod ] && [ -e /etc/systemd/system/venera-videod@.service ] && [ -e /var/log/shim/enabled.venera-videod@108.service ]'
check "config backed up" 'ls /opt/venera/backup/108.conf.* >/dev/null 2>&1'
./install-host.sh --vm 108 --vm 109 >/tmp/i2.log 2>&1
check "a second install leaves 108 alone" '[ "$(args 108)" = "-cpu host,vendor=GenuineIntel -smbios type=2 $DEV108" ] && grep -q "VM 108: has its video device already" /tmp/i2.log'
check "109 (no args line) gains one" '[ "$(args 109)" = "${DEV108//108/109}" ]'
check "no second apt install" '[ "$(grep -c install /var/log/shim/apt)" = 1 ]'
./install-host.sh --status >/tmp/st.log 2>&1
check "status lists both VMs" 'grep -q "VM 108: device" /tmp/st.log && grep -q "VM 109: device" /tmp/st.log'
./install-host.sh --remove-vm 109 >/tmp/r.log 2>&1
check "removing 109 drops its args line" '! grep -q "^args:" /etc/pve/qemu-server/109.conf && [ ! -e /var/log/shim/enabled.venera-videod@109.service ]'
./install-host.sh --vm 108 --vm 300 >/tmp/i3.log 2>&1
check "an unknown VM is refused before any change" 'grep -q "no VM 300" /tmp/i3.log && ! grep -q "systemctl" /tmp/i3.log'
./install-host.sh --uninstall >/tmp/u.log 2>&1; echo "uninstall exit $?"
check "108 back as it was" '[ "$(args 108)" = "-cpu host,vendor=GenuineIntel -smbios type=2" ]'
check "only our package removed" 'grep -q "apt-get remove -y intel-media-va-driver" /var/log/shim/apt && grep -qx libva-drm2 /var/log/shim/installed'
check "files and unit gone, backups kept" '[ ! -e /opt/venera/video ] && [ ! -e /etc/systemd/system/venera-videod@.service ] && ls /opt/venera/backup/ | grep -q 108'
check "no instance left enabled" '! ls /var/log/shim/enabled.* >/dev/null 2>&1'
check "the other VM untouched throughout" 'cmp -s /etc/pve/qemu-server/200.conf /tmp/200.before'
# a VM whose args already hold someone else's ivshmem device stays as it is
printf 'args: -chardev socket,path=/run/other.sock,id=vvideo -device ivshmem-doorbell,chardev=vvideo\n' >/etc/pve/qemu-server/110.conf
cp /etc/pve/qemu-server/110.conf /tmp/110.before
./install-host.sh --vm 110 >/tmp/i4.log 2>&1
check "a foreign video device line is refused before any change" 'grep -q "another video device" /tmp/i4.log && cmp -s /etc/pve/qemu-server/110.conf /tmp/110.before && [ ! -e /opt/venera/video ] && ! grep -q "install" /tmp/i4.log'
[ $fail = 0 ] && echo PASS || { echo FAILED; for f in /tmp/*.log; do echo "== $f"; cat $f; done; }
