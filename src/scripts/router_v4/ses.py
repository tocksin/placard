import sys, uuid
import os; sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from sexpr import parse, find, one
def read(path):
    s=parse(open(path).read())
    routes=one(s,'routes'); res=one(routes,'resolution'); scale={'um':1000.0,'mil':1000/25.4/1000*1000}[res[1]]*float(res[2])
    # coordinates are in res units: value/ (units per mm)
    per_mm={'um':1000.0,'mm':1.0,'mil':1/0.0254}[res[1]]*float(res[2])
    segs=[];vias=[]
    for net in find(one(routes,'network_out'),'net'):
        name=net[1]
        for w in find(net,'wire'):
            p=one(w,'path'); lay=p[1]; wd=float(p[2])/per_mm
            xy=[float(v)/per_mm for v in p[3:] if not isinstance(v,list)]
            pts=[(xy[i],-xy[i+1]) for i in range(0,len(xy),2)]
            for a,b in zip(pts,pts[1:]):
                if a!=b: segs.append((name,lay,wd,a,b))
        for v in find(net,'via'):
            vias.append((name,float(v[2])/per_mm,-float(v[3])/per_mm))
    return segs,vias
def merge(pcb_in, ses, pcb_out, via_size=0.8, via_drill=0.4):
    via_size,via_drill=float(via_size),float(via_drill)
    txt=open(pcb_in).read()
    b=parse(txt); nets={n[2]:int(n[1]) for n in find(b,'net')}
    segs,vias=read(ses)
    out=[]
    for name,lay,wd,a,bb in segs:
        out.append(f'\t(segment\n\t\t(start {a[0]:.4f} {a[1]:.4f})\n\t\t(end {bb[0]:.4f} {bb[1]:.4f})\n\t\t(width {wd:g})\n\t\t(layer "{lay}")\n\t\t(net {nets[name]})\n\t\t(uuid "{uuid.uuid4()}")\n\t)')
    for name,x,y in vias:
        out.append(f'\t(via\n\t\t(at {x:.4f} {y:.4f})\n\t\t(size {via_size:g})\n\t\t(drill {via_drill:g})\n\t\t(layers "F.Cu" "B.Cu")\n\t\t(net {nets[name]})\n\t\t(uuid "{uuid.uuid4()}")\n\t)')
    i=txt.rstrip().rfind(')')
    open(pcb_out,'w').write(txt[:i].rstrip('\n')+'\n'+'\n'.join(out)+'\n)\n')
    return len(segs),len(vias)
if __name__=='__main__':
    print(merge(*sys.argv[1:]))
