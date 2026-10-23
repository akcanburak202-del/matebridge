#!/usr/bin/env python3
"""Game-mode A/B summaries (T-364): per-arm report and the side-by-side table over all arms of one LABEL.

  game_ab.py arm DIR/LABEL/ARM-K [--runs N]     one recorded arm: header, arm_check, metrics
  game_ab.py summary DIR/LABEL                  every arm of the LABEL: arm_check per run, then ARM columns with
                                                median (min-max) over the repeats

An arm directory is written by tools/measure/game-ab.sh and holds only filtered (numeric) files:
meta.txt, tablet.txt, tablet_ident.txt, host.txt, host_ident.txt, mac.txt.

Definitions (docs/research/2026-10-23-game-modes.md "Olcum plani"):
- stall = a 1 Hz host `net ev=stats` sample with cap_dec_ms > 150 (NOTES 2026-10-20 22:30). Without such samples the
  tablet's 10 s windows are used: a window counts when its cap_dec_max_us > 150000 (a lower bound, it counts windows,
  not seconds); the summary says which one it used.
- "median of windows" rows (gpu_ms, cap_to_sent_ms, enc_ms) take the median over the host's 1 s latency windows of
  that window's p50 (or p95) value, not a percentile over frames.
- retx_pct_s = share of video-socket `ev=tcp` seconds with retx_pkts_delta > 0.

Injected stalls (T-366): an arm directory may also hold stalls.txt, written by tools/measure/stall-inject.sh
(`stall n= epoch_ms= mono_ms= end_mono_ms= ms= port=`; mono_ms is the host.log clock). Each stall gets an event
window of EVENT_S seconds on the host's 1 Hz samples: samples whose time is in (mono_ms, mono_ms + 5 s]. Per event:
- idr_5s: sum of `idr` of the `net ev=stats` samples; queue_drops_5s / overwritten_5s: sums of those fields of
  the `video ev=cadence` samples (both are per-second values); cap_dec_max_ms: largest `cap_dec_ms`.
- recover_s: seconds from the stall start to the first 1 Hz sample at or after the worst one whose cap_dec_ms is
  below RECOVER_MS (0 when the worst sample is already below); looked for until the next stall or 30 s. None =
  not recovered in that time.
- cwnd_kb / unacked_kb: `snd_cwnd` / `unacked_bytes` of the last video `ev=tcp` sample at most 2 s before the stall.
Per arm: median (min-max) over the events of all its runs.
"""

import argparse
import os
import re
import sys

sys.dont_write_bytecode = True  # no __pycache__ next to the tools
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mblog  # noqa: E402
import smoke  # noqa: E402

STALL_MS = 150.0
EVENT_S = 5.0
RECOVER_MS = 30.0
RECOVER_HORIZON_S = 30.0
CHROMA_ALIAS = {'normal': '420', 'sharp': 'sharp_nearest', 'full': 'packed444'}
# Mac process columns of macmon.sh that are not "the game".
MAC_KNOWN = ('cpu_user', 'cpu_sys', 'cpu_idle', 'cpu_MateBridgeApp', 'cpu_WindowServer', 'cpu_kernel_task')
FILES = ('meta.txt', 'tablet.txt', 'tablet_ident.txt', 'host.txt', 'host_ident.txt', 'mac.txt')


def read_meta(path):
    d = {}
    if os.path.exists(path):
        with open(path, errors='replace') as fh:
            for line in fh:
                k, sep, v = line.rstrip('\n').partition('=')
                if sep:
                    d[k.strip()] = v.strip()
    return d


def recs(path, side):
    return mblog.read_file_records(path, side=side) if os.path.exists(path) else []


class Arm:
    def __init__(self, path):
        self.path = path.rstrip('/')
        self.name = os.path.basename(self.path)
        self.meta = read_meta(os.path.join(self.path, 'meta.txt'))
        self.arm = self.meta.get('arm') or self.name.rsplit('-', 1)[0]
        self.k = int(self.meta.get('k') or (self.name.rsplit('-', 1)[1] if '-' in self.name else 0) or 0)
        self.t_ident = recs(os.path.join(self.path, 'tablet_ident.txt'), 'T')
        self.t_win = recs(os.path.join(self.path, 'tablet.txt'), 'T')
        self.h_ident = recs(os.path.join(self.path, 'host_ident.txt'), 'H')
        self.h_win = recs(os.path.join(self.path, 'host.txt'), 'H')
        self.stalls = read_stalls(os.path.join(self.path, 'stalls.txt'))
        self.mac = []
        mp =os.path.join(self.path, 'mac.txt')
        if os.path.exists(mp):
            with open(mp, errors='replace') as fh:
                self.mac = [d for d in map(mblog.parse_kv_line, fh) if d and 'ep' in d]

    def sel(self, recs_, comp, ev, **where):
        return [r for r in recs_ if r.comp == comp and r.ev == ev and all(r.f.get(k) == v for k, v in where.items())]


