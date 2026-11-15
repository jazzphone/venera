#!/usr/bin/env python3
# kcdis: disassemble a range of a kernel collection with the kext's symbols (from kcsyms.py) on calls, jumps and
# RIP-relative operands. Vtable entries in a KC are chained fixups: the low 30 bits are the target's KC offset.
#   tools/kcdis.py SystemKernelExtensions.kc out.pkl 0xSTART 0xLENGTH
import pickle, sys, subprocess, re, bisect
segs,syms,vm0=pickle.load(open(sys.argv[2],'rb'))
kc=open(sys.argv[1],'rb').read()
addrs=[v for v,n in syms]
def name(a):
    i=bisect.bisect_right(addrs,a)-1
    if i<0: return '?'
    v,n=syms[i]; return n if v==a else '%s+0x%x'%(n,a-v)
start=int(sys.argv[3],16); length=int(sys.argv[4],16)
b=kc[start:start+length]
import tempfile; S=tempfile.mkdtemp()
open(S+'/k.s','w').write('.text\n.globl _f\n_f:\n'+''.join('.byte '+','.join(str(x) for x in b[i:i+16])+'\n' for i in range(0,len(b),16)))
subprocess.run(['xcrun','clang','-arch','x86_64','-c',S+'/k.s','-o',S+'/k.o'],check=True)
out=subprocess.run(['xcrun','llvm-objdump','-d','--no-show-raw-insn',S+'/k.o'],capture_output=True,text=True).stdout
for l in out.splitlines():
    m=re.match(r'\s*([0-9a-f]+):\s*(.*)',l)
    if not m: continue
    a=int(m.group(1),16)+start; ins=m.group(2)
    def fix(mm):
        t=int(mm.group(1),16)+start
        return '<%s>'%name(t)
    ins=re.sub(r'<_f\+0x([0-9a-f]+)>',fix,ins)
    mc=re.match(r'(callq|jmp|j[a-z]+)\s+0x([0-9a-f]+)',ins)
    if mc:
        t=(int(mc.group(2),16)+start)&0xffffffffffffffff
        ins='%s %s <%s>'%(mc.group(1),hex(t),name(t))
    m2=re.search(r'## 0x([0-9a-f]+)',ins)
    if m2 and 'rip' in ins:
        ins=re.sub(r'## 0x[0-9a-f]+.*','## '+name(int(m2.group(1),16)+start),ins)
    print(hex(a),ins)
