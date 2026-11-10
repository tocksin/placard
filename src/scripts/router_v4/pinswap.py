"""pinswap.py: pin-swap table for placeguide.py (Justin 2026-11-09: "layout goes hand in hand with changes to the schematic").

A swap group is a list of slots on one part; any two slots of a group may trade places, which moves the pads'
nets between pin positions without changing what the circuit does:
  * registers 74x377 / 74x273 / 74x574 and buffers 74x541: (D, Q) or (A, Y) pairs, a bit moves with its output;
  * SRAM AS7C256: address pins among themselves, data pins among themselves (every access goes through the same pins);
  * ATF22V10C PLDs: pins are programmable. A signal may move to any pin that can carry it: an input to any input
    or I/O pin, an output (or registered output) to an I/O pin whose OLMC has enough product terms
    (14/23: 8, 15/22: 10, 16/21: 12, 17/20: 14, 18/19: 16). Pin 1 (clock / input) and power stay put.
    Product terms are estimated from the .pld equations (intermediate names expanded, sum of products of the
    function or its complement, whichever is smaller; never more than the pin it compiles on today).
ROMs are left out: reordering their pins means reordering the image.
Swaps are suggestions only: applying one needs the schematic (and for a PLD the PIN lines) changed and rechecked.
"""
import os, re, glob, itertools

PLD_DIR = os.environ.get('PLDDIR') or os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'pld')       # the .pld sources
SCH_DIR = os.environ.get('SCHDIR') or os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', 'kicad')  # the schematic sheets (part types)
PTCAP = {14: 8, 23: 8, 15: 10, 22: 10, 16: 12, 21: 12, 17: 14, 20: 14, 18: 16, 19: 16}
INPUT_ONLY = set(range(2, 12)) | {13}
REG377 = [(3, 2), (4, 5), (7, 6), (8, 9), (13, 12), (14, 15), (17, 16), (18, 19)]   # (D, Q)
REG574 = [(2 + k, 19 - k) for k in range(8)]
BUF541 = [(2 + k, 18 - k) for k in range(8)]                                         # (A, Y)
SRAM_A = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 21, 23, 24, 25, 26]
SRAM_D = [11, 12, 13, 15, 16, 17, 18, 19]
MAXT = 64

# ---------------------------------------------------------------- CUPL equations -> product-term estimate
def _tok(s):
    return re.findall(r'[A-Za-z_][A-Za-z_0-9]*|[!&#$()]|\'[bBhH]\'[01]', s)

class _P:
    """CUPL precedence: ! > & > # > $"""
    def __init__(self, t): self.t = t; self.i = 0
    def peek(self): return self.t[self.i] if self.i < len(self.t) else None
    def take(self): self.i += 1; return self.t[self.i - 1]
    def xor(self):
        a = self.orr()
        while self.peek() == '$': self.take(); a = ('x', a, self.orr())
        return a
    def orr(self):
        a = self.andd()
        while self.peek() == '#': self.take(); a = ('o', a, self.andd())
        return a
    def andd(self):
        a = self.un()
        while self.peek() == '&': self.take(); a = ('a', a, self.un())
        return a
    def un(self):
        t = self.take()
        if t == '!': return ('n', self.un())
        if t == '(':
            a = self.xor(); assert self.take() == ')'; return a
        if t is None or t in '&#$)': raise ValueError('syntax')
        if t.startswith("'"): return ('c', t.endswith('1'))
        return ('v', t)

class _Big(Exception): pass

def _dnf(e, pos, env, depth=0):
    """set of terms (frozenset of (var, polarity)) for e (pos) or !e (not pos)"""
    if depth > 60: raise _Big()
    k = e[0]
    if k == 'c': return {frozenset()} if e[1] == pos else set()
    if k == 'v':
        if e[1] in env: return _dnf(env[e[1]], pos, env, depth + 1)
        return {frozenset([(e[1], pos)])}
    if k == 'n': return _dnf(e[1], not pos, env, depth + 1)
    if k == 'x':  # a $ b = a&!b # !a&b ; !(a$b) = a&b # !a&!b
        a, b = e[1], e[2]
        if pos: f = ('o', ('a', a, ('n', b)), ('a', ('n', a), b))
        else: f = ('o', ('a', a, b), ('a', ('n', a), ('n', b)))
        return _dnf(f, True, env, depth + 1)
    if (k == 'o') == pos:  # union
        return _clean(_dnf(e[1], pos, env, depth + 1) | _dnf(e[2], pos, env, depth + 1))
    A = _dnf(e[1], pos, env, depth + 1); B = _dnf(e[2], pos, env, depth + 1)
    if len(A) * len(B) > 4 * MAXT: raise _Big()
    return _clean({a | b for a in A for b in B})

def _clean(T):
    T = {t for t in T if not any((v, not p) in t for v, p in t)}
    if len(T) > 4 * MAXT: raise _Big()
    L = sorted(T, key=len); out = []
    for t in L:
        if not any(o <= t for o in out): out.append(t)
    # merge a&x # a&!x -> a (one pass, repeated)
    changed = True
    while changed and len(out) > 1:
        changed = False; S = set(out)
        for t in list(S):
            for v, p in t:
                u = (t - {(v, p)}) | {(v, not p)}
                if u in S and t in S:
                    S.discard(t); S.discard(u); S.add(t - {(v, p)}); changed = True; break
        out2 = []
        for t in sorted(S, key=len):
            if not any(o <= t for o in out2): out2.append(t)
        out = out2
    return set(out)

