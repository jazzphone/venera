#!/usr/bin/env python3
# check-vtables: do the vtables clang lays out for our kexts' classes agree, slot by slot, with the real ones in a
# macOS kernel collection? Our classes subclass Apple's (IOAccel's from NullMoth's reconstructed headers, the rest from
# the SDK), and vendor/nullmoth/accel/vg_tahoe_fwd.h jumps through Apple's vtables at fixed offsets; a macOS update
# that moves a slot breaks either one silently.
#
#   tools/check-vtables.py --kc BootKernelExtensions.kc --kc SystemKernelExtensions.kc [--kext NAME] [--show CLASS]
#                          [--class CLASS] [--strict]
#
# Each kext's sources are compiled as tools/build.sh compiles them (its flags are read from build.sh), with
# -fdump-vtable-layouts and to assembly: the emitted vtables give each slot's mangled symbol. A probe class derived
# from each base (`__vtcheck_probe_B`, one marker virtual at the end) gives the header's own length of the base's
# vtable. Each class of ours is compared with its direct base's real vtable in the KCs given, or with the nearest
# ancestor found there (PARTIAL). The KCs are read only: copy them out of the guest (/System/Library/KernelCollections,
# both Boot and System: IOAcceleratorFamily2 and AppleGraphicsDeviceControl are in the System KC).
# Without --kc only the KC-free checks run: every forwarder in vg_tahoe_fwd.h jumps through the slot clang gives the
# method it forwards.
# A slot is ok when Apple's symbol there has our method's name and parameters (destructors by kind, any of a folded
# function's names); `signature` (same name, other parameter types) and `reserved` (Apple uses a slot the header
# keeps as _RESERVED) are listed but fail only with --strict; `unverified` slots (Apple's has no symbol, or is pure)
# are counted, and listed with --show. --class CLASS checks a header class we only call into, the same way.
# Exit status: 0 all checked slots match, 1 a mismatch, 2 an error.
# The idea (clang's layout against the KC's, slot by slot) follows RX4Darwin's tools/metal/m0/check-vtable.py; no code
# of it is used here.
import argparse, bisect, collections, mmap, os, re, shlex, struct, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = '__vtcheck_probe_'
END = '__vtcheck_end'


def die(msg):
    print('check-vtables: ' + msg, file=sys.stderr)
    sys.exit(2)


# ---- our side: compile as tools/build.sh does -------------------------------------------------------------------

def build_config():
    """Flags, kexts and extra sources from tools/build.sh, so the check sees the headers the build does."""
    text = open(os.path.join(ROOT, 'tools/build.sh')).read()
    sdk = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], capture_output=True, text=True,
                         check=True).stdout.strip()

    def arr(src):
        return shlex.split(src.replace('$SDK', sdk).replace('\\\n', ' '))
    m = re.search(r'^COMMON=\((.*?)\)\s*$', text, re.S | re.M)
    c = re.search(r'^CXXFLAGS=\(\$COMMON(.*?)\)', text, re.M)
    k = re.search(r'^for NAME in ([\w ]+); do', text, re.M)
    if not (m and c and k):
        die('tools/build.sh changed shape (COMMON, CXXFLAGS or the kext loop not found): update build_config()')
    extra = {n: arr(a) for n, a in re.findall(r'\[\[ \$NAME == (\w+) \]\] && EXTRA=\((.*?)\)', text)}
    srcs = {n: arr(a) for n, a in re.findall(r'\[\[ \$NAME == (\w+) \]\] && SRCS\+=\((.*?)\)', text)}
    return arr(m.group(1)) + arr(c.group(1)), k.group(1).split(), extra, srcs


def our_classes(path):
    """class NAME : public BASE declared in one of our sources (the classes whose vtables we emit)."""
    return dict(re.findall(r'^\s*class\s+(\w+)\s*(?:final\s*)?:\s*public\s+(\w+)', open(path).read(), re.M))


