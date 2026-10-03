import argparse, csv, statistics as st
# Constant-playout-delay replay of a pace trace. Reference for the client's ConstantPlayoutPacer (T-080).
# Default: the 60 Hz table. --hz 120: 120 Hz rows and continuity. --idle-ms/--refill: the client's idle rule
# (window cleared after a ready gap > idle-ms, C kept, C may only rise until the window holds `refill` samples).
# --q/--L/--hold: one run instead of the table. --holds (T-208): hold distribution of a trace's released frames;
# --holds-selftest checks it on a synthetic trace with drops.
ap=argparse.ArgumentParser(); ap.add_argument('trace',nargs='?'); ap.add_argument('--hz',type=int,default=60)
ap.add_argument('--idle-ms',type=float,default=None); ap.add_argument('--refill',type=int,default=32)
ap.add_argument('--q',type=float); ap.add_argument('--L',type=float,default=6.0); ap.add_argument('--hold',type=float,default=2.0)
ap.add_argument('--holds',action='store_true',help='T-208: hold distribution of the released frames instead of the replay')
ap.add_argument('--holds-selftest',action='store_true',help='T-208: check --holds on a synthetic trace with drops')
a=ap.parse_args()
from collections import Counter
VISIBLE=('release','move')
def holds(rows):
    """T-208. rows: every scheduled frame of a trace, in record order. Returns {(hz, n): Counter(hold)}.
    The content cadence n comes from the ORIGINAL capture sequence (all decoded frames, also the replaced/discarded
    ones): a pair of consecutive visible frames counts only when every capture gap from the first to the second is
    n*P +- 1 ms (same n, same period). Its hold (released_slot_ns distance in vsyncs) is then compared to n, so a
    frame dropped in between shows up as a long hold (2n) instead of hiding behind a wider capture gap."""
    vis=[i for i,x in enumerate(rows) if x['action'] in VISIBLE and x['released_slot_ns'] not in ('','0')]
    groups={}
    for i,j in zip(vis,vis[1:]):
        P=int(rows[i]['period_ns'])
        if any(int(rows[k]['period_ns'])!=P for k in range(i,j+1)): continue
        if any(rows[k]['action']=='now' for k in range(i+1,j)): continue # unpaced frame in between: no planned slot
        gaps=[(int(rows[k+1]['capture_us'])-int(rows[k]['capture_us']))*1000 for k in range(i,j)]
        n=round(gaps[0]/P)
        if n<1 or n>3 or any(abs(g-n*P)>1_000_000 for g in gaps): continue
        hold=round((int(rows[j]['released_slot_ns'])-int(rows[i]['released_slot_ns']))/P)
        groups.setdefault((round(1e9/P),n),Counter())[hold]+=1
    return groups
def holds_lines(groups):
    for (hz,n),c in sorted(groups.items()):
        tot=sum(c.values()); ex=c[n]
        yield f'{hz} Hz, cadence {n}: {tot} intervals, exact {100*ex/tot:.1f}%, holds '+' '.join(f'{h}:{100*v/tot:.1f}%' for h,v in sorted(c.items()))
if a.holds_selftest:
    # 60 fps on 120 Hz, 100 frames, every 10th replaced by its successor (newest wins): 89 visible intervals,
    # 79 held 2 vsyncs, 10 held 4 (the dropped frame's slot is the next one's). Must not report 100 % exact.
    P=8_333_333; rows=[]
    for k in range(100):
        dropped=k%10==5
        rows.append({'capture_us':str(k*16_667),'period_ns':str(P),'action':'replace' if dropped else 'release',
                     'released_slot_ns':'0' if dropped else str(10**9+k*2*P)})
    c=holds(rows)[(120,2)]
    assert sum(c.values())==89 and c[2]==79 and c[4]==10, c
    print('holds self-test OK: '+next(holds_lines({(120,2):c})))
    raise SystemExit
