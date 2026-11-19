# fold.py IN.ll OUT.ll: a PROTOTYPE (round 16) of folding a specialized AIR text before translation: literal comparisons
# (at the type's width) and boolean ops, branches on them, blocks nothing reaches, phi entries from edges that are
# gone, single-entry phis, and functions nothing reachable calls. Prints sizes. On WindowServer's uber shader it made
# translation 2.7-9.5x faster with the same computation (notes/PLAN.md, round 16); the real one belongs in the
# translator, after its specialization (fc_air_specialize.rs).
# Debugging: NOFUNC=1 keeps every function, FOLD_ONLY=i,j folds only those (by order), FOLD_LOG=1 says each decision.
import os
import re, sys

src = open(sys.argv[1]).read()
lines = src.split('\n')

# split into top-level chunks: functions (define ... { ... }) and everything else
funcs = []   # (start, end) line indexes, inclusive
i = 0
while i < len(lines):
    if lines[i].startswith('define '):
        j = i
        while lines[j] != '}':
            j += 1
        funcs.append((i, j))
        i = j + 1
    else:
        i += 1

LABEL = re.compile(r'^([A-Za-z0-9_.$\-]+|"[^"]+"):')
def fname(l):
    m = re.search(r'@("[^"]+"|[A-Za-z0-9_.$\-]+)\(', l)
    return m.group(1)

def lit_int(t):
    if t == 'true': return 1
    if t == 'false': return 0
    if re.fullmatch(r'-?\d+', t): return int(t)
    return None

ICMP = {'eq': lambda a, b: a == b, 'ne': lambda a, b: a != b,
        'sgt': lambda a, b: a > b, 'sge': lambda a, b: a >= b, 'slt': lambda a, b: a < b, 'sle': lambda a, b: a <= b,
        'ugt': lambda a, b: a > b, 'uge': lambda a, b: a >= b, 'ult': lambda a, b: a < b, 'ule': lambda a, b: a <= b}

