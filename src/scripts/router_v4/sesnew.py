"""sesnew.py pcb ses out : add only the SES wires/vias that are not already in the board (Freerouting writes the protected wiring back too)"""
import sys,uuid; import os; sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from ses import read
from sexpr import parse,find,one
pcb,ses,out=sys.argv[1:4]
txt=open(pcb).read(); b=parse(txt); nets={n[2]:int(n[1]) for n in find(b,'net')}
def k(p): return (round(p[0],2),round(p[1],2))
have=set()
for s in find(b,'segment'):
    a=k(tuple(map(float,one(s,'start')[1:3]))); e=k(tuple(map(float,one(s,'end')[1:3]))); L=one(s,'layer')[1]
    have.add((L,a,e)); have.add((L,e,a))
hv={k(tuple(map(float,one(v,'at')[1:3]))) for v in find(b,'via')}
segs,vias=read(ses); o=[]; ns=nv=0
for name,lay,wd,a,e in segs:
    if (lay,k(a),k(e)) in have: continue
    o.append(f'\t(segment\n\t\t(start {a[0]:.4f} {a[1]:.4f})\n\t\t(end {e[0]:.4f} {e[1]:.4f})\n\t\t(width {wd:g})\n\t\t(layer "{lay}")\n\t\t(net {nets[name]})\n\t\t(uuid "{uuid.uuid4()}")\n\t)'); ns+=1
for name,x,y in vias:
    if k((x,y)) in hv: continue
    o.append(f'\t(via\n\t\t(at {x:.4f} {y:.4f})\n\t\t(size 0.8)\n\t\t(drill 0.4)\n\t\t(layers "F.Cu" "B.Cu")\n\t\t(net {nets[name]})\n\t\t(uuid "{uuid.uuid4()}")\n\t)'); nv+=1
i=txt.rstrip().rfind(')')
open(out,'w').write(txt[:i].rstrip('\n')+'\n'+'\n'.join(o)+'\n)\n'); print('new segments',ns,'vias',nv)
