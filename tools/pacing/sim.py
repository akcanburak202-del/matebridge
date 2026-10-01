import csv, sys, statistics as st
rows=[x for x in csv.DictReader(open(sys.argv[1])) if x['period_ns'].startswith('1666')]
I=int
cap=[I(x['capture_us'])*1000 for x in rows]; rdy=[I(x['ready_ns']) for x in rows]
vs=[I(x['now_vsync_last_ns']) for x in rows]; P=[I(x['period_ns']) for x in rows]
cont=[False]+[abs((cap[i]-cap[i-1])-16_666_667)<1_000_000 for i in range(1,len(cap))]
def gridceil(t,last,p): return last + -(-(t-last)//p)*p
def run(q, L, hold_ms=2.0, win=256, policy='const'):
    xs=[]; C=None; prev=None; lat=[]; gaps=0; drops=0; late=0; shown=0
    for i in range(len(rows)):
        x=rdy[i]-cap[i]; xs.append(x); w=xs[-win:]
        base=min(w); devs=sorted(v-base for v in w); J=devs[min(len(devs)-1,int(len(devs)*q))]
        Cn=base+J
        if C is None or abs(Cn-C)>hold_ms*1e6: C=Cn
        if policy=='asap': C=x  # no buffering: target = ready
        t=cap[i]+C+L
        s=gridceil(max(t,rdy[i]+L),vs[i],P[i])  # can't be before ready+L
        if rdy[i]+L> cap[i]+C+L: late+=1
        if prev is not None:
            if s<=prev: drops+=1; continue   # same slot: replaces previous -> one content frame lost
            if s-prev>P[i]*1.5 and cont[i]: gaps+=1
        prev=s; shown+=1; lat.append((s-rdy[i])/1e6)
    n=sum(cont)
    return f'q={q} L={L/1e6:.1f} hold={hold_ms}: lat p50={st.median(lat):.1f} ms, gaps={100*gaps/n:.1f}%, dropped={100*drops/n:.1f}%, late={100*late/n:.1f}%'
print(run(0,6e6,policy='asap'))
for L in (6e6,13.333e6):
    for q in (0.5,0.8,0.9,0.95,0.98,0.99):
        print(run(q,L))