def vals(rs, getter):
    return [v for v in (getter(r) for r in rs) if v is not None]


def f(key, idx=None):
    return lambda r: r.num(key, idx)


def med(xs):
    return mblog.percentile(xs, 50)


def p(xs, q):
    return mblog.percentile(xs, q)


def total(xs):
    return float(sum(xs)) if xs else None


def last(rs):
    return rs[-1] if rs else None


def fv(r, key):
    if r is None:
        return None
    v = r.f.get(key)
    return None if v in (None, '-') else v


def parse_expect(text):
    out = []
    for tok in (text or '').split(','):
        k, sep, v = tok.partition('=')
        if sep and k.strip():
            out.append((k.strip(), v.strip()))
    return out


def applied_values(a):
    """What the logs say was applied. Each value is (value, source) or (None, None)."""
    t_all, h_all = a.t_ident + a.t_win, a.h_ident + a.h_win
    t_prof = last(a.sel(t_all, 'session', 'profile'))
    t_cfg = last(a.sel(t_all, 'session', 'stream_config'))
    h_prof = last(a.sel(h_all, 'encoder', 'profile'))
    out = {}
    out['bitrate_kbps_tablet'] = (fv(t_prof, 'bitrate_kbps'), 'tablet session profile')
    out['bitrate_kbps_host'] = (fv(h_prof, 'bitrate_kbps'), 'host encoder profile')
    size = fv(t_prof, 'size') or fv(t_cfg, 'size')
    out['size'] = (size, 'tablet session profile' if fv(t_prof, 'size') else 'tablet stream_config')
    out['fps'] = (fv(t_prof, 'fps') or fv(t_cfg, 'fps'), 'tablet session profile')
    out['transport'] = (fv(t_prof, 'transport'), 'tablet session profile')
    modes = [r.f.get('mode') for r in a.sel(a.h_win, 'video', 'chroma_stats') if r.f.get('mode')]
    cfg = last(a.sel(h_all, 'encoder', 'chroma_config'))
    if modes:
        out['chroma'] = (mblog.mode_of(modes), 'host video chroma_stats mode (in window)')
        out['chroma_modes'] = sorted(set(modes))
    elif fv(cfg, 'applied'):
        out['chroma'] = (fv(cfg, 'applied'), 'host encoder chroma_config applied (latest)')
        out['chroma_modes'] = [fv(cfg, 'applied')]
    else:
        out['chroma'] = (None, None)
        out['chroma_modes'] = []
    return out


