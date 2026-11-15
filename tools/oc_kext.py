#!/usr/bin/env python3
"""Add, enable or disable a kext in an OpenCore config.plist (runs on the Proxmox host).

Usage: oc_kext.py CONFIG BUNDLE {enable|disable|status} [EXECUTABLE]
"""
import plistlib
import sys

path, bundle, action = sys.argv[1], sys.argv[2], sys.argv[3]
exe = sys.argv[4] if len(sys.argv) > 4 else bundle.removesuffix('.kext')

with open(path, 'rb') as f:
    cfg = plistlib.load(f)

if action == 'csr':
    # oc_kext.py CONFIG - csr 0x201: csr-active-config (little-endian 4 bytes), re-applied each boot
    guid = '7C436110-AB2A-4BBB-A880-FE41995C9F82'
    value = int(sys.argv[4], 16)
    cfg['NVRAM']['Add'][guid]['csr-active-config'] = value.to_bytes(4, 'little')
    deletes = cfg['NVRAM'].setdefault('Delete', {}).setdefault(guid, [])
    if 'csr-active-config' not in deletes:
        deletes.append('csr-active-config')
    with open(path + '.new', 'wb') as f:
        plistlib.dump(cfg, f)
    import os
    os.replace(path + '.new', path)
    print('csr-active-config', hex(value))
    sys.exit(0)

if action in ('nopicker', 'picker'):
    # The test VM boots straight to Macintosh HD; a picker waits forever while noVNC sends input.
    cfg['Misc']['Boot']['ShowPicker'] = action == 'picker'
    with open(path + '.new', 'wb') as f:
        plistlib.dump(cfg, f)
    import os
    os.replace(path + '.new', path)
    print('ShowPicker', cfg['Misc']['Boot']['ShowPicker'])
    sys.exit(0)

kexts = cfg['Kernel']['Add']
entry = next((k for k in kexts if k.get('BundlePath') == bundle), None)

if action == 'status':
    print(bundle, 'missing' if entry is None else ('enabled' if entry.get('Enabled') else 'disabled'))
    sys.exit(0)

if entry is None:
    entry = {
        'Arch': 'x86_64',
        'BundlePath': bundle,
        'Comment': 'macos-virtio-gpu',
        'Enabled': True,
        'ExecutablePath': f'Contents/MacOS/{exe}',
        'MaxKernel': '',
        'MinKernel': '',
        'PlistPath': 'Contents/Info.plist',
    }
    kexts.append(entry)
entry['Enabled'] = action == 'enable'

with open(path + '.new', 'wb') as f:
    plistlib.dump(cfg, f)
import os
os.replace(path + '.new', path)
print(bundle, 'enabled' if entry['Enabled'] else 'disabled')
