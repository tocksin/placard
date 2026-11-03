"""budgets.py board.kicad_pcb out.json : track-length budgets for the router from the board timing model.
The timing paths of docs/timing/TIMING.md (routed-timing model, 2026-11-02: fetch, operand/X/Y/video/zero-page reads, store
start and end, RW, STALL loop, cartridge ROM fetch, ALU single clock) are written here with every board track length as a
variable: each check becomes a set of linear slack forms  slack = const - sum(k_i * len_i)  (one per alternative path,
e.g. per address bit and data bit). For a form to keep MARGIN ns of slack, its hurting lengths share the room in proportion
to their straight (Manhattan) pad-to-pad distance on the current placement:  len_i <= r * man_i  with one detour ratio r
per form. A length's budget is the smallest over all forms. Lengths that help a check (a later capture clock) are taken at
their straight distance, the shortest any routing can make them (HELP=now: their present routed value instead, which only
holds while that net is not re-routed). FIXED nets or pairs (the CLK_E delay lead X1 -> NT2, Justin's) are never
budgeted and use their routed length (FIXLEN while not routed); the CLK_E taps to U15 pin 9 and U11 pin 1 are budgeted. Cartridge-side lengths come from timing/cart_c64.json (64K cartridge board).
out.json: {"margin_ns":..,"duty":[..],"max":{"NET":{"FROM_PAD":{"TO_PAD":mm,..}}},"min":{"CLK_E":{"X1-8":{"NT2-1":420}}},
           "checks":{name:{"worst_ratio":r,"forms":n,"slack_now":ns}}}
env: MARGIN=0.5 (ns kept on every setup path)  DUTY=0.45,0.53 (clock high share range: budgets hold at both ends)
     FIXED=CLK_E:X1-8:NT2-1 (nets or NET:FROM:TO pairs never budgeted; the CLK_E taps to U15-9 / U11-1 are)  FIXLEN=CLK_E:X1-8:NT2-1:459 (length of a fixed net while it is not routed; FIXFORCE=1 uses it even when routed, for what-ifs)  MINLEN=CLK_E:X1-8:NT2-1:420  RMAX=4 (no budget written when the ratio is above this)
     FLOOR=3 (mm: smallest share of a short hop)  RFEAS=1.05 (budget of an infeasible form: this x Manhattan)  WEC=1 (store
     start uses the later of CLK_E/CLK at the sync PLD, as in TIMING.md)  U11E=1 (timing fix 4: U11 pin 1 on CLK_E at X1)
     HELP=man (helping lengths at their straight distance; now = present routed value)"""
import sys, os, json, math, collections
TOOLS=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,TOOLS)
import tracklen
E=os.environ.get
V=0.006; T=39.72
tPD,tPDm,tCO,tCOm=7.5,3.0,5.5,2.0
MARGIN=float(E('MARGIN','0.5')); DUTY=[float(x) for x in E('DUTY','0.45,0.53').split(',')]
FIXED=set(E('FIXED','CLK_E:X1-8:NT2-1').split(',')); RMAX=float(E('RMAX','4')); FLOOR=float(E('FLOOR','3')); RFEAS=float(E('RFEAS','1.05'))
WEC=E('WEC','1')=='1'; SLOTS=E('SLOTS','1')=='1'; HELP=E('HELP','man'); FIXFORCE=E('FIXFORCE','0')=='1'; U11E=E('U11E','0')=='1'
# card budget at the slot fingers (ns), the reference card of EXPANSION.md "Card timing" (I/O decode PLD rev 07): a plain
# 15 ns SRAM (AS7C256C-15) with /CE = /EXPn, /OE = Q0, /WE = /WE and A6:A0 from the slot; 1 ns of card traces each way.
# CARD_EXP = tACE 15 + 1, CARD_CTL = tAA 15 + 1 (A7:A0, RW, LOAD_IMM to data), CARD_OE = tOE 7 + 1 (Q0 to data),
# CARD_WE = tCW 12 + 1 (select ready before /WE rises), CARD_DS = tDW 8 + 1, CARD_DH = tDH 0 + 2, CARD_EH = tAH 0 + 2
CARD_EXP=float(E('CARD_EXP','16.0')); CARD_CTL=float(E('CARD_CTL','16.0')); CARD_OE=float(E('CARD_OE','8.0')); CARD_WE=float(E('CARD_WE','13.0'))
CARD_DS=float(E('CARD_DS','9.0')); CARD_DH=float(E('CARD_DH','2.0')); CARD_EH=float(E('CARD_EH','2.0'))
MINLEN=[m.split(':') for m in E('MINLEN','CLK_E:X1-8:NT2-1:420').split(',') if m]
FIXLEN={tuple(m.split(':')[:3]):float(m.split(':')[3]) for m in E('FIXLEN','CLK_E:X1-8:NT2-1:459').split(',') if m}   # fixed lengths used while that net is not routed