def arm_check(a):
    """(applied line, check line, warning lines)."""
    ap = applied_values(a)
    width = None
    m = re.match(r'^(\d+)x(\d+)$', ap['size'][0] or '')
    if m:
        width = m.group(1)

    def show(v):
        return v if v is not None else '-'
    applied = 'applied: bitrate_kbps=%s (tablet) / %s (host)  chroma=%s [%s]  size=%s  fps=%s  transport=%s' % (
        show(ap['bitrate_kbps_tablet'][0]), show(ap['bitrate_kbps_host'][0]), show(ap['chroma'][0]),
        ap['chroma'][1] or 'no line found', show(ap['size'][0]), show(ap['fps'][0]), show(ap['transport'][0]))
    expect = parse_expect(a.meta.get('expect'))
    bad = []
    for k, want in expect:
        if k == 'bitrate_kbps':
            got = [ap['bitrate_kbps_tablet'][0], ap['bitrate_kbps_host'][0]]
            have = [g for g in got if g is not None]
            if not have:
                bad.append('bitrate_kbps expected %s, no profile line found' % want)
            elif any(g != want for g in have):
                bad.append('bitrate_kbps expected %s, applied %s' % (want, '/'.join(have)))
        elif k == 'chroma':
            w = CHROMA_ALIAS.get(want, want)
            got = ap['chroma'][0]
            if got is None:
                bad.append('chroma expected %s, no chroma line found' % want)
            elif got != w:
                bad.append('chroma expected %s, applied %s' % (w, got))
        elif k in ('width', 'size', 'fps', 'transport'):
            got = width if k == 'width' else ap[k][0]
            if got is None:
                bad.append('%s expected %s, not found in the logs' % (k, want))
            elif got != want:
                bad.append('%s expected %s, applied %s' % (k, want, got))
        else:
            bad.append('unknown expectation key %s' % k)
    warns = []
    if len(ap['chroma_modes']) > 1:
        bad.append('chroma changed during the window (%s)' % ','.join(ap['chroma_modes']))
    if a.sel(a.h_win, 'encoder', 'profile') or a.sel(a.t_win, 'session', 'profile'):
        warns.append('warn: a profile line was logged inside the window (reconnect or setting change); '
                     'drop this run or wait longer after the change')
    if bad:
        chk = 'arm_check: MISMATCH (%s)' % '; '.join(bad)
    elif expect:
        chk = 'arm_check: ok (%s)' % ', '.join('%s=%s' % kv for kv in expect)
    else:
        chk = 'arm_check: no expectation given (applied values above are from the logs)'
    return applied, chk, warns


def metrics(a):
    """Ordered [(name, value, digits, note)] for one arm. Missing = None."""
    hs = a.sel(a.h_win, 'net', 'stats')
    lat = a.sel(a.h_win, 'video', 'latency')
    cad = a.sel(a.h_win, 'video', 'cadence')
    tcp = a.sel(a.h_win, 'net', 'tcp', conn='video')
    kf = a.sel(a.h_win, 'net', 'keyframe_request')
    ts = a.sel(a.t_win, 'render', 'stats')
    td = a.sel(a.t_win, 'decoder', 'stats')
    m = []

    def add(name, v, nd=1, note=''):
        m.append((name, v, nd, note))

    kbps = vals(hs, f('sent_kbps'))
    add('host sent_mbps p50', med(kbps) / 1000 if kbps else None)
    add('host sent_mbps mean', sum(kbps) / len(kbps) / 1000 if kbps else None)
    add('host cap_fps p50', med(vals(cad, f('cap_fps'))))
    add('host enc_ms p50', med(vals(lat, f('enc_ms_p50_95_99_max', 0))), 2)
    add('host gpu_ms p50', med(vals(lat, f('gpu_ms_p50_95_99_max', 0))), 2)
    add('host gpu_ms p95', med(vals(lat, f('gpu_ms_p50_95_99_max', 1))), 2)
    add('host cap_to_sent_ms p50', med(vals(lat, f('cap_to_sent_ms_p50_95_99_max', 0))), 2)
    add('host cap_to_sent_ms p95', med(vals(lat, f('cap_to_sent_ms_p50_95_99_max', 1))), 2)
    retx = vals(tcp, f('retx_pkts_delta'))
    add('video retx_pkts total', total(retx), 0)
    add('video retx_pct_s', 100.0 * sum(1 for v in retx if v > 0) / len(retx) if retx else None)
    srtt = vals(tcp, f('srtt_ms'))
    add('video srtt_ms p50', med(srtt))
    add('video srtt_ms p95', p(srtt, 95))
    add('keyframe_request', float(len(kf)) if a.h_win else None, 0)
    # tablet
    iv = sum(r.num('interval_ms') or 0 for r in td if r.num('recv') is not None)
    add('tablet recv_fps', sum(r.num('recv') or 0 for r in td) * 1000.0 / iv if iv else None)
    add('tablet render fps p50', med(vals(ts, f('fps'))))
    add('tablet skip_pct p50', med(vals(ts, f('skip_pct'))))
    dec = vals(hs, f('decode_ms'))
    add('decode_ms p50 (1 Hz)', med(dec), 2)
    add('decode_ms p95 (1 Hz)', p(dec, 95), 2)
    add('tablet dec_ms p50 (10 s)', (lambda v: v / 1000 if v is not None else None)(med(vals(ts, f('dec_p50_us')))), 2)
    cd = vals(hs, f('cap_dec_ms'))
    add('cap_dec_ms p50 (1 Hz)', med(cd), 1)
    add('cap_dec_ms p95 (1 Hz)', p(cd, 95), 1)
    add('cap_dec_ms p99 (1 Hz)', p(cd, 99), 1)
    mx = vals(ts, f('cap_dec_max_us'))
    if cd:
        stalls, src = float(sum(1 for v in cd if v > STALL_MS)), 'host 1 Hz seconds with cap_dec_ms > 150'
    elif mx:
        stalls, src = float(sum(1 for v in mx if v > STALL_MS * 1000)), \
            'tablet 10 s windows with cap_dec_max_us > 150000 (lower bound: windows, not seconds)'
    else:
        stalls, src = None, 'no cap_dec samples'
    add('stalls >150 ms', stalls, 0, src)
    add('tablet cap_dec_ms p50 (10 s)', (lambda v: v / 1000 if v is not None else None)(med(vals(ts, f('cap_dec_p50_us')))))
    add('tablet cap_dec_ms p95 (10 s)', (lambda v: v / 1000 if v is not None else None)(med(vals(ts, f('cap_dec_p95_us')))))
    # Mac
    def mac(key, nd=1):
        return med([v for v in (mblog.fnum(r, key) for r in a.mac) if v is not None])
    add('mac gpu_dev p50', mac('gpu_dev'), 0)
    add('mac cpu MateBridgeApp p50', mac('cpu_MateBridgeApp'))
    add('mac cpu WindowServer p50', mac('cpu_WindowServer'))
    keys = []
    for r in a.mac:
        for k in r:
            if k.startswith('cpu_') and k not in MAC_KNOWN and k not in keys:
                keys.append(k)
    enc = [k for k in keys if k.startswith('cpu_VTEncoder')]
    add('mac cpu VTEncoder p50', mac(enc[0]) if enc else None)
    for k in keys:
        if k not in enc:
            add('mac cpu %s p50' % k[4:], mac(k))
    return m


