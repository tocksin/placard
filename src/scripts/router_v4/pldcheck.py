"""pldcheck.py before.kicad_pcb after.kicad_pcb [outdir]
Check every ATF22V10 pin swap between two boards against the chip's resources:
product terms of the new pin (as written and inverted), input-only pins, the
clock pin, and that every signal still has exactly one pin.  Writes
<outdir>/pldcheck.json, pldcheck.md and one <Uref>_<design>_pinswap.pld per chip
(only the PIN lines differ) for a WinCUPL compile.  SCHDIR/PLDDIR as in pinswap.py."""
import sys,os,re,json,collections,datetime
R=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,R)
import pinswap as ps
from board import load
PT=ps.PTCAP
def padnets(f):
    b,nets,fps,pads,edges=load(f); d=collections.defaultdict(dict)
    for p in pads:
        if p['ref'].startswith('U') and p['num'].isdigit(): d[p['ref']][int(p['num'])]=nets.get(p['net'],'') or ''
    return d
old=padnets(sys.argv[1]); new=padnets(sys.argv[2])
syms=ps.schematic_symbols(); out={}; rep=[]
for ref in sorted([r for r in syms if re.match(r'U\d+$',r)],key=lambda r:int(r[1:])):
    if 'ATF22V10' not in syms[ref].upper(): continue
    f=ps.pld_file(syms[ref]); pins,eqs,ext=ps.parse_pld(f); pinnames=set(pins.values())
    env={k:v for k,v in eqs.items() if k not in pinnames and v is not None}
    raw=open(f,encoding='utf-8',errors='replace').read()
    def need(nm):
        t=eqs.get(nm)
        if t is None: return None
        try: return (len(ps._dnf(t,True,env)),len(ps._dnf(t,False,env)))
        except Exception as e: return None
    o=old[ref]; n=new[ref]; moved=[p for p in range(1,25) if o.get(p)!=n.get(p)]
    # signal now on pin p = signal whose old pin carried that net
    bynet=collections.defaultdict(list)
    for p in range(1,25): bynet[o.get(p,'')].append(p)
    newpins={}; issues=[]; rows=[]
    used=set()
    for p in range(1,25):
        if p not in moved: newpins[p]=pins.get(p); used.add(p); continue
    for p in moved:
        cands=[q for q in bynet[n[p]] if q not in used or q in moved]
        cands=[q for q in bynet[n[p]] if q in moved and q not in [v for v in newpins.get('_src',[])]]
        if not cands: issues.append(f'pin {p}: net {n[p]} was not on a moved pin of this part'); continue
        q=cands[0]; newpins.setdefault('_src',[]).append(q); sig=pins.get(q); newpins[p]=sig
        kind='unused' if sig is None else ('out' if sig in eqs else 'in')
        row=dict(pin=p,frompin=q,signal=sig,net=n[p],kind=kind)
        if p in (1,12,24) or q in (1,12,24): issues.append(f'pin {p}<-{q}: clock/power pin moved')
        if kind=='out':
            nd=need(sig); cap=PT.get(p); capo=PT.get(q)
            row.update(cap_new=cap,cap_old=capo,need=nd)
            reg=bool(re.search(r'\b'+re.escape(sig)+r'\.[dD]\s*=',raw)); oe=bool(re.search(r'\b'+re.escape(sig)+r'\.[oO][eE]\s*=',raw)); row.update(registered=reg,oe=oe)
            if cap is None: issues.append(f'{sig}: output moved to input-only pin {p}')
            elif nd is None:
                row['verdict']='ok (new pin has at least as many terms as the old one)' if cap>=capo else 'UNVERIFIED: terms could not be counted and the new pin has fewer'
                if cap<capo: issues.append(f'{sig}: pin {q} ({capo} terms) -> pin {p} ({cap} terms), term count unknown')
            else:
                m=nd[0]   # as written: CUPL keeps the polarity of the equation
                row['verdict']='ok' if m<=cap else 'TOO BIG'
                if m>cap: issues.append(f'{sig}: needs {m} terms (true {nd[0]} / inverted {nd[1]}), pin {p} has {cap}')
        rows.append(row)
    newpins.pop('_src',None)
    # every signal still on exactly one pin
    a=collections.Counter(v for v in pins.values()); b=collections.Counter(v for v in newpins.values() if v)
    if a!=b: issues.append(f'signal set changed: lost {sorted((a-b).elements())} doubled {sorted((b-a).elements())}')
    out[ref]=dict(file=os.path.basename(f),moved=len(moved),rows=rows,issues=issues,newpins={k:v for k,v in newpins.items()},oldpins=pins)
