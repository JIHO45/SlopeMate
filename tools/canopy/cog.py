import struct, sys, urllib.request
TYPES={1:1,2:1,3:2,4:4,5:8,7:1,11:4,12:8,16:8}
FMT={1:'B',2:'c',3:'H',4:'I',5:'II',7:'B',11:'f',12:'d',16:'Q'}
def rng(url,a,n):
    import subprocess
    return subprocess.run(['curl','-sf','-r',f'{a}-{a+n-1}',url],capture_output=True,check=True).stdout
def ifds(url):
    h=rng(url,0,1<<20)
    def val(t,c,off_or_inline):
        sz=TYPES[t]*c
        raw=off_or_inline if sz<=4 else (h[o:o+sz] if (o:=struct.unpack('<I',off_or_inline)[0])+sz<=len(h) else rng(url,o,sz))
        if t==2: return raw[:sz].decode(errors='ignore')
        f=FMT[t]; n=c*(2 if t==5 else 1)
        return list(struct.unpack('<'+f[-1]*n if t!=5 else '<'+'I'*n, raw[:sz]))
    off=struct.unpack('<I',h[4:8])[0]; out=[]
    while off:
        n=struct.unpack('<H',h[off:off+2])[0]; tags={}
        for i in range(n):
            e=h[off+2+12*i:off+14+12*i]; tag,t,c=struct.unpack('<HHI',e[:8]); tags[tag]=val(t,c,e[8:12])
        out.append(tags); off=struct.unpack('<I',h[off+2+12*n:off+6+12*n])[0]
    return out
if __name__=='__main__':
    for i,t in enumerate(ifds(sys.argv[1])):
        print(i,{k:(v if not isinstance(v,list) or len(v)<8 else f'[{len(v)}]') for k,v in t.items()})