def read_stalls(path):
    """stalls.txt of stall-inject.sh -> [{'n','mono','ms'}] sorted by mono; [] when absent."""
    out = []
    if not os.path.exists(path):
        return out
    with open(path, errors='replace') as fh:
        for line in fh:
            d = mblog.parse_kv_line(line)
            if d and mblog.fnum(d, 'mono_ms') is not None:
                out.append({'n': int(mblog.fnum(d, 'n') or len(out) + 1), 'mono': mblog.fnum(d, 'mono_ms'),
                            'ms': mblog.fnum(d, 'ms')})
    out.sort(key=lambda e: e['mono'])
    return out


def stall_events(a):
    """One dict per injected stall: see the module docstring. Empty without stalls.txt."""
    if not a.stalls:
        return []
    stats = [r for r in a.sel(a.h_win, 'net', 'stats') if r.mono is not None]
    cad = [r for r in a.sel(a.h_win, 'video', 'cadence') if r.mono is not None]
    tcp = [r for r in a.sel(a.h_win, 'net', 'tcp', conn='video') if r.mono is not None]
    out = []
    for i, st in enumerate(a.stalls):
        m0 = st['mono']
        end = m0 + EVENT_S * 1000
        nxt = a.stalls[i + 1]['mono'] if i + 1 < len(a.stalls) else float('inf')
        win = [r for r in stats if m0 < r.mono <= end]
        cw = [r for r in cad if m0 < r.mono <= end]
        ev = {'n': st['n']}
        ev['idr_5s'] = total(vals(win, f('idr'))) if win else None
        ev['queue_drops_5s'] = total(vals(cw, f('queue_drops'))) if cw else None
        ev['overwritten_5s'] = total(vals(cw, f('overwritten'))) if cw else None
        caps = [(r.mono, r.num('cap_dec_ms')) for r in win if r.num('cap_dec_ms') is not None]
        ev['cap_dec_max_ms'] = max(v for _t, v in caps) if caps else None
        rec = None
        if caps:
            peak_t, peak_v = max(caps, key=lambda x: x[1])
            if peak_v < RECOVER_MS:
                rec = 0.0
            else:
                lim = min(nxt, m0 + RECOVER_HORIZON_S * 1000)
                for r in stats:
                    v = r.num('cap_dec_ms')
                    if peak_t <= r.mono < lim and v is not None and v < RECOVER_MS:
                        rec = (r.mono - m0) / 1000.0
                        break
        ev['recover_s'] = rec
        before = [r for r in tcp if m0 - 2000 <= r.mono <= m0]
        last_tcp = before[-1] if before else None
        cwnd = last_tcp.num('snd_cwnd') if last_tcp else None
        unacked = last_tcp.num('unacked_bytes') if last_tcp else None
        ev['cwnd_kb'] = cwnd / 1000.0 if cwnd is not None else None
        ev['unacked_kb'] = unacked / 1000.0 if unacked is not None else None
        out.append(ev)
    return out