# ---------------- max-plus algebra of linear forms
class Form:
    __slots__=('c','t')
    def __init__(self,c=0.0,t=None): self.c=c; self.t=t or {}
    def add(self,o):
        t=dict(self.t)
        for k,v in o.t.items(): t[k]=t.get(k,0.0)+v
        return Form(self.c+o.c,t)
    def neg(self): return Form(-self.c,{k:-v for k,v in self.t.items()})
    def sig(self): return tuple(sorted((k,round(v,9)) for k,v in self.t.items() if abs(v)>1e-12))
class X:
    """max (sense +1) or min (sense -1) over linear forms; one form = no sense"""
    def __init__(self,forms,sense=0): self.f=forms; self.s=sense if len(forms)>1 else 0
    @staticmethod
    def of(v): return v if isinstance(v,X) else X([Form(float(v))])
    def __add__(a,b):
        b=X.of(b)
        if len(a.f)>1 and len(b.f)>1 and a.s!=b.s: raise ValueError('max + min of forms')
        s=a.s or b.s; out=[p.add(q) for p in a.f for q in b.f]
        if len(out)>20000: raise ValueError('form explosion')
        return X(out,s).dedupe()
    __radd__=__add__
    def __neg__(a): return X([p.neg() for p in a.f],-a.s)
    def __sub__(a,b): return a+(-X.of(b))
    def __rsub__(a,b): return X.of(b)+(-a)
    def dedupe(self):
        d={}
        for p in self.f:
            k=p.sig()
            if k not in d or (self.s>=0 and p.c>d[k].c) or (self.s<0 and p.c<d[k].c): d[k]=p
        self.f=list(d.values()); return self
def _ext(sense,xs):
    xs=[X.of(x) for x in xs]; out=[]
    for x in xs:
        if x.s==-sense: raise ValueError('mixed max/min')
        out+=x.f
    return X(out,sense).dedupe()
def MAX(*xs): return _ext(1,xs[0] if len(xs)==1 and not isinstance(xs[0],(X,int,float)) else xs)
def MIN(*xs): return _ext(-1,xs[0] if len(xs)==1 and not isinstance(xs[0],(X,int,float)) else xs)

