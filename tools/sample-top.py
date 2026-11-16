#!/usr/bin/env python3
"""sample-top: the heaviest frames under a thread of a macOS `sample` report.
   tools/sample-top.py FILE [THREAD-SUBSTRING] [MIN-SAMPLES] [MAX-DEPTH-BELOW]"""
import re, sys, collections
f = sys.argv[1]; th = sys.argv[2] if len(sys.argv) > 2 else 'main'
lo = int(sys.argv[3]) if len(sys.argv) > 3 else 50; md = int(sys.argv[4]) if len(sys.argv) > 4 else 60
lines = open(f, errors='replace').read().split('\n')
i = next(i for i, l in enumerate(lines) if re.match(r'^\s*\d+ Thread_', l) and th.lower() in l.lower())
print(lines[i].strip()[:120])
for l in lines[i + 1:]:
    if re.match(r'^\s*\d+ Thread_', l): break
    m = re.match(r'^([\s+!:|]*)(\d+) (.*)', l)
    if not m: continue
    d = len(m.group(1)); n = int(m.group(2))
    if n >= lo and d <= md:
        name = re.sub(r"  \[0x.*", "", m.group(3))[:140]
        print('%3d %5d %s' % (d, n, name))