OUT=(sys.argv[3] if len(sys.argv)>3 else 'pldcheck').rstrip('/')+'/'; os.makedirs(OUT,exist_ok=True)
json.dump(out,open(OUT+'pldcheck.json','w'),indent=1)
md=['# PLD pin swap check','',f'{sys.argv[1]} -> {sys.argv[2]}','','| chip | design | pins moved | outputs moved | issues |','|---|---|---|---|---|']
for ref,d in out.items():
    outs=[r for r in d['rows'] if r['kind']=='out']
    print(f"{ref} {d['file']}: {d['moved']} pins moved ({len(outs)} outputs, {sum(1 for r in d['rows'] if r['kind']=='in')} inputs, {sum(1 for r in d['rows'] if r['kind']=='unused')} unused); issues: {d['issues'] or 'none'}")
    md.append(f"| {ref} | {d['file']} | {d['moved']} | {len(outs)} | {'; '.join(d['issues']) or 'none'} |")
    for r in outs: print(f"    {r['signal']:<14} pin {r['frompin']:>2} ({r['cap_old']:>2}) -> {r['pin']:>2} ({r['cap_new']:>2})  need {r['need']}  {'reg ' if r['registered'] else ''}{'oe ' if r['oe'] else ''} {r.get('verdict')}")
D=out; today=datetime.date.today()
made=[]
for ref,d in D.items():
    s=open(ps.pld_file(syms[ref]),encoding='utf-8',errors='replace').read()
    lines=s.split('\n'); pinline={}
    for i,l in enumerate(lines):
        m=re.match(r'(?i)^(\s*PIN\s+)(\d+)(\s*=\s*)(!?\s*[A-Za-z_][A-Za-z_0-9]*)(\s*;)(.*)$',l)
        if m: pinline[int(m.group(2))]=(i,m)
    src={r['pin']:r['frompin'] for r in d['rows']}
    new=list(lines)
    for p,q in src.items():
        if p in pinline: i,m=pinline[p]
        else: i=None
        if q in pinline:
            _,mq=pinline[q]; txt=f"PIN {p:<2} = {mq.group(4)};{mq.group(6)}  /* pin swap: was on pin {q} */"
        else: txt=f"/* PIN {p}: not used after the pin swap (was {pinline[p][1].group(4) if p in pinline else 'unused'}) */"
        if i is not None: new[i]=txt
        else:
            j=max(k for k,_ in pinline.values()); new.insert(j+1,txt)   # pin had no line before
    t='\n'.join(new)
    t=re.sub(r'(?im)^(\s*Date\s+)[^;]*;',lambda m:m.group(1)+today.strftime('%m/%d/%Y')+' ;',t,count=1)
    name=f"{ref}_{d['file'][:-4]}_pinswap.pld"
    t=f"/* PIN-SWAP VARIANT for {ref} (router test bench, {today}): only the PIN lines differ from {d['file']}.\n   Not a released design: compile-check only. */\n"+t
    open(OUT+name,'w',encoding='utf-8').write(t); made.append(name)
print(len(made),made[:3])

md+=['','## Moved outputs','','| chip | signal | old pin (terms) | new pin (terms) | terms needed as written / inverted | spare | registered | result |','|---|---|---|---|---|---|---|---|']
for ref,d in out.items():
    for r in d['rows']:
        if r['kind']!='out': continue
        nd=r.get('need'); md.append(f"| {ref} | {r['signal']} | {r['frompin']} ({r['cap_old']}) | {r['pin']} ({r['cap_new']}) | {'%d / %d'%tuple(nd) if nd else 'not counted'} | {r['cap_new']-nd[0] if nd and r['cap_new'] else ''} | {'yes' if r['registered'] else ''} | {r.get('verdict','')} |")
open(OUT+'pldcheck.md','w').write('\n'.join(md)+'\n')
bad=sum(len(d['issues']) for d in out.values()); print('issues:',bad); sys.exit(1 if bad else 0)