# (label, event key, digits)
EVENT_ROWS = (('idr in 5 s', 'idr_5s', 0), ('queue_drops in 5 s', 'queue_drops_5s', 0),
              ('overwritten in 5 s', 'overwritten_5s', 0), ('cap_dec_ms max in 5 s', 'cap_dec_max_ms', 0),
              ('recover to <30 ms (s)', 'recover_s', 1), ('snd_cwnd at stall (KB)', 'cwnd_kb', 0),
              ('unacked at stall (KB)', 'unacked_kb', 0))


def event_lines(arms, name_w=26, colw=22):
    """Median (min-max) rows over events; `arms` = [(column name, events)] side by side."""
    out = ['%-*s ' % (name_w, 'stall metric') + ' '.join('%-*s' % (colw, n) for n, _e in arms)]
    out.append('%-*s ' % (name_w, 'stall events') + ' '.join('%-*d' % (colw, len(e)) for _n, e in arms))
    for label, key, nd in EVENT_ROWS:
        row = []
        for _n, e in arms:
            row.append('%-*s' % (colw, spread([ev[key] for ev in e if ev.get(key) is not None], nd)))
        out.append('%-*s ' % (name_w, label) + ' '.join(row))
    rec = ['%-*s' % (colw, '%d/%d' % (sum(1 for ev in e if ev.get('recover_s') is not None), len(e))) for _n, e in arms]
    out.append('%-*s ' % (name_w, 'recovered (of events)') + ' '.join(rec))
    return out


def arm_header(a, runs):
    ns = argparse.Namespace(macos=a.meta.get('macos'), harmonyos=a.meta.get('harmonyos'),
                            apk_version_code=a.meta.get('apk_version_code'), seconds=a.meta.get('seconds'),
                            host_instances=a.meta.get('host_instances'))
    derived, _detail = smoke.identity(a.h_ident + a.h_win, a.t_ident + a.t_win, a.t_win, ns)
    if a.meta.get('content'):
        derived['content'] = a.meta['content']
    return derived


def cmd_arm(a, runs):
    derived = arm_header(a, runs)
    out = mblog.header_lines(derived, a.k, runs)
    applied, chk, warns = arm_check(a)
    out += ['', 'arm: %s run %d' % (a.arm, a.k), chk, applied] + warns
    out.append('')
    out.append('%-32s %10s' % ('metric', 'value'))
    notes = []
    for name, v, nd, note in metrics(a):
        out.append('%-32s %10s' % (name, mblog.fmt(v, nd)))
        if note:
            notes.append('note: %s: %s' % (name, note))
    out += notes
    ev = stall_events(a)
    if ev:
        out += ['', '-- injected stalls (stalls.txt): %d, event window %d s after each start --' % (len(ev), EVENT_S)]
        out.append('%-4s %6s %8s %8s %12s %10s %9s %11s' % ('n', 'idr', 'q_drops', 'overwr', 'cap_dec_max', 'recover_s',
                                                          'cwnd_kb', 'unacked_kb'))
        for e in ev:
            out.append('%-4d %6s %8s %8s %12s %10s %9s %11s' % (
                e['n'], mblog.fmt(e['idr_5s'], 0), mblog.fmt(e['queue_drops_5s'], 0), mblog.fmt(e['overwritten_5s'], 0),
                mblog.fmt(e['cap_dec_max_ms'], 0), mblog.fmt(e['recover_s'], 1), mblog.fmt(e['cwnd_kb'], 0),
                mblog.fmt(e['unacked_kb'], 0)))
        out += event_lines([('median (min-max)', ev)])
    if not a.t_win:
        out.append('note: no tablet window (no adb device, or no client stats lines: static screen writes none)')
    return out