def parse_asm(s):
    """Each vtable emitted in the assembly: class -> its primary function slots (mangled), up to the kext's 0."""
    out = {}
    lines = s.splitlines()
    for i, line in enumerate(lines):
        m = re.match(r'^(__ZTV\w+):$', line)
        if not m:
            continue
        cls = demangle_vtable(m.group(1))
        quads = []
        for l in lines[i + 1:]:
            q = re.match(r'^\s+\.quad\s+(\S+)', l)
            if not q:
                break
            quads.append(q.group(1))
        slots = []
        for q in quads[2:]:   # offset to top, RTTI
            if q == '0':
                break
            slots.append(q)
        if cls:
            out[cls] = slots
    return out


def demangle_vtable(sym):
    m = re.match(r'^__ZTV(\d+)(\w+)$', sym)
    if not m or len(m.group(2)) != int(m.group(1)):
        return None   # nested (MetaClass) or templated
    return m.group(2)


def parse_dump(text):
    """clang's -fdump-vtable-layouts: class -> (its primary bases, {slot: printed signature})."""
    out = {}
    cur = None
    for line in text.splitlines():
        m = re.match(r"^Vtable for '([\w:]+)' \(\d+ entries\)\.", line)
        if m:
            cur = m.group(1)
            out[cur] = (set(), {})
            continue
        if cur is None:
            continue
        if not line.strip():
            cur = None
            continue
        b = re.match(r'^\s+-- \((\w+), 0\) vtable address --', line)
        if b:
            out[cur][0].add(b.group(1))
        e = re.match(r'^\s*(\d+) \| (.*)$', line)
        if e and int(e.group(1)) >= 2:
            out[cur][1][int(e.group(1)) - 2] = e.group(2)
    return out


def compile_tu(flags, src, probes, work):
    """Compile src with a probe per class in probes; drop the probes clang refuses (and retry)."""
    probes = set(probes)
    for _ in range(8):
        tu = os.path.join(work, 'tu.cpp')
        with open(tu, 'w') as f:
            f.write('#include "%s"\n' % src)
            for b in sorted(probes):
                f.write('struct %s%s final : %s { virtual void %s(); };\nvoid %s%s::%s() {}\n'
                        % (PROBE, b, b, END, PROBE, b, END))
        asm = os.path.join(work, 'tu.s')
        r = subprocess.run(['xcrun', 'clang++'] + flags + ['-w', '-Xclang', '-fdump-vtable-layouts', '-S', '-o', asm,
                           tu], capture_output=True, text=True, cwd=ROOT)
        if r.returncode == 0:
            return open(asm).read(), r.stdout, probes
        bad = set(re.findall(PROBE + r'(\w+)', r.stderr)) & probes
        if not bad:
            die('clang failed on %s:\n%s' % (src, r.stderr[-3000:]))
        probes -= bad
    die('clang kept failing on the probes for ' + src)