def fold_function(body, defline=""):
    """body: list of lines between '{' and '}'. Returns new lines."""
    # blocks
    blocks = []   # [name, [lines]]
    # an unlabeled entry block is numbered after the unnamed arguments, as LLVM numbers it
    params = defline[defline.index('('):defline.rindex(')')] if '(' in defline else ''
    nums = [int(x) for x in re.findall(r'%(\d+)(?![\w.$\-])', params)]
    cur = ['%' + str(max(nums) + 1 if nums else 0), []]
    for l in body:
        m = LABEL.match(l)
        if m:
            blocks.append(cur); cur = ['%' + m.group(1).strip('"'), [l]]
        else:
            cur[1].append(l)
    blocks.append(cur)
    if not blocks[0][1] or all(not x.strip() for x in blocks[0][1]):
        blocks = blocks[1:]
    entry = blocks[0][0]
    for _ in range(8):
        consts = {}
        changed = False
        # constant values
        for b in blocks:
            for l in b[1]:
                m = re.match(r'\s*(%[\w.$\-]+) = icmp (\w+) i(\d+) (\S+), (\S+)$', l)
                if m:
                    m = (m, m.group(1), m.group(2), int(m.group(3)), m.group(4), m.group(5))
                    _, dst, pred, bits, x, y = m
                    a, c = lit_int(consts.get(x, x)), lit_int(consts.get(y, y))
                    if a is not None and c is not None:   # the literal's bits at the type's width (i8 255 is -1)
                        mask = (1 << bits) - 1
                        a, c = a & mask, c & mask
                        if pred[0] == 's' and bits > 1:
                            a = a - (1 << bits) if a >> (bits - 1) else a
                            c = c - (1 << bits) if c >> (bits - 1) else c
                    if a is not None and c is not None and pred in ICMP:
                        consts[dst] = 'true' if ICMP[pred](a, c) else 'false'
                    continue
                m = re.match(r'\s*(%[\w.$\-]+) = (and|or|xor) i1 (\S+), (\S+)$', l)
                if m:
                    a, c = lit_int(consts.get(m.group(3), m.group(3))), lit_int(consts.get(m.group(4), m.group(4)))
                    op = m.group(2)
                    v = None
                    if a is not None and c is not None:
                        v = {'and': a & c, 'or': a | c, 'xor': a ^ c}[op]
                    elif op == 'and' and (a == 0 or c == 0): v = 0
                    elif op == 'or' and (a == 1 or c == 1): v = 1
                    if v is not None:
                        consts[m.group(1)] = 'true' if v else 'false'
                    continue
                m = re.match(r'\s*(%[\w.$\-]+) = select i1 (\S+), i1 (\S+), i1 (\S+)$', l)
                if m:
                    cnd = lit_int(consts.get(m.group(2), m.group(2)))
                    if cnd is not None:
                        v = consts.get(m.group(3 if cnd else 4), m.group(3 if cnd else 4))
                        if lit_int(v) is not None:
                            consts[m.group(1)] = v
        # branches
        for b in blocks:
            for k, l in enumerate(b[1]):
                m = re.match(r'(\s*)br i1 (\S+), label (%\S+), label (%[^\s,]+)(.*)$', l)
                if m:
                    c = lit_int(consts.get(m.group(2), m.group(2)))
                    if c is not None:
                        if os.environ.get('FOLD_LOG'):
                            dl = next((x.strip() for bb in blocks for x in bb[1] if x.strip().startswith(m.group(2) + ' = ')), m.group(2))
                            print('fold', b[0], m.group(2), '->', c, '|', dl[:140], file=sys.stderr)
                        b[1][k] = f'{m.group(1)}br label {m.group(3).rstrip(",") if c else m.group(4)}{m.group(5)}'
                        changed = True
        # reachability
        succ = {}
        for b in blocks:
            # the terminator: from the last br/switch/indirectbr line to the block's end (a switch spans lines)
            k = max((n for n, x in enumerate(b[1]) if re.match(r'\s*(br|switch|indirectbr|callbr|invoke)\b', x)), default=None)
            succ[b[0]] = re.findall(r'label (%[\w.$\-]+)', '\n'.join(b[1][k:])) if k is not None else []
        seen = {entry}; todo = [entry]
        while todo:
            n = todo.pop()
            for s in succ.get(n, []):
                if s not in seen:
                    seen.add(s); todo.append(s)
        if len(seen) < len(blocks):
            changed = True
        blocks = [b for b in blocks if b[0] in seen]
        preds = {b[0]: set() for b in blocks}
        for b in blocks:
            for s in succ[b[0]]:
                if s in preds: preds[s].add(b[0])
        # phis: drop entries from blocks that aren't predecessors any more
        for b in blocks:
            for k, l in enumerate(b[1]):
                m = re.match(r'(\s*%[\w.$\-]+ = phi [^\[]+?)\s(\[.*\])(.*)$', l)
                if m:
                    ents = re.findall(r'\[ ([^\]]+?), (%[\w.$\-]+) \]', m.group(2))
                    keep = [(v, p) for v, p in ents if p in preds[b[0]]]
                    if len(keep) != len(ents):
                        b[1][k] = m.group(1) + ' ' + ', '.join(f'[ {v}, {p} ]' for v, p in keep) + m.group(3)
                        changed = True
        # a phi left with one entry is that value
        subst = {}
        for b in blocks:
            keep = []
            for l in b[1]:
                m = re.match(r'\s*(%[\w.$\-]+) = phi [^\[]+?\s\[ ([^\]]+?), %[\w.$\-]+ \]\s*$', l)
                if m:
                    subst[m.group(1)] = m.group(2)
                else:
                    keep.append(l)
            b[1] = keep
        if subst:
            changed = True
            if os.environ.get('FOLD_LOG'):
                for kk, vv in subst.items(): print('phi1', kk, '=', vv[:80], file=sys.stderr)
            # chains: a phi's value may itself be one going away
            for k in list(subst):
                v = subst[k]
                while v in subst and subst[v] != v:
                    v = subst[v]
                subst[k] = v
            pat = re.compile(r'(%[\w.$\-]+)(?![\w.$\-])')
            for b in blocks:
                b[1] = [pat.sub(lambda mm: subst.get(mm.group(1), mm.group(1)), l) for l in b[1]]
        if not changed:
            break
    out = []
    for b in blocks:
        out.extend(b[1])
    return out

new = []
last = 0
fnames = {}
bodies = {}
for (s, e) in funcs:
    new.extend(lines[last:s])
    only = os.environ.get('FOLD_ONLY')
    fi = len(fnames)
    body = fold_function(lines[s + 1:e], lines[s]) if only is None or str(fi) in only.split(',') else lines[s + 1:e]
    fnames[fname(lines[s])] = len(new)
    new.append(lines[s]); new.extend(body); new.append('}')
    last = e + 1
new.extend(lines[last:])
text = '\n'.join(new)

# functions nothing reachable calls: keep the ones referenced outside function bodies (metadata, globals) and their callees
defs = {}
cur = None
for idx, l in enumerate(new):
    if l.startswith('define '):
        cur = fname(l); defs[cur] = [idx, None]
    elif l == '}' and cur:
        defs[cur][1] = idx; cur = None
outside = '\n'.join(l for idx, l in enumerate(new) if not any(a <= idx <= b for a, b in defs.values()))
roots = {f for f in defs if re.search(r'@' + re.escape(f) + r'\b', outside)}
live = set(roots); todo = list(roots)
while todo:
    f = todo.pop(); a, b = defs[f]
    for g in re.findall(r'@("[^"]+"|[A-Za-z0-9_.$\-]+)', '\n'.join(new[a + 1:b])):
        if g in defs and g not in live:
            live.add(g); todo.append(g)
import os
dead = set() if os.environ.get('NOFUNC') else set(defs) - live
final = [l for idx, l in enumerate(new) if not any(a <= idx <= b for f, (a, b) in defs.items() if f in dead)]
out = '\n'.join(final)
open(sys.argv[2], 'w').write(out)
print(f"{len(src)} -> {len(text)} (blocks) -> {len(out)} B; functions {len(defs)} -> {len(live)}")
