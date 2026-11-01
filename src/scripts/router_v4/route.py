"""route.py in out : the v4 pipeline. mroute4 (parallel negotiation + rip-up) -> mroute3 on any leftovers (v3 rip-up that may
also move fixed copper of unprotected nets) -> tidy -> score. Intermediate files next to out. Env vars pass through."""
import os, sys, subprocess, re
TOOLS=os.path.dirname(os.path.abspath(__file__)); src,dst=sys.argv[1:3]; stem=dst.rsplit('.',1)[0]
def run(args,log):
    with open(log,'w') as f: p=subprocess.run([sys.executable]+args,stdout=f,stderr=subprocess.STDOUT)
    txt=open(log).read(); print(txt[-1500:]); return txt
t=run([os.path.join(TOOLS,'mroute4.py'),src,stem+'_a.kicad_pcb'],stem+'_a.log')
m=re.search(r"UNROUTED (\d+) \[(.*?)\] total",t); left=[x.strip().strip("'") for x in m.group(2).split(',') if x.strip()] if m and m.group(1)!='0' else []
cur=stem+'_a.kicad_pcb'
if left:
    env=dict(os.environ,NETS=','.join(left))
    with open(stem+'_b.log','w') as f: subprocess.run([sys.executable,os.path.join(TOOLS,'mroute3.py'),cur,stem+'_b.kicad_pcb'],stdout=f,stderr=subprocess.STDOUT,env=env)
    print(open(stem+'_b.log').read()[-800:]); cur=stem+'_b.kicad_pcb'
env=dict(os.environ,BASE=src)
with open(stem+'_tidy.log','w') as f: subprocess.run([sys.executable,os.path.join(TOOLS,'tidy.py'),cur,dst],stdout=f,stderr=subprocess.STDOUT,env=env)
print(open(stem+'_tidy.log').read()[-600:])
subprocess.run([sys.executable,os.path.join(TOOLS,'score.py'),dst],env=dict(env,JSON=stem+'.json'))