# ---------------- the timing model (port of the routed-timing what-if model, all board lengths symbolic)
def model(H,CART):
    def L(net,drv,load): return X([Form(0.0,{(net,drv,load):V})])
    def LC(net,drv,load): return CART[f'{net}|{drv}']['d'][load]*V
    def c(ref):
        if ref=='U15-9': return L('CLK_E','X1-8','U15-9')
        return L('CLK_E','X1-8','NT2-1')+L('CLK','NT2-2',ref)
    clk={'U1':'U1-1','U2':'U2-1','U3':'U3-1','U4':'U4-1','U11':'U11-1','U15':'U15-1','U17':'U17-1','U18':'U18-11','U22':'U22-11','U21':'U21-11','U19':'U19-11','U20':'U20-11'}
    C={k:c(v) for k,v in clk.items()}; C['U15E']=c('U15-9')
    if U11E: C['U11']=L('CLK_E','X1-8','U11-1')   # timing fix 4: /OE PLD clocked from CLK_E next to X1 (not on the board yet)
    mux={}
    for i,u in zip((0,2,4,6),('U7','U8','U9','U10')):
        for j,b in enumerate((i,i+1,i+8,i+9)): mux[b]=(u,[20,21,22,23][j],[8,13,16,19][j])
    ramA={14:1,12:2,7:3,6:4,5:5,4:6,3:7,2:8,1:9,0:10,15:20,10:21,11:23,9:24,8:25,13:26}
    bits={'U31':list(range(16)),'U32':list(range(15))}
    pcdrv={i:(('U3' if i<8 else 'U4')+'-'+str({0:15,1:22,2:21,3:16,4:20,5:17,6:19,7:18}[i%8])) for i in range(16)}
    def A(a,r): u,p,_=mux[a]; return L(f'ADDR{a}',f'{u}-{p}',f'{r}-{ramA[a]}')
    def sel(net,drv,pin): return {a:L(net,drv,f'{mux[a][0]}-{pin}') for a in range(16)}
    PCE=sel('PC_ENABLE','U1-15',2); PIX=sel('PIXEL_ENABLE','U15-19',1); XE=sel('X_ENABLE','U1-16',3); YE=sel('Y_ENABLE','U1-17',4)
    CEHI=lambda: L('Net-(J8-{slash}CE_HI)','U12-15','U32-20')
    DBp=[11,12,13,15,16,17,18,19]
    def DB(i,r,dest): return L(f'DATABUS{i}',f'{r}-{DBp[i]}',dest)
    dests={'U1':{0:'U1-4',1:'U1-3',2:'U1-10',3:'U1-9',4:'U1-11'},'U17':{i:f'U17-{2+i}' for i in range(8)},
           'U18':{i:f'U18-{p}' for i,p in enumerate([3,4,7,8,13,14,17,18])},'U22':{i:f'U22-{p}' for i,p in enumerate([3,4,7,8,13,14,17,18])}}
    setup={'U1':3.5,'U17':3.5,'U18':2.0,'U22':2.0}
    R={}
    def addr_sel(S,M,r,tco=tCO,tpd=tPD,f=MAX,mux_bits=None): return f([C[S]+tco+M[a]+tpd+A(a,r) for a in (mux_bits or bits[r])])
    def cehi_from(S,net,drv,pin,tco=tCO,tpd=tPD): return C[S]+tco+L(net,drv,f'U12-{pin}')+tpd+CEHI()
    oe={r:H+C['U11']+tPD+L('Net-(U11-{slash}RAM_OE)','U11-18',f'{r}-22') for r in ('U31','U32')}
    def read_slack(ready,destchips,use_oe=True):
        out=[]
        for r in ('U31','U32'):
            t=ready[r]+15
            if use_oe: t=MAX(t,oe[r]+7)
            for d in destchips:
                for i,pin in dests[d].items(): out.append(T+C[d]-(t+DB(i,r,pin)+setup[d]))
        return MIN(out)
    rd={r:addr_sel('U1',PCE,r) for r in ('U31','U32')}
    rd['U32']=MAX(rd['U32'],cehi_from('U1','PC_ENABLE','U1-15',3))
    R['fetch_tAA']=read_slack(rd,['U1','U17'],use_oe=False)
    R['fetch_oe']=read_slack(rd,['U1','U17'])
    rdp={}
    for r in ('U31','U32'):
        rdp[r]=MAX([C[pcdrv[a].split('-')[0]]+tCO+L(f'PC{a}',pcdrv[a],f'{mux[a][0]}-{mux[a][2]}')+tPD+A(a,r) for a in bits[r]])
    rdp['U32']=MAX(rdp['U32'],C['U4']+tCO+L('PC15','U4-18','U12-4')+tPD+CEHI())
    rdb={r:MAX(rd[r],rdp[r]) for r in rd}
    R['fetch_branch_tAA']=read_slack(rdb,['U1','U17'],use_oe=False)
    R['operand_read']=read_slack(rdp,['U18'])
    rx={r:MAX(addr_sel('U1',XE,r),addr_sel('U1',YE,r,mux_bits=[a for a in bits[r] if a>=8]),addr_sel('U1',PCE,r)) for r in ('U31','U32')}
    rx['U32']=MAX(rx['U32'],cehi_from('U1','Y_ENABLE','U1-17',14))
    R['xy_read']=read_slack(rx,['U18'])
    rv={r:addr_sel('U15',PIX,r) for r in ('U31','U32')}
    rv['U32']=MAX(rv['U32'],cehi_from('U15','PIXEL_ENABLE','U15-19',2))
    R['video_read']=read_slack(rv,['U22'])
    # store start: /WE low (earliest) after the zero-page address [0,D] / the select change. Sync PLD rev 11 gates /WE with
    # CLK as well as CLK_E (WEC=1): /WE falls at the later edge, which is CLK at U15-1 (CLK_E reaches NT2 through the delay lead)
    WE0=C['U15'] if WEC else C['U15E']
    we_lo={r:H+WE0+tPDm+L('~{WE}','U15-20',f'{r}-27') for r in ('U31','U32')}
    sel_t=addr_sel('U1',PCE,'U31')
    dpath=MAX([C['U18']+10.5+L(f'D{a}',f'U18-{[2,5,6,9,12,15,16,19][a]}',f'{mux[a][0]}-{[5,9][a%2]}')+tPD+A(a,'U31') for a in range(8)])
    R['zp_store_start']=we_lo['U31']-MAX(sel_t,dpath)
    R['zp_store_start_cehi']=we_lo['U32']-cehi_from('U1','PC_ENABLE','U1-15',3)
    R['store_after_stall']=MIN([we_lo[r]-addr_sel('U15',PIX,r) for r in ('U31','U32')])
    rw=MAX([C['U17']+tCO+L(f'I{i}',f'U17-{14+i}','U1-'+p)+tPD for i,p in [(0,'13'),(2,'7'),(3,'6'),(4,'5')]])+L('RW','U1-23','U15-10')
    R['rw_before_we']=H+WE0-rw
    # write pulse tWP 10 (AS7C256C-15): /WE low from the later falling edge (CLK at U15-1 with WEC) to the CLK_E rise at
    # U15-9, less the spread of the two /WE edges (tPD 7.5 - tPDm 3.0); the CLK_E delay lead shortens it
    R['write_pulse']=(T-H)-(tPD-tPDm)-(WE0-C['U15E'])-10.0
    we_hi={r:T+C['U15E']+tPD+L('~{WE}','U15-20',f'{r}-27') for r in ('U31','U32')}
    we_hi_min={r:T+C['U15E']+tPDm+L('~{WE}','U15-20',f'{r}-27') for r in ('U31','U32')}
    hold=[]
    for r in ('U31','U32'):
        hold.append(addr_sel('U1',PCE,r,tCOm,tPDm,MIN)+T-we_hi[r]); hold.append(addr_sel('U15',PIX,r,tCOm,tPDm,MIN)+T-we_hi[r])
    hold.append(T+MIN(cehi_from('U1','PC_ENABLE','U1-15',3,tCOm,tPDm),cehi_from('U15','PIXEL_ENABLE','U15-19',2,tCOm,tPDm))-we_hi['U32'])
    R['addr_hold']=MIN(hold)
    # port PLD rev 05 registers clock on /WE (U38 pin 1) and load only while /PORT (U12 pin 20, from PC_ENABLE / Y_ENABLE
    # of the next state) is low: /PORT must not change before /WE rises at U38 (ATF22V10C tH 0)
    we_u38=T+C['U15E']+tPD+L('~{WE}','U15-20','U38-1')
    R['port_sel_hold']=T+MIN(C['U1']+tCOm+L('PC_ENABLE','U1-15','U12-3'),C['U1']+tCOm+L('Y_ENABLE','U1-17','U12-14'))+tPDm+L('~{PORT}','U12-20','U38-2')-we_u38
    off=[]
    for r in ('U31','U32'):
        for i in range(8):
            for net,drv,pin in (('PC_ENABLE','U1-15','U2-11'),('/Control/Q0','U1-18','U2-10')):
                t=T+C['U1']+tCOm+L(net,drv,pin)+tPDm+MIN(L('~{SRC_EN}','U2-16','U26-1'),L('~{SRC_EN}','U2-16','U27-1'))+1.5+L(f'/Data bus/SRC{i}',f'U26-{18-i}',f'R{5+i}-2')+L(f'DATABUS{i}',f'{r}-{DBp[i]}',f'R{5+i}-1')
                off.append(t-we_hi[r])
    R['data_hold']=MIN(off)
    st=C['U15']+tCO+L('PIXEL_ENABLE','U15-19','U2-9')+tPD+L('STALL_IN','U2-19','J8-B12')+22.8*V+tPD+L('STALL_OUT','J8-B5','U1-2')+tPD
    sl=[]
    for net,drv,ld,d,su in [('~{LOAD_IMM}','U1-19','U18-1','U18',4.5),('~{LOAD_X}','U1-20','U20-1','U20',4.5),('~{LOAD_Y}','U1-21','U21-1','U21',4.5),('~{LOAD_AC}','U1-22','U19-1','U19',4.5),('Net-(U1-{slash}LOAD_INSTR)','U1-14','U17-10','U17',3.5)]:
        sl.append(T+C[d]-(st+L(net,drv,ld)+su))
    R['stall_strobe']=MIN(sl)
    R['stall_pc']=MIN([T+C[u]-(C['U15']+tCO+L('PIXEL_ENABLE','U15-19','U2-9')+tPD+L('STALL_IN','U2-19','J8-B12')+22.8*V+tPD+L('STALL_OUT','J8-B5',f'{u}-14')+3.5) for u in ('U3','U4')])
    J8A={0:'A22',1:'A19',2:'A17',3:'A15',4:'A14',5:'B9',6:'B7',7:'A4',8:'A8',9:'A9',10:'A18',11:'A13',12:'B3',13:'A6',14:'A3',15:'A5'}
    J8D=['A24','A27','A29','A32','A30','B27','A25','B22']
    def AJ(a,rom):
        u,p,_=mux[a]
        if a==15: return L('ADDR15',f'{u}-{p}','J8-A5')+LC('/~{CE_LO}','J1-A5','U4-20')
        return L(f'ADDR{a}',f'{u}-{p}',f'J8-{J8A[a]}')+LC(f'/ADDR{a}',f'J1-{J8A[a]}',f'{rom}-{ramA[a]}')
    def rom_read(sel_src,M,dchips,extra_ce):
        out=[]
        for rom in ('U4','U5'):
            bl=list(range(16)) if rom=='U4' else list(range(15))
            t=MAX([C[sel_src]+tCO+M[a]+tPD+AJ(a,rom) for a in bl])
            if rom=='U5': t=MAX(t,extra_ce+L('Net-(J8-{slash}CE_HI)','U12-15','J8-B16')+LC('/~{CE_HI}','J1-B16','U5-20'))
            oe_t=H+C['U11']+tPD+L('Net-(J8-{slash}ROM_OE)','U11-19','J8-A16')+LC('/~{ROM_OE}','J1-A16',f'{rom}-22')
            tt=MAX(t+15,oe_t+7)
            for d in dchips:
                for i,pin in dests[d].items():
                    out.append(T+C[d]-(tt+LC(f'/DATABUS{i}',f'J1-{J8D[i]}',f'{rom}-{DBp[i]}')+L(f'DATABUS{i}',f'J8-{J8D[i]}',pin)+setup[d]))
        return MIN(out)
    ce0=C['U1']+tCO+L('PC_ENABLE','U1-15','U12-3')+tPD
    R['rom_fetch_oe']=rom_read('U1',PCE,['U1','U17'],ce0)
    R['rom_operand_oe']=rom_read('U1',PCE,['U18'],ce0)
    t=MAX(dpath,sel_t)
    R['zp_read']=MIN([T+C['U18']-(MAX(t+15,oe['U31']+7)+DB(i,'U31',p)+2.0) for i,p in dests['U18'].items()])
    srcen={u:MAX(C['U1']+tCO+L('PC_ENABLE','U1-15','U2-11'),C['U1']+tCO+L('/Control/Q0','U1-18','U2-10'))+tPD+L('~{SRC_EN}','U2-16',f'{u}-1') for u in ('U26','U27')}
    acsel=C['U17']+tCO+L('I1','U17-15','U35-16')+tPD+L('~{AC_SEL}','U35-21','U27-19')
    srcAC=MAX(srcen['U27'],acsel)+9.5
    ds=[]
    for r in ('U31','U32'):
        for i in range(8):
            tr=L(f'/Data bus/SRC{i}',f'U26-{18-i}',f'U27-{18-i}')+L(f'/Data bus/SRC{i}',f'U26-{18-i}',f'R{5+i}-2')
            ds.append(we_hi_min[r]-8-(srcAC+tr+L(f'DATABUS{i}',f'{r}-{DBp[i]}',f'R{5+i}-1')))
    R['data_setup']=MIN(ds)
    alu=[]
    fdrv={0:'U5-17',1:'U5-20',2:'U5-16',3:'U5-21',4:'U6-17',5:'U6-20',6:'U6-16',7:'U6-21'}
    for i in range(8):
        u='U5' if i<4 else 'U6'; apin=[5,6,7,8][i%4]
        tr=L(f'/Data bus/SRC{i}',f'U26-{18-i}',f'U27-{18-i}')+L(f'/Data bus/SRC{i}',f'U26-{18-i}',f'R{5+i}-2')
        rr=L(f'DATABUS{i}',f'R{5+i}-1',f'{u}-{apin}')
        f19=L(f'/ALU and registers/F{i}',fdrv[i],f'U19-{[3,4,7,8,13,14,17,18][i]}')
        alu.append(T+C['U19']-(srcAC+tr+rr+tPD+f19+2.0))
    R['alu_single_clock']=MIN(alu)
    if SLOTS:
        # expansion slots J9-J12 (docs/architecture/EXPANSION.md "Card timing"): the board's side of an I/O read or write of a
        # card, checked against the card budget at the fingers (CARD_* below) so a card built to that budget always passes.
        # I/O address [Y,X] in LOAD_MEM: X_ENABLE/Y_ENABLE select at the muxes.  /EXPn (I/O decode PLD U12 rev 07) is decoded
        # from the Y register, X7 and the mux selects: Y and X were loaded at least one clock earlier (an instruction before),
        # so in the I/O clock only Y_ENABLE, PC_ENABLE and PIXEL_ENABLE change, and /EXPn is valid one pass after them.
        tU12=MAX([C['U1']+tCO+L('Y_ENABLE','U1-17','U12-14'),C['U1']+tCO+L('PC_ENABLE','U1-15','U12-3'),
                  C['U15']+tCO+L('PIXEL_ENABLE','U15-19','U12-2')])
        tQ0=C['U1']+tCO   # Q0 (State PLD pin 18) falls at the start of LOAD_MEM
        SA={0:'A22',1:'A19',2:'A17',3:'A15',4:'A14',5:'B9',6:'B7',7:'A4'}
        SD={0:'A23',1:'B13',2:'B15',3:'B17',4:'B19',5:'B23',6:'B25',7:'B29'}
        lo={a:mux[a][:2] for a in range(8)}
        rd=[];wr=[];wd=[];dh=[];eh=[]
        for j,e,ed in (('J9','~{EXP1}','U12-21'),('J10','~{EXP2}','U12-22'),('J11','~{EXP3}','U12-16'),('J12','~{EXP4}','U12-19')):
            addr=MAX([C['U1']+tCO+L('X_ENABLE','U1-16',f'{u}-3')+tPD+L(f'ADDR{a}',f'{u}-{p}',f'{j}-{SA[a]}') for a,(u,p) in lo.items()])
            exp=tU12+tPD+L(e,ed,f'{j}-A16')
            ctl=MAX(addr,C['U1']+tCO+L('RW','U1-23',f'{j}-B16'),C['U1']+tCO+L('~{LOAD_IMM}','U1-19',f'{j}-A20'))
            dval=MAX(exp+CARD_EXP,ctl+CARD_CTL,tQ0+L('Q0','U1-18',f'{j}-A10')+CARD_OE)
            for i in range(8): rd.append(T+C['U18']-(dval+L(f'DATABUS{i}',f'{j}-{SD[i]}',dests['U18'][i])+setup['U18']))
            wlo=T+C['U15E']+tPDm+L('~{WE}','U15-20',f'{j}-B24'); whi=T+C['U15E']+tPD+L('~{WE}','U15-20',f'{j}-B24')
            wr.append(wlo-(MAX(exp,ctl)+CARD_WE))
            for i in range(8):
                tr=L(f'/Data bus/SRC{i}',f'U26-{18-i}',f'U27-{18-i}')+L(f'/Data bus/SRC{i}',f'U26-{18-i}',f'R{5+i}-2')
                wd.append(wlo-(srcAC+tr+L(f'DATABUS{i}',f'R{5+i}-1',f'{j}-{SD[i]}')+CARD_DS))
                for net,drv,pin in (('PC_ENABLE','U1-15','U2-11'),('/Control/Q0','U1-18','U2-10')):
                    off=T+C['U1']+tCOm+L(net,drv,pin)+tPDm+MIN(L('~{SRC_EN}','U2-16','U26-1'),L('~{SRC_EN}','U2-16','U27-1'))+1.5+tr+L(f'DATABUS{i}',f'R{5+i}-1',f'{j}-{SD[i]}')
                    dh.append(off-whi-CARD_DH)
            achg=T+MIN([C['U1']+tCOm+MIN(L('PC_ENABLE','U1-15',f'{u}-2'),L('X_ENABLE','U1-16',f'{u}-3'))+tPDm+L(f'ADDR{a}',f'{u}-{p}',f'{j}-{SA[a]}') for a,(u,p) in lo.items()])
            eh.append(achg+CARD_EH-whi)
        # the board's own I/O reads (I/O decode rev 07): line read F541 U29 (/OE1 = /P0, /OE2 = Q0), port PLD U38 and PS/2
        # PLD U42 (output enable from /PORT, Q0 and A1:A0), into D (U18)
        xaddr=lambda a,dst: C['U1']+tCO+L('X_ENABLE','U1-16',f'{mux[a][0]}-3')+tPD+L(f'ADDR{a}',f'{mux[a][0]}-{mux[a][1]}',dst)
        p0=tU12+tPD+L('~{P0}','U12-17','U29-1')
        en29=MAX(p0,tQ0+L('Q0','U1-18','U29-19'))+9.5
        R['io_line_read']=MIN([T+C['U18']-(en29+L(f'DATABUS{i}',f'U29-{18-i}',dests['U18'][i])+setup['U18']) for i in range(8)])
        pr=[]
        for u,pp,pq,pa0,pa1,outs in (('U38','2','15','3','14',{5:'21',6:'22',7:'23'}),('U42','3','7','5','6',{i:str(16+i) for i in range(8)})):
            en=MAX(tU12+tPD+L('~{PORT}','U12-20',f'{u}-{pp}'),tQ0+L('Q0','U1-18',f'{u}-{pq}'),xaddr(0,f'{u}-{pa0}'),xaddr(1,f'{u}-{pa1}'))+tPD
            for i,o in outs.items(): pr.append(T+C['U18']-(en+L(f'DATABUS{i}',f'{u}-{o}',dests['U18'][i])+setup['U18']))
        R['io_port_read']=MIN(pr)
        R['slot_read']=MIN(rd); R['slot_write_select']=MIN(wr); R['slot_write_data']=MIN(wd)
        R['slot_data_hold']=MIN(dh); R['slot_select_hold']=MIN(eh)
    return R
