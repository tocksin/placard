"""makebench.py in.kicad_pcb out.kicad_pcb [KEEP=GND,+5V,CLK_E] : whole-board test bench. Removes every segment, arc and via
of the nets not in KEEP (default GND,+5V: the plane vias stay). Footprints, zones and everything else are untouched.
The input file is never written to."""
import sys, os, re
src,dst=sys.argv[1:3]; KEEP=set(os.environ.get('KEEP','GND,+5V,CLK_E').split(','))
s=open(src,encoding='utf-8').read()
nets={int(a):b for a,b in re.findall(r'\(net (\d+) "((?:[^"\\]|\\.)*)"\)',s)}
keep={n for n,name in nets.items() if name in KEEP}
out=[]; i=0; n=len(s); removed={'segment':0,'arc':0,'via':0}
def block_end(j):
    """index after the matching ')' of the block starting at j ('(' at s[j]); quotes respected"""
    depth=0; q=False; k=j
    while k<n:
        c=s[k]
        if q:
            if c=='\\': k+=1
            elif c=='"': q=False
        elif c=='"': q=True
        elif c=='(': depth+=1
        elif c==')':
            depth-=1
            if depth==0: return k+1
        k+=1
    raise SystemExit('unbalanced')
pat=re.compile(r'\n\t\((segment|arc|via)\b')
while True:
    m=pat.search(s,i)
    if not m: out.append(s[i:]); break
    j=m.start()+2; e=block_end(j)   # j = index of '('
    blk=s[j:e]; nm=re.search(r'\(net (\d+)\)',blk)
    if nm and int(nm.group(1)) in keep: out.append(s[i:e]); i=e
    else: out.append(s[i:m.start()]); removed[m.group(1)]+=1; i=e
open(dst,'w',encoding='utf-8').write(''.join(out))
print('removed',removed,'kept nets',sorted(nets[k] for k in keep))