def arms_of(label_dir):
    arms = []
    for n in sorted(os.listdir(label_dir)):
        full = os.path.join(label_dir, n)
        if os.path.isdir(full) and re.match(r'^.+-\d+$', n):
            arms.append(Arm(full))
    arms.sort(key=lambda a: (float(a.meta.get('start_ep') or 0), a.name))
    return arms


def spread(xs, nd):
    xs = [x for x in xs if x is not None]
    if not xs:
        return '-'
    m = med(xs)
    mnd = 1 if nd == 0 and m != int(m) else nd   # a median of two counts can be x.5
    return '%s (%s-%s)' % (mblog.fmt(m, mnd), mblog.fmt(min(xs), nd), mblog.fmt(max(xs), nd))


def cmd_summary(label_dir):
    arms = arms_of(label_dir)
    if not arms:
        return ['no arm directories (ARM-K) in %s' % label_dir]
    order = []
    for a in arms:
        if a.arm not in order:
            order.append(a.arm)
    runs_of = {n: [a for a in arms if a.arm == n] for n in order}
    min_runs = min(len(v) for v in runs_of.values())
    first = arms[0]
    derived = arm_header(first, None)
    derived['duration_s'] = ', '.join(sorted({a.meta.get('seconds', '-') for a in arms}))
    derived['content'] = first.meta.get('content') or derived.get('content')
    derived['run'] = 'all of %d' % min_runs
    out = mblog.header_lines(derived)
    out.append('arms (recording order): %s' % ' '.join(a.name for a in arms))
    out.append('runs per arm: %s' % ', '.join('%s=%d' % (n, len(runs_of[n])) for n in order))
    out += ['', '-- arm_check per run --']
    for a in arms:
        applied, chk, warns = arm_check(a)
        out.append('%s: %s' % (a.name, chk.replace('arm_check: ', '')))
        out += ['  ' + w for w in warns]
    per = {a.name: dict((n, (v, nd, note)) for n, v, nd, note in metrics(a)) for a in arms}
    names = [n for n, _v, _nd, _note in metrics(first)]
    width = max(len(n) for n in names)
    colw = 22
    out += ['', '-- per arm: median (min-max) over the runs; one run = one column entry --',
            '%-*s ' % (width, 'metric') + ' '.join('%-*s' % (colw, n) for n in order)]
    for n in names:
        row = []
        nd = 1
        for arm in order:
            xs = []
            for a in runs_of[arm]:
                v, nd, _note = per[a.name].get(n, (None, 1, ''))
                xs.append(v)
            row.append('%-*s' % (colw, spread(xs, nd)))
        out.append('%-*s ' % (width, n) + ' '.join(row))
    if any(a.stalls for a in arms):
        out += ['', '-- injected stalls: events of all runs of an arm pooled, median (min-max) --']
        out += event_lines([(n, [e for a in runs_of[n] for e in stall_events(a)]) for n in order], width, colw)
        out.append('recover: seconds from the stall start to the first 1 Hz sample with cap_dec_ms < %d after the '
                   'worst one; "recovered" counts events that got there before the next stall or within %d s.' % (
                       RECOVER_MS, RECOVER_HORIZON_S))
    srcs = {per[a.name]['stalls >150 ms'][2] for a in arms if per[a.name].get('stalls >150 ms')}
    out.append('')
    out.append('stalls source: %s' % ' | '.join(sorted(s for s in srcs if s)))
    out.append('median-of-windows rows (gpu_ms, cap_to_sent_ms, enc_ms): median over 1 s host windows of that '
               'window\'s p50 / p95')
    out.append('A spread wider than the difference between arms means "uncertain" (research doc, decision rules).')
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description='Game A/B summaries (T-364).')
    sub = ap.add_subparsers(dest='cmd', required=True)
    s1 = sub.add_parser('arm', help='report of one arm directory DIR/LABEL/ARM-K')
    s1.add_argument('dir')
    s1.add_argument('--runs', type=int, help='planned repeats of this arm (header run count)')
    s2 = sub.add_parser('summary', help='all arms of DIR/LABEL side by side')
    s2.add_argument('dir')
    a = ap.parse_args(argv)
    if not os.path.isdir(a.dir):
        sys.stderr.write('game_ab: no such directory: %s\n' % a.dir)
        return 2
    out = cmd_arm(Arm(a.dir), a.runs) if a.cmd == 'arm' else cmd_summary(a.dir)
    sys.stdout.write('\n'.join(out) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