def forwarders(flags):
    """vg_tahoe_fwd.h's naked forwarders: (class, method, arity, base, slot), when the build defines NM_TAHOE."""
    if '-DNM_TAHOE' not in flags:
        return []
    out = []
    for d in [f[2:] for f in flags if f.startswith('-I') and not f.startswith('-I/')]:
        p = os.path.join(ROOT, d, 'vg_tahoe_fwd.h')
        if not os.path.exists(p):
            continue
        for m in re.finditer(r'\b(\w+)::(\w+)\(([^)]*)\)[^{]*\{ __asm__\("movq __ZTV\d+(\w+)@GOTPCREL\(%rip\), %r11'
                             r'\\n\\tjmpq \*(\d+)\(%r11\)', open(p).read()):
            cls, meth, params, base, off = m.groups()
            out.append((cls, meth, arity(params), base, int(off) // 8 - 2))
    return out


# ---- names ------------------------------------------------------------------------------------------------------

_dm = {}


def demangle(names):
    todo = sorted({n for n in names if n not in _dm})
    if todo:
        r = subprocess.run(['xcrun', 'c++filt'], input='\n'.join(n[1:] if n.startswith('__Z') else n for n in todo),
                           capture_output=True, text=True, check=True)
        for n, d in zip(todo, r.stdout.splitlines()):
            _dm[n] = d
    return [_dm.get(n, n) for n in names]


def split(sig):
    """'A::b(int) const' -> ('A', 'b', '(int) const'); a destructor's name is '~'."""
    p = sig.find('(')
    if p < 0:
        return '', sig, ''
    head, rest = sig[:p], sig[p:]
    qual, _, name = head.rpartition('::')
    qual = qual.split(' ')[-1].lstrip('*&')   # a printed return type, in the dump's form
    return qual, ('~' if name.startswith('~') else name), rest


def arity(params):
    params = params.strip()
    if params.startswith('('):
        params = params[1:params.rfind(')')]
    if params in ('', 'void'):
        return 0
    depth, n = 0, 1
    for ch in params:
        depth += ch in '<('
        depth -= ch in '>)'
        n += ch == ',' and depth == 0
    return n


# ---- Apple's side: a kernel collection --------------------------------------------------------------------------

class KC:
    """An x86_64 kernel collection (MH_FILESET): its entries' symbols and its vtable slots (plain pointers or
    chained fixups: the low 30 bits a target's offset from its collection's base, bits 30-31 which collection)."""

    def __init__(self, path):
        self.path = path
        f = open(path, 'rb')
        self.d = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        magic, cpu, _, ftype, ncmds = struct.unpack_from('<IiiII', self.d, 0)
        if magic != 0xfeedfacf or cpu != 0x01000007 or ftype != 12:
            die('%s is not an x86_64 kernel collection (MH_FILESET)' % path)
        self.entries, self.segs = {}, []
        for cmd, p, cs in self._lcs(0):
            if cmd == 0x80000035:   # LC_FILESET_ENTRY
                vm, fo, eid = struct.unpack_from('<QQI', self.d, p + 8)
                self.entries[self._cstr(p + eid)] = (vm, fo)
            elif cmd == 0x19:
                self.segs.append(struct.unpack_from('<QQQQ', self.d, p + 24))   # vmaddr, vmsize, fileoff, filesize
        self.base = min(s[0] for s in self.segs)
        name = os.path.basename(path).lower()
        self.level = 0 if 'com.apple.kernel' in self.entries else 2 if 'aux' in name else 1
        self.sym = {}                          # name -> (address, entry)
        self.at = collections.defaultdict(list)   # address -> names (identical code folding gives several)
        for e, (vm, fo) in self.entries.items():
            for cmd, p, cs in self._lcs(fo):
                if cmd == 2:   # LC_SYMTAB
                    symoff, nsyms, stroff = struct.unpack_from('<III', self.d, p + 8)
                    for i in range(nsyms):
                        strx, typ, sect, desc, val = struct.unpack_from('<IBBHQ', self.d, symoff + 16 * i)
                        if typ & 0x0e == 0x0e and val:
                            n = self._cstr(stroff + strx)
                            self.sym.setdefault(n, (val, e))
                            self.at[val].append(n)
        self.ends = sorted(self.at)

    def _lcs(self, off):
        ncmds = struct.unpack_from('<I', self.d, off + 16)[0]
        p = off + 32
        for _ in range(ncmds):
            cmd, cs = struct.unpack_from('<II', self.d, p)
            yield cmd, p, cs
            p += cs

    def _cstr(self, off):
        return self.d[off:self.d.find(b'\0', off)].decode('latin1')

    def off(self, va):
        for vm, vs, fo, fs in self.segs:
            if vm <= va < vm + fs:
                return fo + va - vm
        return None

    def describe(self):
        kind = {0: 'Boot', 1: 'System', 2: 'Auxiliary'}[self.level]
        builds = collections.Counter(re.findall(rb'<key>DTPlatformBuild</key>\s*<string>(\w+)</string>', self.d))
        build = builds.most_common(1)[0][0].decode() if builds else '?'
        k = re.search(rb'Darwin Kernel Version ([\d.]+)', self.d)
        return '%s (%s KC, %d entries, kexts built for %s%s)' % (
            self.path, kind, len(self.entries), build, ', Darwin %s' % k.group(1).decode() if k else '')


class KCs:
    def __init__(self, paths):
        self.kcs = [KC(p) for p in paths]
        self.by_level = {k.level: k for k in self.kcs}

    def vtable(self, cls):
        """The real vtable of cls: (its function slots as lists of names, the KC and entry), or None."""
        sym = '__ZTV%d%s' % (len(cls), cls)
        for k in self.kcs:
            if sym not in k.sym:
                continue
            va, entry = k.sym[sym]
            o = k.off(va)
            nxt = next(iter(k.ends[bisect.bisect_right(k.ends, va):]), None)
            slots = []
            i = 2
            while True:
                if nxt is not None and va + 8 * i >= nxt:
                    break
                v = struct.unpack_from('<Q', k.d, o + 8 * i)[0]
                if v == 0:
                    break
                t = self.target(k, v)
                if t is None:
                    break
                slots.append(t)
                i += 1
            return slots, k, entry
        return None

    def target(self, k, v):
        """Names at the function a slot points to ([] when stripped), or None when it isn't a pointer."""
        if v >> 40 == 0xffffff:   # a plain kernel address
            for kk in self.kcs:
                if kk.off(v) is not None and kk.base <= v:
                    return kk.at.get(v, [])
            return None
        level, t = (v >> 30) & 3, v & 0x3fffffff
        kk = self.by_level.get(level)
        if kk is None:
            return ['<in the %s KC, not given>' % {0: 'Boot', 1: 'System', 2: 'Auxiliary'}.get(level, '?')]
        return kk.at.get(kk.base + t, [])


# ---- the comparison ---------------------------------------------------------------------------------------------

def compare(ours, dumpnames, real, upto):
    """Slot by slot over [0, upto): (slot, verdict, our signature, Apple's names). verdict: ok, mismatch,
    signature (same name, other parameters), reserved (Apple uses a slot the header reserves), unverified."""
    rows = []
    for i in range(upto):
        mine = ours[i] if i < len(ours) else None
        theirs = real[i] if i < len(real) else None
        if mine is None or theirs is None:
            rows.append((i, 'mismatch', demangle([mine])[0] if mine else '<none>',
                         demangle(theirs) if theirs else ['<none>']))
            continue
        pure = mine == '___cxa_pure_virtual'
        msig = dumpnames.get(i, '?') if pure else demangle([mine])[0]
        tsigs = demangle(theirs)
        if not theirs or theirs[0].startswith('<') or theirs == ['___cxa_pure_virtual']:
            rows.append((i, 'unverified', msig, tsigs or ['<no symbol>']))
            continue
        _, mname, mrest = split(msig)
        tsplit = [split(t) for t in tsigs]
        if pure:   # the dump's sugared types: the name and the count of parameters
            same = [t for t in tsplit if t[1] == mname and arity(t[2]) == arity(mrest)]
            rows.append((i, 'ok' if same else 'mismatch', msig, tsigs))
            continue
        if any(t[1] == mname and t[2] == mrest for t in tsplit):
            rows.append((i, 'ok', msig, tsigs))
        elif any(t[1] == mname for t in tsplit):
            rows.append((i, 'signature', msig, tsigs))
        elif mname.startswith('_RESERVED'):
            rows.append((i, 'reserved', msig, tsigs))
        else:
            rows.append((i, 'mismatch', msig, tsigs))
    return rows


def main():
    ap = argparse.ArgumentParser(description='Compare our kexts\' vtable layouts with a macOS kernel collection.')
    ap.add_argument('--kc', action='append', default=[], help='a kernel collection (repeat: Boot, System, Aux)')
    ap.add_argument('--kext', action='append', help='only this kext (as named in tools/build.sh); repeatable')
    ap.add_argument('--class', dest='extra', action='append', default=[],
                    help='also check a header class we only call into (its header layout against the real one)')
    ap.add_argument('--show', action='append', default=[], help='print every slot of this class')
    ap.add_argument('--strict', action='store_true',
                    help='count signature and reserved-slot differences as mismatches')
    a = ap.parse_args()

    flags, kexts, extra, srcs = build_config()
    for k in a.kext or []:
        if k not in kexts:
            die('no kext %s in tools/build.sh (%s)' % (k, ' '.join(kexts)))
    kcs = KCs(a.kc) if a.kc else None
    if kcs:
        for k in kcs.kcs:
            print('KC: ' + k.describe())
        if len({k.level for k in kcs.kcs}) != len(kcs.kcs):
            die('two KCs of the same kind given')
    else:
        print('No --kc: only the KC-free checks (forwarders against clang\'s layout).')
    bad_levels = ('mismatch', 'signature', 'reserved') if a.strict else ('mismatch',)
    failures = 0
    tmp = tempfile.TemporaryDirectory(prefix='check-vtables-')
    work = tmp.name

    for kext in a.kext or kexts:
        kflags = flags + extra.get(kext, [])
        files = sorted(os.path.join('kext', kext, f) for f in os.listdir(os.path.join(ROOT, 'kext', kext))
                       if f.endswith('.cpp')) + srcs.get(kext, [])
        print('\n%s' % kext)
        declared, done = {}, set()
        for f in os.listdir(os.path.join(ROOT, 'kext', kext)):
            if f.endswith(('.cpp', '.hpp', '.h')):
                declared.update(our_classes(os.path.join(ROOT, 'kext', kext, f)))
        for src in files:
            text = open(os.path.join(ROOT, src)).read()
            mine = {c: b for c, b in declared.items()
                    if re.search(r'OSDefineMetaClassAndStructors\(\s*%s\s*,' % c, text)}
            extra_here = [b for b in a.extra if b not in done]
            if not mine and not extra_here:
                continue
            asm, dump, _ = compile_tu(kflags, os.path.join(ROOT, src), [], work)
            layouts = parse_dump(dump)
            probes = set(mine.values()) | set(extra_here)
            for c in mine:
                probes |= layouts.get(c, (set(), {}))[0] - {c, 'OSMetaClassBase'}
            asked = set(probes)
            asm, dump, probes = compile_tu(kflags, os.path.join(ROOT, src), probes, work)
            vt, layouts = parse_asm(asm), parse_dump(dump)
            hdr_len = {}
            for b in probes:
                s = vt.get(PROBE + b, [])
                if s and END in demangle([s[-1]])[0]:
                    hdr_len[b] = len(s) - 1
            subjects = [(c, mine[c], vt[c], c) for c in sorted(mine) if c in vt]
            subjects += [(b, b, vt[PROBE + b][:hdr_len[b]], PROBE + b) for b in extra_here if b in hdr_len]
            done |= {b for b in extra_here if b in hdr_len}
            print('  %s' % src)
            for b in sorted(asked - set(hdr_len)):
                if b not in extra_here or b in mine.values():
                    print('    (no header layout for %s: clang refused its probe class)' % b)
            for name, base, slots, key in subjects:
                bases, dnames = layouts.get(key, (set(), {}))
                cands = [base] + sorted(bases - {base, name, key, 'OSMetaClassBase'}, key=lambda b: -hdr_len.get(b, 0))
                label = '%s : %s' % (name, base) if name != base else '%s (header class)' % name
                ref = None
                if kcs:
                    for b in cands:
                        r = kcs.vtable(b)
                        if r and b in hdr_len:
                            ref = (b, r)
                            break
                if not ref:
                    why = 'no KC given' if not kcs else 'no vtable of it or an ancestor in the KCs given'
                    print('    %-62s NOT CHECKED (%s; ours %d slots)' % (label, why, len(slots)))
                    continue
                b, (real, k, entry) = ref
                n = hdr_len[b]
                rows = compare(slots, dnames, real, max(n, len(real)))
                counts = collections.Counter(v for _, v, _, _ in rows)
                bad = [r for r in rows if r[1] in bad_levels]
                state = 'MISMATCH' if bad else 'OK' if b == base else 'PARTIAL'
                failures += bool(bad)
                note = '%d slots against %s (%s)' % (len(rows), b, entry)
                if b != base:
                    note += '; %s %s' % (base, 'has no header layout' if kcs.vtable(base) else 'not in the KCs given')
                if n != len(real):
                    note += '; header %d slots, Apple %d' % (n, len(real))
                extras = ', '.join('%d %s' % (counts[v], v) for v in ('signature', 'reserved', 'unverified')
                                   if counts[v])
                own = len(slots) - n if name != base and b == base else 0
                print('    %-62s %-8s %s%s%s' % (label, state, note, '; ' + extras if extras else '',
                                                  '; %d of its own' % own if own > 0 else ''))
                for i, v, m, t in rows:   # the differences (unverified ones with --show), every slot with --show
                    if v != 'ok' and (v != 'unverified' or name in a.show):
                        print('      slot %3d (+0x%03x) %-10s ours %s\n%37s Apple %s'
                              % (i, 16 + 8 * i, v, m, '', ' = '.join(t)))
                    elif name in a.show:
                        print('      slot %3d (+0x%03x) %-10s %s' % (i, 16 + 8 * i, v, m))
            # the forwarders: each one's slot is clang's slot for the method, and Apple's method there
            fw = [f for f in forwarders(kflags) if f[0] in mine]
            if fw:
                wrong, real_ok, real_bad, unchecked, nosym = [], 0, [], 0, 0
                for cls, meth, ar, base, slot in fw:
                    s = vt.get(cls, [])
                    got = demangle([s[slot]])[0] if slot < len(s) else '<none>'
                    q, gname, grest = split(got)
                    if not (q == cls and gname == meth and arity(grest) == ar):
                        wrong.append('%s::%s at slot %d (+%d of %s), clang has %s there'
                                     % (cls, meth, slot, 16 + 8 * slot, base, got))
                    r = kcs.vtable(base) if kcs else None
                    if not r:
                        unchecked += 1
                        continue
                    t = demangle(r[0][slot]) if slot < len(r[0]) else ['<none>']
                    if not t or t[0].startswith('<in the'):
                        nosym += 1
                    elif any(split(x)[1] == meth and arity(split(x)[2]) == ar for x in t):
                        real_ok += 1
                    else:
                        real_bad.append('%s::%s jumps through %s slot %d (+%d): Apple has %s'
                                        % (cls, meth, base, slot, 16 + 8 * slot, ' = '.join(t) or '<no symbol>'))
                print('    forwarders (vg_tahoe_fwd.h): %d; %d at clang\'s slot; Apple\'s method there: %d, %d other, '
                      '%d no symbol, %d not checked (base not in the KCs given)'
                      % (len(fw), len(fw) - len(wrong), real_ok, len(real_bad), nosym, unchecked))
                for w in wrong + real_bad:
                    print('      MISMATCH ' + w)
                failures += bool(wrong or real_bad)
        for b in a.extra:
            if b not in done:
                print('  --class %s: not a class this kext\'s sources can see' % b)
    print('\n%s' % ('%d mismatching item(s)' % failures if failures else 'No mismatches in the slots checked.'))
    tmp.cleanup()
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
