#!/usr/bin/env python3
# config.py SAMPLE OUT: OpenCore's config.plist for a macOS VM on Proxmox (QEMU q35, OVMF), made from OpenCore's own
# Docs/Sample.plist (the release's, BSD-3) and the settings below. Each one is what a VM needs, or what the old image
# (thenickdude's KVM-Opencore v21) set and our VMs still use; nothing else changes from the sample.
# The VM script fills in the rest per VM: the screen size, boot-args, SIP, the Mac identity and a fresh SystemUUID.
import plistlib, sys

c = plistlib.load(open(sys.argv[1], 'rb'))

def entries(section, key, keep):
    """Keeps (enabled) only the entries of a list that `keep` names, in that order; drops the rest."""
    have = {e.get('Path') or e.get('BundlePath'): e for e in c[section][key]}
    out = []
    for name in keep:
        if name in have:
            e = dict(have[name])
        else:   # not in the sample: an entry of the same shape as its first (every key this version wants)
            e = dict(c[section][key][0])
            for k, v in e.items():
                e[k] = '' if isinstance(v, str) else False if isinstance(v, bool) else v
            e['Path' if 'Path' in e else 'BundlePath'] = name
        e['Enabled'] = True
        out.append(e)
    c[section][key] = out
    return out

# ACPI: Venera's one table (SSDT-VENERA.dsl): an EC device, the USB power properties, the CPU's XCPM plugin-type
entries('ACPI', 'Add', ['SSDT-VENERA.aml'])
c['ACPI']['Add'][0]['Comment'] = 'Venera: EC, USBX, plugin-type on QEMU\'s C000'

c['ACPI']['Patch'] = []

# Booter: OVMF runs without a virtual memory map of OpenCore's making
c['Booter']['Quirks']['SetupVirtualMap'] = False

# Device properties: none (the sample's are for real Macs' audio and graphics)
c['DeviceProperties']['Add'] = {}

# Kernel: Lilu and VirtualSMC (a full SMC: QEMU's applesmc has only the keys macOS needs to boot and can't list them,
# and PerfPowerServices asked it for every key by index, spinning a core for good), then VeneraHide (the VM hidden
# from kern.hv_vmm_present: Apple Account sign-in); Venera's installer adds its own kexts later. The CPU reported as
# a Skylake-SP Xeon (an iMac Pro's) whatever the host's, and its power management faked: macOS knows neither the newer
# Intel CPUs a host may have, nor a VM's.
def kext(name, comment):
    return {'Arch': 'x86_64', 'BundlePath': name + '.kext', 'Comment': comment, 'Enabled': True,
            'ExecutablePath': 'Contents/MacOS/' + name, 'MaxKernel': '', 'MinKernel': '', 'PlistPath': 'Contents/Info.plist'}
add = [kext('Lilu', "acidanthera's Lilu (VirtualSMC needs it)"),
       kext('VirtualSMC', "acidanthera's VirtualSMC: a full SMC for macOS")]
add += [{'Arch': 'x86_64', 'BundlePath': 'VeneraHide.kext', 'Comment': 'Venera: the VM hidden from kern.hv_vmm_present',
        'Enabled': True, 'ExecutablePath': 'Contents/MacOS/VeneraHide', 'MaxKernel': '', 'MinKernel': '',
        'PlistPath': 'Contents/Info.plist'}]
c['Kernel']['Add'] = add
c['Kernel']['Block'] = []
c['Kernel']['Patch'] = []
emu = c['Kernel']['Emulate']
emu['Cpuid1Data'] = bytes.fromhex('54060500000000000000000000000000')
emu['Cpuid1Mask'] = bytes.fromhex('ffffff00000000000000000000000000')
emu['DummyPowerManagement'] = True
q = c['Kernel']['Quirks']
q['ProvideCurrentCpuInfo'] = True        # the TSC and bus frequencies from the hypervisor, not a table
q['ForceSecureBootScheme'] = True
q['SetApfsTrimTimeout'] = 0              # a virtual disk's TRIM: don't (it crawls over iSCSI)
q['DisableLinkeditJettison'] = True

# Misc: the text picker (no OpenCanopy, no Resources folder), auxiliary entries shown (Reset NVRAM), no hot keys (a
# Shift stuck in noVNC made every boot a Safe boot), the default boot entry settable (Ctrl+Enter)
b = c['Misc']['Boot']
b['PickerMode'] = 'Builtin'
b['HideAuxiliary'] = False
b['PollAppleHotKeys'] = False
b['ShowPicker'] = True
b['Timeout'] = 5
b['HibernateMode'] = 'None'
c['Misc']['Debug']['Target'] = 3
c['Misc']['Entries'] = []
c['Misc']['Tools'] = []
s = c['Misc']['Security']
# APFS and HFS+ only (macOS, its installer and recovery; not OpenCore's own FAT disk, which listed as an entry and was
# booted by default), on SATA, SAS, SCSI, NVMe, ATAPI, USB and PCI (virtio) devices; the two lock bits as OpenCore's
s['ScanPolicy'] = 0x0001 | 0x0002 | 0x0100 | 0x0200 | 0x013F0000
s['SecureBootModel'] = 'Disabled'        # Venera's kexts and its relaxed SIP
s['Vault'] = 'Optional'
s['AllowSetDefault'] = True
s['ExposeSensitiveData'] = 6

# NVRAM: no verbose boot, SIP on until the VM script or Venera's installer says otherwise, an English keyboard
nv = c['NVRAM']['Add']['7C436110-AB2A-4BBB-A880-FE41995C9F82']
nv['boot-args'] = 'keepsyms=1'
nv['csr-active-config'] = bytes(4)
nv['prev-lang:kbd'] = b'en-US:0'
nv.pop('#INFO (prev-lang:kbd)', None)
for k in ('boot-args', 'csr-active-config'):
    d = c['NVRAM']['Delete'].setdefault('7C436110-AB2A-4BBB-A880-FE41995C9F82', [])
    if k not in d:
        d.append(k)
c['NVRAM']['WriteFlash'] = True

# PlatformInfo: a model macOS Tahoe installs on, OpenCore's sample serial (no iCloud until the owner's own identity)
pi = c['PlatformInfo']
pi['Automatic'] = True
pi['UpdateSMBIOSMode'] = 'Create'
pi['Generic']['SystemProductName'] = 'iMac20,1'

# UEFI: HFS+ (the installer and the recovery), partitions OVMF doesn't know, Reset NVRAM; any APFS driver version; no
# audio; requests for Apple's boot variables routed to OpenCore's (macOS's "startup disk" choices land there)
entries('UEFI', 'Drivers', ['OpenRuntime.efi', 'OpenHfsPlus.efi', 'OpenPartitionDxe.efi', 'ResetNvramEntry.efi'])
c['UEFI']['APFS']['MinDate'] = -1
c['UEFI']['APFS']['MinVersion'] = -1
c['UEFI']['Audio']['AudioSupport'] = False
c['UEFI']['Audio']['AudioDevice'] = ''
c['UEFI']['Output']['Resolution'] = 'Max'
c['UEFI']['Quirks']['RequestBootVarRouting'] = True
c['UEFI']['Quirks']['EnableVectorAcceleration'] = True

plistlib.dump(c, open(sys.argv[2], 'wb'))