def parse_pld(path):
    s = open(path, encoding='utf-8', errors='replace').read()
    s = re.sub(r'/\*.*?\*/', ' ', s, flags=re.S)
    pins = {}; eqs = {}; ext = {}
    for st in s.split(';'):
        st = ' '.join(st.split())
        m = re.match(r'(?i)^PIN\s+(\d+)\s*=\s*(!?)\s*([A-Za-z_][A-Za-z_0-9]*)$', st)
        if m: pins[int(m.group(1))] = m.group(3); continue
        m = re.match(r'^(!?)\s*([A-Za-z_][A-Za-z_0-9]*)(\.[A-Za-z]+)?\s*=\s*(.+)$', st)
        if m and not re.match(r'(?i)^(name|partno|date|revision|designer|company|assembly|location|device)$', m.group(2)):
            nm, ex = m.group(2), (m.group(3) or '').upper()
            try: tree = _P(_tok(m.group(4))).xor()
            except Exception: tree = None
            if ex in ('', '.D', '.T'): eqs[nm] = tree
            else: ext.setdefault(nm, []).append(ex)
    return pins, eqs, ext

def pld_slots(path):
    """{pin: (kind, need)}: kind 'in' | 'out' | 'free' | 'fixed'; need = product terms for outputs"""
    pins, eqs, ext = parse_pld(path)
    pinnames = set(pins.values())
    env = {k: v for k, v in eqs.items() if k not in pinnames and v is not None}  # intermediate names
    out = {}
    for p in range(1, 25):
        if p in (1, 12, 24): out[p] = ('fixed', 0); continue
        nm = pins.get(p)
        if nm is None: out[p] = ('free', 0); continue
        if nm in eqs:
            cap = PTCAP.get(p, 0); tree = eqs[nm]
            try:
                if tree is None: raise _Big()
                need = min(len(_dnf(tree, True, env)), len(_dnf(tree, False, env)))
            except (_Big, RecursionError, KeyError):
                need = cap
            out[p] = ('out', max(1, min(need, cap)))
        else: out[p] = ('in', 0)
    return out

def pld_fits(kind, need, pin):
    if kind == 'fixed': return False
    if kind in ('in', 'free'): return pin not in (1, 12, 24)
    return pin in PTCAP and PTCAP[pin] >= need

# ---------------------------------------------------------------- swap table
def schematic_symbols():
    m = {}
    for f in glob.glob(os.path.join(SCH_DIR, '*.kicad_sch')):
        s = open(f, encoding='utf-8').read()
        for mm in re.finditer(r'\(lib_id "([^"]+)"\)(.{0,800}?)\(property "Reference" "([A-Z]+\d+)"', s, re.S):
            m[mm.group(3)] = mm.group(1).split(':')[-1]
    return m

def pld_file(sym):
    n = sym.upper().replace('ATF22V10C_', '')
    for f in glob.glob(os.path.join(PLD_DIR, '*.pld')):
        b = os.path.basename(f).upper()[:-4].replace('ATF22V10_', '')
        if b == n: return f
    return None

def table(B):
    """list of groups: dict(ref, part index, kind, slots=[tuple of pad indices], fits=f(slot_a, slot_b) or None)"""
    syms = schematic_symbols(); G = []
    for i, P in enumerate(B.parts):
        if not P.ref.startswith('U'): continue
        num = {}
        for j, p in enumerate(P.pads): num.setdefault(p['num'], j)
        def pads(t): return tuple(num[str(k)] for k in t) if all(str(k) in num for k in t) else None
        val = (P.lib + ' ' + syms.get(P.ref, '')).upper()
        sym = syms.get(P.ref, '')
        val2 = ''
        for fp in []: pass
        S = None; kind = ''
        if 'ATF22V10' in sym.upper():
            f = pld_file(sym)
            if not f: continue
            sl = pld_slots(f)
            slots = [(pads((p,)), sl[p]) for p in sorted(sl) if sl[p][0] != 'fixed' and pads((p,))]
            G.append(dict(ref=P.ref, i=i, kind='PLD ' + os.path.basename(f), slots=[s for s, _ in slots],
                          info={s: k for s, k in slots}, pins={s: int(P.pads[s[0]]['num']) for s, _ in slots}))
            continue
        v = sym.upper()
        if '377' in v or '273' in v: S, kind = REG377, 'register D/Q'
        elif '574' in v: S, kind = REG574, 'register D/Q'
        elif '541' in v: S, kind = BUF541, 'buffer A/Y'
        elif 'AS7C256' in v or '62256' in v:
            for nm, L in (('SRAM address', SRAM_A), ('SRAM data', SRAM_D)):
                sl = [pads((k,)) for k in L if pads((k,))]
                G.append(dict(ref=P.ref, i=i, kind=nm, slots=sl, info=None, pins={s: int(P.pads[s[0]]['num']) for s in sl}))
            continue
        if S:
            sl = [pads(t) for t in S if pads(t)]
            G.append(dict(ref=P.ref, i=i, kind=kind, slots=sl, info=None, pins={s: tuple(int(P.pads[j]['num']) for j in s) for s in sl}))
    return G

def can_swap(g, a, b):
    if g['info'] is None: return True
    ka, na = g['info'][a]; kb, nb = g['info'][b]
    if ka == 'free' and kb == 'free': return False
    pa, pb = g['pins'][a], g['pins'][b]
    return pld_fits(ka, na, pb) and pld_fits(kb, nb, pa)

if __name__ == '__main__':
    import sys
    for f in sorted(glob.glob(os.path.join(PLD_DIR, '*.pld'))):
        sl = pld_slots(f)
        print(os.path.basename(f), ' '.join(f'{p}:{k[0]}{k[1] if k[0]=="out" else ""}' for p, k in sorted(sl.items())))
