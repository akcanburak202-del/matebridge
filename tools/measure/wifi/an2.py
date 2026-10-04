# an2.py ROW... — per-row summary from ~/.cache/matebridge-tools/data/wifi-runs/ROW.host.log (+ ROW.tablet.log if present).
# Host: control/video srtt (ev=tcp), tablet-reported cap_dec_ms/dropped (net ev=stats), retx, idr.
# Tablet: audio underruns (cumulative counter: max-min), render skip_pct and fps medians.
import os, re, statistics as st, sys
O = os.path.expanduser('~/.cache/matebridge-tools/data/wifi-runs')
def q(v, p):
    v = sorted(v); return v[min(len(v) - 1, int(p * len(v)))] if v else float('nan')
def f(l, k):
    m = re.search(r'\b' + k + r'=(-?[\d.]+)', l); return float(m.group(1)) if m else None
def col(L, flt, k): return [x for x in (f(l, k) for l in L if flt(l)) if x is not None]
print('%-14s | %5s %5s %5s | %5s %5s | %5s %5s %5s | %4s %4s %5s | %5s %5s %5s %5s' % (
    'row', 'c50', 'c95', 'cmax', 'v95', 'vmax', 'cd50', 'cd95', 'cdmx', 'retx', 'idr', 'drop', 'under', 'skip', 'fps', 'kbps'))
for n in sys.argv[1:]:
    H = open(f'{O}/{n}.host.log', errors='ignore').read().splitlines()
    c = col(H, lambda l: 'ev=tcp ' in l and 'conn=control' in l, 'srtt_ms')
    v = col(H, lambda l: 'ev=tcp ' in l and 'conn=video' in l, 'srtt_ms')
    retx = sum(col(H, lambda l: 'ev=tcp ' in l, 'retx_pkts_delta'))
    NS = lambda l: ' net ' in l and 'ev=stats' in l
    cd = [x for x in col(H, NS, 'cap_dec_ms') if x > 0]
    drop = sum(col(H, NS, 'dropped')); idr = sum(col(H, NS, 'idr')); kb = col(H, NS, 'sent_kbps')
    under = skip = fps = '-'
    tp = f'{O}/{n}.tablet.log'
    if os.path.exists(tp):
        T = open(tp, errors='ignore').read().splitlines()
        au = col(T, lambda l: 'MB/audio' in l and 'ev=stats' in l, 'underruns'); under = '%d' % (max(au) - min(au)) if au else '-'
        sk = col(T, lambda l: 'MB/render' in l and 'ev=stats' in l, 'skip_pct'); skip = '%.1f' % st.median(sk) if sk else '-'
        fp = col(T, lambda l: 'MB/render' in l and 'ev=stats' in l, 'fps'); fps = '%.1f' % st.median(fp) if fp else '-'
    print('%-14s | %5.0f %5.0f %5.0f | %5.0f %5.0f | %5.0f %5.0f %5.0f | %4.0f %4.0f %5.0f | %5s %5s %5s %5.0f' % (
        n, q(c, .5), q(c, .95), max(c or [0]), q(v, .95), max(v or [0]), q(cd, .5), q(cd, .95), max(cd or [0]),
        retx, idr, drop, under, skip, fps, q(kb, .5)))
