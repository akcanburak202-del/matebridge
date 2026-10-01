import argparse, csv, statistics as st
# Constant-playout-delay replay of a pace trace. Reference for the client's ConstantPlayoutPacer (T-080).
# Default: the 60 Hz table. --hz 120: 120 Hz rows and continuity. --idle-ms/--refill: the client's idle rule
# (window cleared after a ready gap > idle-ms, C kept, C may only rise until the window holds `refill` samples).
# --q/--L/--hold: one run instead of the table.
ap=argparse.ArgumentParser(); ap.add_argument('trace'); ap.add_argument('--hz',type=int,default=60)
ap.add_argument('--idle-ms',type=float,default=None); ap.add_argument('--refill',type=int,default=32)
ap.add_argument('--q',type=float); ap.add_argument('--L',type=float,default=6.0); ap.add_argument('--hold',type=float,default=2.0)
a=ap.parse_args()
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
