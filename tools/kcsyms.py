#!/usr/bin/env python3
# kcsyms: one kext's symbols out of a kernel collection (MH_FILESET), for kcdis.py. The guest's kexts live only in its
# KCs (/System/Library/KernelCollections/*.kc); copy one out over the transfer disk first.
#   tools/kcsyms.py SystemKernelExtensions.kc com.apple.iokit.IOAcceleratorFamily2 out.pkl
# KC offsets equal the kext's vmaddr (relative), so a symbol value is also the file offset of its code.
f=open(sys.argv[1],'rb'); kc=f.read()
def lcs(off):
    magic,cpu,sub,ft,ncmds,size,flags,res=struct.unpack_from('<IiiIIIII',kc,off)
    p=off+32
    for _ in range(ncmds):
        cmd,cs=struct.unpack_from('<II',kc,p); yield cmd,p,cs; p+=cs
entries={}
for cmd,p,cs in lcs(0):
    if cmd==0x80000035:
        vm,fo,eid,_=struct.unpack_from('<QQII',kc,p+8)
        name=kc[p+eid:kc.index(b'\0',p+eid)].decode(); entries[name]=(vm,fo)
want=sys.argv[2]
vm0,fo=entries[want]
segs=[];syms=[]
for cmd,p,cs in lcs(fo):
    if cmd==0x19:
        segname=kc[p+8:p+24].rstrip(b'\0').decode(); vmaddr,vmsize,fileoff,filesize=struct.unpack_from('<QQQQ',kc,p+24)
        segs.append((segname,vmaddr,vmsize,fileoff,filesize))
    if cmd==2:
        symoff,nsyms,stroff,strsize=struct.unpack_from('<IIII',kc,p+8)
        for i in range(nsyms):
            strx,typ,sect,desc,val=struct.unpack_from('<IBBHQ',kc,symoff+16*i)
            if typ&0x0e==0x0e and val:
                n=kc[stroff+strx:kc.index(b'\0',stroff+strx)].decode('latin1'); syms.append((val,n))
syms.sort()
import pickle
pickle.dump((segs,syms,vm0),open(sys.argv[3],'wb'))
print(len(syms),'symbols'); [print(s) for s in segs]
