import struct, collections, sys
b=open(sys.argv[1],"rb").read()
n=struct.unpack_from("<Q",b,8)[0]; o=16
cat={}
for i in range(n):
    h,base,res=struct.unpack_from("<IIQ",b,o); o+=16
    o+=28; lc=b[o]; nl=b[o+1]; o+=2+nl
    cat.setdefault(h,lc)
e=open(sys.argv[2],"rb").read()
m=struct.unpack_from("<Q",e,8)[0]
arch=collections.Counter()
for i in range(m): arch[struct.unpack_from("<I",e,16+i*52+44)[0]]+=1
miss=[(c,a) for a,c in arch.items() if a not in cat]; miss.sort(reverse=True)
print("entities",m,"archetypes",len(arch),"missing archetypes",len(miss),"entities without model",sum(c for c,a in miss))
print("top", [(hex(a),c) for c,a in miss[:8]])
