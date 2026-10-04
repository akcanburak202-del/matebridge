import argparse, csv, statistics as st
# Constant-playout-delay replay of a pace trace. Reference for the client's ConstantPlayoutPacer (T-080).
# Default: the 60 Hz table. --hz 120: 120 Hz rows and continuity. --idle-ms/--refill: the client's idle rule
# (window cleared after a ready gap > idle-ms, C kept, C may only rise until the window holds `refill` samples).
# --q/--L/--hold: one run instead of the table. --holds (T-208, T-220, T-225): the client's presentation metric (hold of
# each shown frame against its content cadence, the `skip_pct` rules) on a trace: from the frame-rendered callback times
# (`cb_ns` column, T-225) when the trace has them, else from the vsync each frame was released for (T-220's latch model;
# --latch forces it); --holds-selftest checks it on synthetic traces (the first vector is the one of the JVM test
# PresentationMetricTest.simSelfTestVector).
ap=argparse.ArgumentParser(); ap.add_argument('trace',nargs='?'); ap.add_argument('--hz',type=int,default=60)
ap.add_argument('--idle-ms',type=float,default=None); ap.add_argument('--refill',type=int,default=32)
ap.add_argument('--q',type=float); ap.add_argument('--L',type=float,default=6.0); ap.add_argument('--hold',type=float,default=2.0)
ap.add_argument('--holds',action='store_true',help='T-208/T-220: presentation metric of the released frames instead of the replay')
ap.add_argument('--holds-selftest',action='store_true',help='T-220: check --holds on a synthetic trace')
ap.add_argument('--latch',action='store_true',help='T-225: with --holds, use the release-time latch model even when the trace has cb_ns')
a=ap.parse_args()
import math
from collections import Counter
VISIBLE=('release','move')
MAX_NS=2**63-1 # Long.MAX_VALUE: the codec's callback had no usable time
def jround(x): return math.floor(x+0.5) # Kotlin Math.round
class HoldMeter:
    """T-220: the client's presentation metric, rule for rule (VideoStats.kt `HoldMeter`; keep both in step).
    Decoded frames (every trace row, in record order = decode order) form content runs: capture gaps within 1 ms of
    the run's first gap. A released frame is reported with the vsync it was released for (latch()). Two shown frames
    are judged when the later one's run reaches back to the earlier one, the panel rate is the same (5 %), and the run
    gap is n periods +- 1 ms (1 <= n <= 3): hold < n short, = n exact, > n long (a frame dropped in between makes its
    predecessor's hold long). A release for the same vsync as the previous one replaces it (never shown), so an
    interval is judged only when the next release confirms it (the last one of a trace never is)."""
    TOL=1_000_000; MAX_N=3; DEC_MAX=64
    def __init__(s): s.reset()
    def reset(s):
        s.dec=[]; s.last_dec=None; s.run_start=None; s.run_gap=0; s.brk()
    def brk(s): s.last=None; s.prev=None
    def decoded(s,cap):
        if s.last_dec is not None and cap>s.last_dec:
            g=(cap-s.last_dec)*1000
            if s.run_gap==0 or abs(g-s.run_gap)>s.TOL: s.run_start=s.last_dec; s.run_gap=g
        else: s.run_start=cap; s.run_gap=0
        s.last_dec=cap; s.dec.append((cap,s.run_start,s.run_gap)); del s.dec[:-s.DEC_MAX]
    def presented(s,cap,slot,P):
        """Returns (hz, n, hold) of the interval this release confirms (hz of THAT interval), or None (not judged)."""
        if s.last is not None:
            d=slot-s.last[1]
            if abs(d)<P//2: s.last=(cap,slot,P); return None
            if d<0: s.prev=None; s.last=(cap,slot,P); return None
        v=None
        if s.last is not None:
            if s.prev is not None: v=s.judge()
            s.prev=s.last
        s.last=(cap,slot,P); return v
    def judge(s):
        (pc,ps,pp),(lc,ls,lp)=s.prev,s.last
        if abs(pp-lp)*20>lp: return None
        e=next((x for x in reversed(s.dec) if x[0]==lc),None)
        if e is None: return None
        _,start,g=e
        if g<=0 or start is None or pc<start or pc>=lc: return None
        n=jround(g/lp)
        if n<1 or n>s.MAX_N or abs(g-n*lp)>s.TOL: return None
        return round(1e9/lp),n,jround((ls-ps)/lp)