if a.trace is None: ap.error('trace is required')
if a.holds:
    # Planned hold of each released frame (released_slot_ns distance to the previous released frame, in vsyncs),
    # per panel rate and content cadence n (see holds()). Exact = held n vsyncs.
    allrows=list(csv.DictReader(open(a.trace)))
    t=[x for x in allrows if x['action'] in VISIBLE and x['released_slot_ns'] not in ('','0')]
    paths=Counter(); lat={}
    for x in t:
        hz=round(1e9/int(x['period_ns'])); paths[(hz,x['path'])]+=1
        lat.setdefault(hz,[]).append((int(x['released_slot_ns'])-int(x['ready_ns']))/1e6)
    for line in holds_lines(holds(allrows)): print(line)
    for hz in sorted(lat):
        print(f'{hz} Hz: ready->slot p50 {st.median(lat[hz]):.1f} ms, paths '+' '.join(f'{p}={v}' for (h,p),v in sorted(paths.items()) if h==hz))
    raise SystemExit
pfx,step={60:('1666',16_666_667),120:('833',8_333_333)}[a.hz]
rows=[x for x in csv.DictReader(open(a.trace)) if x['period_ns'].startswith(pfx)]
I=int
cap=[I(x['capture_us'])*1000 for x in rows]; rdy=[I(x['ready_ns']) for x in rows]
vs=[I(x['now_vsync_last_ns']) for x in rows]; P=[I(x['period_ns']) for x in rows]
cont=[False]+[abs((cap[i]-cap[i-1])-step)<1_000_000 for i in range(1,len(cap))]
def gridceil(t,last,p): return last + -(-(t-last)//p)*p
def run(q, L, hold_ms=2.0, win=256, policy='const', idle_ms=None, refill=32):
    xs=[]; C=None; prev=None; lat=[]; gaps=0; drops=0; late=0; shown=0; lastr=None; refilling=False
    for i in range(len(rows)):
        if idle_ms is not None and lastr is not None and rdy[i]-lastr>idle_ms*1e6: xs=[]; refilling=C is not None
        lastr=rdy[i]
        x=rdy[i]-cap[i]; xs.append(x); w=xs[-win:]
        base=min(w); devs=sorted(v-base for v in w); J=devs[min(len(devs)-1,int(len(devs)*q))]
        Cn=base+J
        if C is None: C=Cn
        elif refilling and len(w)<refill:
            if Cn-C>hold_ms*1e6: C=Cn
        elif abs(Cn-C)>hold_ms*1e6: C=Cn
        if len(w)>=refill: refilling=False
        if policy=='asap': C=x  # no buffering: target = ready
        t=cap[i]+C+L
        s=gridceil(max(t,rdy[i]+L),vs[i],P[i])  # can't be before ready+L
        if rdy[i]+L> cap[i]+C+L: late+=1
        if prev is not None:
            if s<=prev: drops+=1; continue   # same slot: replaces previous -> one content frame lost
            if s-prev>P[i]*1.5 and cont[i]: gaps+=1
        prev=s; shown+=1; lat.append((s-rdy[i])/1e6)
    n=sum(cont)
    return f'q={q} L={L/1e6:.1f} hold={hold_ms}: lat p50={st.median(lat):.1f} ms, gaps={100*gaps/n:.1f}%, dropped={100*drops/n:.1f}%, late={100*late/n:.1f}%' \
        + (f' (lat p50={st.median(lat):.4f} ms, gaps {gaps}/{n} = {100*gaps/n:.4f}%)' if a.q is not None else '')
if a.q is not None:
    print(run(a.q,a.L*1e6,a.hold,idle_ms=a.idle_ms,refill=a.refill))
else:
    print(run(0,6e6,policy='asap',idle_ms=a.idle_ms,refill=a.refill))
    for L in (6e6,13.333e6):
        for q in (0.5,0.8,0.9,0.95,0.98,0.99):
            print(run(q,L,idle_ms=a.idle_ms,refill=a.refill))
