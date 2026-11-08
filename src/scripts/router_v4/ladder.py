"""ladder.py src.kicad_pcb prefix : the via-cost ladder of tidy passes, best-of-N per rung.
Runs tidy.py on src with VIA = each value of VIAS ("400 800 1600"), feeding each rung's best board to the next. Every rung
is tried TRIES times (SEED=1.. jitters the net order; the parallel pool adds its own run-to-run spread, ~10 vias on the
r1 bench), each try is chamfered (corner45.py) and scored (score.py), and the try with the lowest cost
    track_m*1000 + VIA*GRID*vias            (the tidy's own objective in mm)
wins the rung. Outputs prefix_v<VIA>_t<k>.* per try and prefix_v<VIA>.kicad_pcb / _c45.kicad_pcb / .score for the winner.
restartable: finished tries (their .json exists) are reused.
env: VIAS ("400 800 1600")  TRIES (3)  GRID NETS WORKERS AGAINST and everything else tidy.py reads
     WIDE=1: one more rung after the last VIA with the wide pair search (NEIGH=8 NEIGHMM=2.5, no net pass; one try):
     16 fewer vias on the whole board, 7-13 on r1, for about the same track, in 3x the pair-pass time.
     DIAGRUNGS=N: the first N rungs run the tidy with DIAG=1 (45-degree moves anywhere), the rest orthogonal (DIAG=0),
     which backs the diagonals out of the tight spots they made (Justin's rule). Fine r1: DIAGRUNGS=2 of 4 + WIDE gives
     422 vias / 26.13 m against 423 / 26.73 all-orthogonal and 424 / 26.34 all-diagonal."""
import sys, os, subprocess, json, shutil, time
TOOLS=os.path.dirname(os.path.abspath(__file__))
E=os.environ.get
src,prefix=sys.argv[1:3]
VIAS=[int(v) for v in E('VIAS','400 800 1600').split()]; TRIES=int(E('TRIES','3')); G=float(E('GRID','0.125'))
DIAGRUNGS=int(E('DIAGRUNGS','0'))
PY=sys.executable
def run(cmd,env,log):
    with open(log,'a') as f:
        f.write('$ '+' '.join(f'{k}={v}' for k,v in env.items())+' '+' '.join(cmd)+'\n'); f.flush()
        e=dict(os.environ); e.update(env)
        r=subprocess.run(cmd,env=e,stdout=f,stderr=subprocess.STDOUT)
    if r.returncode: raise SystemExit(f'{cmd[1]} failed, see {log}')
def score(pcb,js):
    if not os.path.exists(js): run([PY,os.path.join(TOOLS,'score.py'),pcb],{'JSON':js},js.replace('.json','.log'))
    t=json.load(open(js))['total']; return float(t['track_m']),int(t['vias'])
prev=src; T0=time.time()
for ri,v in enumerate(VIAS):
    diag={'DIAG':'1' if ri<DIAGRUNGS else '0'} if DIAGRUNGS else {}
    best=None
    for k in range(TRIES):
        t0=time.time(); out=f'{prefix}_v{v}_t{k}'
        if not os.path.exists(out+'.json'):   # a finished try is reused when the ladder is restarted
            for f in (out+'.log',out+'.kicad_pcb',out+'_c45.kicad_pcb'):
                if os.path.exists(f): os.remove(f)
            run([PY,os.path.join(TOOLS,'tidy.py'),prev,out+'.kicad_pcb'],{'VIA':str(v),'SEED':str(k),**diag},out+'.log')
            run([PY,os.path.join(TOOLS,'corner45.py'),out+'.kicad_pcb',out+'_c45.kicad_pcb'],{},out+'.log')
        m,n=score(out+'_c45.kicad_pcb',out+'.json'); cost=m*1000+v*G*n
        print(f'VIA {v} try {k}: {m:.2f} m, {n} vias, cost {cost:.0f}, {time.time()-t0:.0f} s',flush=True)
        if best is None or cost<best[0]: best=(cost,k,m,n)
    cost,k,m,n=best; out=f'{prefix}_v{v}_t{k}'
    for ext in ('.kicad_pcb','_c45.kicad_pcb','.json'): shutil.copyfile(out+ext,f'{prefix}_v{v}'+ext)
    with open(f'{prefix}_v{v}.score','w') as f: f.write(f'# ladder VIA {v}: best try {k} of {TRIES}: {m:.2f} m, {n} vias, cost {cost:.0f}\n')
    print(f'VIA {v} best: try {k}, {m:.2f} m, {n} vias ({time.time()-T0:.0f} s so far)',flush=True)
    prev=f'{prefix}_v{v}.kicad_pcb'
if E('WIDE','0')=='1':
    v=VIAS[-1]; t0=time.time(); out=f'{prefix}_v{v}_wide'
    if not os.path.exists(out+'.json'):
        run([PY,os.path.join(TOOLS,'tidy.py'),prev,out+'.kicad_pcb'],{'VIA':str(v),'NEIGH':'8','NEIGHMM':'2.5','NETPASS':'0',**({'DIAG':'0'} if DIAGRUNGS else {})},out+'.log')
        run([PY,os.path.join(TOOLS,'corner45.py'),out+'.kicad_pcb',out+'_c45.kicad_pcb'],{},out+'.log')
    m,n=score(out+'_c45.kicad_pcb',out+'.json')
    with open(out+'.score','w') as f: f.write(f'# ladder wide pair rung at VIA {v}: {m:.2f} m, {n} vias\n')
    print(f'wide pair rung at VIA {v}: {m:.2f} m, {n} vias, {time.time()-t0:.0f} s',flush=True)
print('LADDER DONE',flush=True)