def latch(x):
    """Older traces (no `latch_slot_ns`): the vsync a released row was due on, rebuilt like HoldMeter.latchSlot from the
    schedule-time grid (can differ from the client's release-time grid across a panel-rate change)."""
    req=int(x['released_slot_ns']); P=int(x['period_ns']); last=int(x.get('now_vsync_last_ns') or 0)
    rel=int(x.get('release_ns') or 0); dl=int(x.get('deadline_ns') or 0)
    if last<=0 or rel<=0 or P<=0: return req
    t=rel+dl
    earliest=last if t<=last else last+(t-last+P-1)//P*P
    return earliest if req<earliest-P//2 else req
def holds_cb(rows):
    """T-225: the metric on the frame-rendered callback times (`cb_ns`, the codec's own nanoTime; `skip_pct` on the
    client). A frame is decoded at its `ready_ns` and shown at its `cb_ns`; the two kinds of event are merged by time
    (a callback follows its decode), a row with no callback was dropped by the compositor and is simply not shown, so
    its predecessor's hold comes out long. The period is the one the client judged the callback with (`cb_period_ns`: the
    panel period at the callback's delivery; older traces: `latch_period_ns`, the one at the release, else `period_ns`).
    A `cb_ns` of Long.MAX_VALUE (the codec had no usable time) breaks the shown sequence, like the client (it has no time
    of its own: it is placed one median decode->callback lag after its decode); a callback with no usable period is not
    judged. Rows with no `ready_ns` (received but never decoded) are no decoded frame."""
    lags = sorted(int(x['cb_ns']) - int(x['ready_ns']) for x in rows
                  if 0 < int(x.get('cb_ns') or 0) < MAX_NS and int(x.get('ready_ns') or 0) > 0)
    lag = lags[len(lags) // 2] if lags else 0
    ev = []
    for i, x in enumerate(rows):
        cap = int(x['capture_us']); rdy = int(x.get('ready_ns') or 0); cb = int(x.get('cb_ns') or 0)
        if rdy > 0: ev.append((rdy, 0, i, cap, 0))
        if cb >= MAX_NS:
            if rdy > 0: ev.append((rdy + lag, 2, i, cap, 0))
        elif cb > 0:
            P = int(x.get('cb_period_ns') or 0) or int(x.get('latch_period_ns') or 0) or int(x.get('period_ns') or 0)
            if P > 0: ev.append((cb, 1, i, cap, P))
    ev.sort(); m = HoldMeter(); groups = {}
    for t, kind, i, cap, P in ev:
        if kind == 0: m.decoded(cap); continue
        if kind == 2: m.brk(); continue
        v = m.presented(cap, t, P)
        if v: groups.setdefault((v[0], v[1]), Counter())[v[2]] += 1
    return groups
def holds(rows, source='auto'):
    """rows: every scheduled frame of a trace, in record order. Returns {(hz, n): Counter(hold)} of the judged
    intervals. T-225: with callback times in the trace (and source != 'latch') the metric is [holds_cb]; otherwise,
    with the client's own `latch_slot_ns`/`latch_period_ns` (traces since T-220's review) every released row
    counts with exactly the client's vsync and period, a row released at once ('now') too. Older traces: the vsync is
    rebuilt from the schedule-time grid and a 'now' row (no slot) breaks the shown sequence."""
    if source != 'latch' and any(int(x.get('cb_ns') or 0) for x in rows): return holds_cb(rows)
    m=HoldMeter(); groups={}
    for x in rows:
        m.decoded(int(x['capture_us']))
        own=int(x.get('latch_slot_ns') or 0); ownP=int(x.get('latch_period_ns') or 0)
        if own and ownP: v=m.presented(int(x['capture_us']),own,ownP)
        elif x['action']=='now': m.brk(); continue
        elif x['action'] not in VISIBLE or x['released_slot_ns'] in ('','0'): continue
        else: v=m.presented(int(x['capture_us']),latch(x),int(x['period_ns']))
        if v: groups.setdefault((v[0],v[1]),Counter())[v[2]]+=1
    return groups
def holds_lines(groups):
    judged=long=0
    for (hz,n),c in sorted(groups.items()):
        tot=sum(c.values()); ex=c[n]; sh=sum(v for h,v in c.items() if h<n); lo=sum(v for h,v in c.items() if h>n)
        judged+=tot; long+=lo
        yield (f'{hz} Hz, cadence {n}: {tot} intervals, exact {100*ex/tot:.1f}%, short {100*sh/tot:.1f}%, long {100*lo/tot:.1f}%, '
               'holds '+' '.join(f'{h}:{100*v/tot:.1f}%' for h,v in sorted(c.items())))
    if judged: yield f'skip_pct (long holds, the client metric): {100*long/judged:.1f}% of {judged} judged'
if a.holds_selftest:
    # 60 fps on 120 Hz, 100 frames: every 10th replaced (never shown), frame 50 handed over 4 ms after its slot's
    # deadline (due one vsync later: frame 49 held 3, frame 50 held 1). Judged 88 (the last release is unconfirmed):
    # 10 long 4-vsync holds over a dropped frame, one long 3, one short 1, 76 exact.
    P=8_333_333; rows=[]
    for k in range(100):
        dropped=k%10==5; slot=10**9+k*2*P
        rows.append({'capture_us':str(k*16_667),'period_ns':str(P),'action':'replace' if dropped else 'release',
                     'released_slot_ns':'0' if dropped else str(slot),'now_vsync_last_ns':str(10**9),'deadline_ns':'6000000',
                     'release_ns':str(slot-6_000_000+4_000_000 if k==50 else slot-10_000_000)})
    g=holds(rows); c=g[(120,2)]
    assert list(g)==[(120,2)] and sum(c.values())==88 and c[2]==76 and c[4]==10 and c[3]==1 and c[1]==1, g
    for line in holds_lines(g): print('holds self-test OK: '+line)
    # A trace with the client's latch columns across a 120 -> 60 Hz change. Frames 40 and 41 were scheduled on the old
    # grid (their period_ns / released_slot_ns are 120 Hz ones) but released on the new one: only latch_* count. Frame
    # 60 was released at once ('now'). The interval 38 -> 39 is confirmed by frame 40 and stays a 120 Hz one; 39 -> 40
    # spans the change and is not judged. Expected: 120 Hz cadence 2: 39 exact; 60 Hz cadence 1: 38 exact.
    P1=8_333_333; P2=16_666_667; rows=[]
    for k in range(80):
        if k<40: slot=10**9+k*2*P1; lp=P1; per=P1; rs=slot; act='release'
        else: slot=10**9+80*P1+(k-39)*P2; lp=P2; per=P1 if k<42 else P2; rs=slot-P2+P1 if k<42 else slot; act='release'
        if k==60: act='now'; rs=0; per=0
        rows.append({'capture_us':str(k*16_667),'period_ns':str(per),'action':act,'released_slot_ns':str(rs),
                     'now_vsync_last_ns':str(10**9),'deadline_ns':'6000000','release_ns':str(slot-10_000_000),
                     'latch_slot_ns':str(slot),'latch_period_ns':str(lp)})
    g=holds(rows)
    assert {k:dict(v) for k,v in g.items()}=={(120,2):{2:39},(60,1):{1:38}}, g
    for line in holds_lines(g): print('holds self-test OK (latch columns): '+line)
    # T-225: callback times. 60 fps on 120 Hz, 100 frames decoded 20 ms after capture; the latch columns say 3,1,3,1...
    # (a release call returning past the old cut) but the callbacks are regularly 2 vsyncs apart. Frame 40 never gets a
    # callback (dropped by the compositor): frame 39 is held 4 vsyncs, one long. 99 frames are shown and the first two
    # of them judge nothing: 97 intervals, 96 exact and 1 long.
    P=8_333_333; rows=[]
    for k in range(100):
        cb=10**9+k*2*P+51_000_000; lat=10**9+(k//2)*4*P+(0 if k%2==0 else 3*P)
        rows.append({'capture_us':str(k*16_667),'ready_ns':str(10**9+k*2*P+20_000_000),'period_ns':str(P),'action':'release',
                     'released_slot_ns':str(lat),'latch_slot_ns':str(lat),'latch_period_ns':str(P),'cb_ns':'0' if k==40 else str(cb)})
    g=holds(rows); c=g[(120,2)]
    assert list(g)==[(120,2)] and sum(c.values())==97 and c[2]==96 and c[4]==1, g
    for line in holds_lines(g): print('holds self-test OK (callback times): '+line)
    g=holds(rows,'latch'); assert sum(v for k,v in g[(120,2)].items() if k!=2)>50, g
    for line in holds_lines(g): print('holds self-test OK (--latch, same rows): '+line)
    # T-225 review 1: a callback with the Long.MAX_VALUE sentinel (frame 30) breaks the shown sequence, as in the client,
    # instead of being a frame shown at the end of time (which made the 16.7% skips of the review's repro).
    def regular(n=100):
        return [{'capture_us':str(k*16_667),'ready_ns':str(10**9+k*2*P+20_000_000),'period_ns':str(P),'action':'release',
                 'released_slot_ns':'0','latch_period_ns':str(P),'cb_ns':str(10**9+k*2*P+51_000_000)} for k in range(n)]
    g0=holds(regular()); assert dict(g0[(120,2)])=={2:98}, g0
    sent=regular(); sent[30]['cb_ns']=str(MAX_NS)
    g1=holds(sent); c1=g1[(120,2)]; assert list(c1)==[2] and 92<=c1[2]<=96, g1 # no long, no short: only the sequence around 30 is cut
    for line in holds_lines(g1): print('holds self-test OK (callback sentinel breaks the sequence): '+line)
    # T-225 review 2: the callback is judged with the period current at its delivery (`cb_period_ns`), not the release's.
    # Frames 0..49 on a 120 Hz panel; from frame 50 the callbacks are delivered on the 60 Hz grid while latch_period_ns
    # (the release's) is still the 120 Hz one: only cb_period_ns gives the right cadence for them.
    P2=16_666_667; rows=[]
    for k in range(100):
        cb=10**9+k*2*P+51_000_000 if k<50 else 10**9+100*P+(k-49)*P2+51_000_000
        rows.append({'capture_us':str(k*16_667),'ready_ns':str(10**9+k*2*P+20_000_000),'period_ns':str(P),'action':'release',
                     'released_slot_ns':'0','latch_period_ns':str(P),'cb_period_ns':str(P if k<50 else P2),'cb_ns':str(cb)})
    g=holds(rows); assert {k:dict(v) for k,v in g.items()}=={(120,2):{2:49},(60,1):{1:48}}, g
    for line in holds_lines(g): print('holds self-test OK (cb_period_ns): '+line)
    for x in rows: del x['cb_period_ns'] # an older trace: latch_period_ns stands in, the 60 Hz frames are misjudged as 120 Hz holds of 2
    g=holds(rows); assert (60,1) not in g, g
    for line in holds_lines(g): print('holds self-test OK (older trace falls back to latch_period_ns): '+line)
    raise SystemExit
if a.trace is None: ap.error('trace is required')
if a.holds:
    # The client's presentation metric (see HoldMeter / holds()): per panel rate and content cadence n of the judged
    # interval, the hold distribution; exact = held n vsyncs. Then ready->slot p50 and paths (schedule-time values).
    allrows=list(csv.DictReader(open(a.trace)))
    t=[x for x in allrows if x['action'] in VISIBLE and x['released_slot_ns'] not in ('','0')]
    paths=Counter(); lat={}
    for x in t:
        hz=round(1e9/int(x['period_ns'])); paths[(hz,x['path'])]+=1
        lat.setdefault(hz,[]).append((int(x['released_slot_ns'])-int(x['ready_ns']))/1e6)
    src = 'latch' if a.latch else 'auto'
    print('source: ' + ('callback times (cb_ns)' if src != 'latch' and any(int(x.get('cb_ns') or 0) for x in allrows) else 'release-time latch model'))
    for line in holds_lines(holds(allrows, src)): print(line)
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