HOLD={'addr_hold','data_hold','port_sel_hold','slot_data_hold','slot_select_hold'}

def main():
    pcb,out=sys.argv[1:3]
    B=tracklen.Board(pcb); CART=json.load(open(os.path.join(TOOLS,'timing','cart_c64.json')))
    forms=collections.defaultdict(list)
    for d in DUTY:
        for k,x in model(T*d,CART).items():
            if x.s>0: raise SystemExit(f'{k}: slack is a max of forms')
            forms[k]+=x.f
    # net names that changed on the board (schematic 2026-11-02: /Control/Q0 became the global Q0)
    alias={'/Control/Q0':'Q0'}
    ren=lambda k: (alias[k[0]],k[1],k[2]) if k[0] not in B.nid and alias.get(k[0]) in B.nid else k
    for fl in forms.values():
        for f in fl: f.t={ren(k):v for k,v in f.t.items()}
    keys={k for fl in forms.values() for f in fl for k in f.t}
    missing=sorted({k[0] for k in keys if k[0] not in B.nid})
    if missing: raise SystemExit(f'nets of the timing model missing on the board: {missing}')
    cur=tracklen.measure(B,keys)
    def man(k):
        a=B.padxy.get(k[1]); b=B.padxy.get(k[2])
        if a is None or b is None: raise SystemExit(f'pad missing on the board: {k}')
        return abs(a[0]-b[0])+abs(a[1]-b[1])
    M={k:man(k) for k in keys}
    def now(k):
        if FIXFORCE and k in FIXLEN: return FIXLEN[k]
        if cur[k] is not None: return cur[k]
        return FIXLEN.get(k,M[k])
    unrouted=sorted({k[0] for k in keys if cur[k] is None})
    if unrouted: print(f'not routed (straight distance used): {len(unrouted)} nets'+(f'; fixed lengths {FIXLEN}' if any(k in FIXLEN for k in keys if cur[k] is None) else ''))
    cap=collections.defaultdict(lambda:1e9); report={}; infeas=[]
    for name,fl in forms.items():
        worst=1e9; snow=1e9; cnt=0
        for f in fl:
            s_now=f.c+sum(v*now(k) for k,v in f.t.items()); snow=min(snow,s_now)
            if name in HOLD: continue
            const=f.c; hurt={}
            for k,v in f.t.items():
                if k[0] in FIXED or ':'.join(k) in FIXED: const+=v*now(k)   # fixed net or pair (the CLK_E delay lead): its present length
                elif v>0: const+=v*(M[k] if HELP=='man' else now(k))   # a length that helps (later capture clock): straight distance, the safe bound
                else: hurt[k]=-v
            if not hurt: continue
            cnt+=1
            den=sum(c*max(M[k],FLOOR) for k,c in hurt.items()); r=(const-MARGIN)/den
            worst=min(worst,r)
            if r<1.0: infeas.append((name,r,const-MARGIN,sorted(hurt,key=lambda k:-M[k])[:4]))
            if r>RMAX: continue
            rr=max(r,RFEAS) if r<RFEAS else r
            for k in hurt: cap[k]=min(cap[k],rr*max(M[k],FLOOR) if r>=RFEAS else max(RFEAS*M[k],FLOOR))
        report[name]=dict(worst_ratio=round(worst,3) if worst<1e9 else None,forms=cnt,slack_now=round(snow,2))
    mx={}
    for k,v in cap.items():
        if v>=1e9: continue
        mx.setdefault(k[0],{}).setdefault(k[1],{})[k[2]]=round(v,1)
    mn={}
    for net,a,b,mm in MINLEN: mn.setdefault(net,{}).setdefault(a,{})[b]=float(mm)
    viol=[(k,round(cur[k],1),round(v,1)) for k,v in cap.items() if v<1e9 and cur[k] is not None and cur[k]>v]
    json.dump(dict(board=os.path.basename(pcb),margin_ns=MARGIN,duty=DUTY,fixed=sorted(FIXED),max=mx,min=mn,checks=report),open(out,'w'),indent=1)
    print(f'{len(cap)} budgeted lengths on {len(mx)} nets, margin {MARGIN} ns, duty {DUTY}')
    for name,r in report.items(): print(f"  {name:22s} slack now {r['slack_now']:7.2f} ns   worst detour ratio {r['worst_ratio']}   forms {r['forms']}")
    cnt=collections.Counter(t[0] for t in infeas)
    for name,k in cnt.items(): print(f'  INFEASIBLE {name}: {k} forms cannot keep the margin even at straight-line lengths')
    for name,r,room,ks in sorted(infeas,key=lambda t:t[1])[:6]:
        print(f'    worst {name}: ratio {r:.2f}, room {room:.2f} ns; longest hops {[f"{k[0]} {k[1]}->{k[2]} {M[k]:.0f}mm" for k in ks]}')
    print(f'{len(viol)} present lengths over budget' + (':' if viol else ''))
    for k,c,v in sorted(viol,key=lambda t:t[2]-t[1])[:25]: print(f'  {k[0]} {k[1]}->{k[2]}: {c} mm > {v} mm')
if __name__=='__main__': main()
