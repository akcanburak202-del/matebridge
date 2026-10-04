#!/usr/bin/env python3
"""Tablet window summary (T-173): mbmon.sh perf samples, optionally joined with a filtered logcat capture.

  an.py MBMON.txt [--log CAPTURE] [--window S] [--header FILE] [--content T] [--run K --runs N]

- CPU shares are % of one core over the window (ticks / (system ticks / ncpu)); the system total is out of
  ncpu x 100 (e.g. "157/800"), as in NOTES 2026-10-02 ~21:30. A tick delta is never taken across a pid change.
- CAPTURE: `adb logcat -v epoch -T 1 | python3 mblog.py filter --side tablet --agp > cap.txt` (numeric lines only).
  A raw logcat file also works (it is filtered in memory). MB lines are placed by their mono_ms (elapsedRealtime,
  the same clock as /proc/uptime); AGP lines by epoch (needs `-v epoch`).
- `--window S` splits the run into S-second windows (default: one window for the whole run).
"""

import argparse
import os
import sys
from collections import Counter

sys.dont_write_bytecode = True  # no __pycache__ next to the tools
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mblog  # noqa: E402

GROUPS = ['client', 'sf', 'codec', 'hal', 'adbd', 'logd']


def load_samples(path):
    meta, rows = {}, []
    with open(path, errors='replace') as fh:
        for line in fh:
            if line.startswith('# mbmon'):
                meta = {k: v for k, _, v in (t.partition('=') for t in line[1:].split()) if v}
                continue
            d = mblog.parse_kv_line(line)
            if d and 'up' in d and 'cpu_total' in d:
                rows.append(d)
    return meta, rows


def dist(values):
    c = Counter(v for v in values if v is not None)
    n = sum(c.values())
    if not n:
        return '-'
    return ' '.join('%s:%d%%' % (mblog.fmt(k, 0), round(100.0 * c[k] / n)) for k in sorted(c, reverse=True))


def window_block(idx, rows, meta, recs, offset, lead=0):
    """One window; the first `lead` rows only open the tick deltas (they belong to the previous window)."""
    ncpu = int(meta.get('ncpu') or 8)
    t0, t1 = mblog.fnum(rows[lead], 'up'), mblog.fnum(rows[-1], 'up')
    out = ['window %d: t=%.0f..%.0f s (%d samples)' % (idx, t0 - offset['up0'], t1 - offset['up0'],
                                                         len(rows) - lead)]
    # CPU from tick deltas inside the window, same pid generation only
    sums = {g: 0.0 for g in GROUPS}
    sys_total = sys_busy = 0.0
    client_pts = []
    for a, b in zip(rows, rows[1:]):
        if a.get('gen') != b.get('gen'):
            continue
        dt = mblog.fnum(b, 'cpu_total') - mblog.fnum(a, 'cpu_total')
        di = mblog.fnum(b, 'cpu_idle') - mblog.fnum(a, 'cpu_idle')
        if dt <= 0:
            continue
        sys_total += dt
        sys_busy += dt - di
        for g in GROUPS:
            x, y = mblog.fnum(a, 't_' + g), mblog.fnum(b, 't_' + g)
            if x is not None and y is not None and y >= x:
                sums[g] += y - x
                if g == 'client':
                    client_pts.append((y - x) / (dt / ncpu) * 100.0)
    if sys_total > 0:
        core = sys_total / ncpu
        shares = '  '.join('%s %.1f' % (g, sums[g] / core * 100.0) for g in GROUPS)
        out.append('  cpu (%% of one core): total %.1f/%d  %s  (client p95 %s)' % (
            sys_busy / sys_total * ncpu * 100.0, ncpu * 100, shares,
            mblog.fmt(mblog.percentile(client_pts, 95))))
    else:
        out.append('  cpu: - (fewer than 2 samples of one pid generation)')
    own = rows[lead:]
    out.append('  panel_hz (%s): %s' % (meta.get('panel_src', '?'),
                                         dist([mblog.fnum(r, 'panel_hz') for r in own])))
    temps = sorted({k for r in own for k in r if k.startswith('temp_')})
    tl = []
    for k in temps:
        vs = [mblog.fnum(r, k) for r in own]
        vs = [v / 1000.0 if v is not None and v > 1000 else v for v in vs]
        tl.append('%s p50 %s max %s' % (k[5:], mblog.fmt(mblog.percentile(vs, 50)),
                                        mblog.fmt(max([v for v in vs if v is not None], default=None))))
    out.append('  temp_c: %s' % ('  '.join(tl) or '-'))
    fl = []
    for k in sorted({k for r in own for k in r if k.startswith('f_')}):
        div = 1e6 if k == 'f_gpu' else 1000.0
        fl.append('%s %s' % (k[2:], mblog.fmt(mblog.percentile(
            [mblog.fnum(r, k) / div for r in own if mblog.fnum(r, k) is not None], 50), 0)))
    out.append('  freq_mhz p50: %s' % ('  '.join(fl) or '-'))
    if recs is not None:
        def inside(r):
            if r.mono is not None:
                t = r.mono / 1000.0
            elif r.ep is not None and offset['ep_minus_up'] is not None:
                t = r.ep - offset['ep_minus_up']
            else:
                return False
            return t0 <= t <= t1 + 1
        win = [r for r in recs if inside(r)]
        dec = [r for r in win if r.comp == 'decoder' and r.ev == 'stats']
        ren = [r for r in win if r.comp == 'render' and r.ev == 'stats']
        recv = sum(r.num('recv') or 0 for r in dec)
        ivl = sum(r.num('interval_ms') or 0 for r in dec)
        agp = [r.num('fps') for r in win if r.comp == 'agp' and r.ev == 'lcd_fps']
        touch = sum(1 for r in win if r.comp == 'agp' and r.ev == 'touch')
        out.append('  log: recv_fps %s  vsync_ms_p50 %s  display_hz %s  agp_lcd_fps %s  agp_touch %d' % (
            mblog.fmt(recv * 1000.0 / ivl) if ivl else '-',
            mblog.fmt(mblog.percentile([r.num('vsync_ms_p50') for r in ren], 50), 2),
            dist([r.num('display_hz') for r in ren]),
            ' '.join('%d:%d' % (k, v) for k, v in sorted(Counter(int(x) for x in agp if x).items(), reverse=True))
            or '-', touch))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description='Tablet window summary (T-173)')
    ap.add_argument('mbmon')
    ap.add_argument('--log', help='logcat capture (filtered by mblog.py, or raw)')
    ap.add_argument('--window', type=float, help='window length in seconds (default: whole run)')
    mblog.add_header_args(ap)
    a = ap.parse_args(argv)

    meta, rows = load_samples(a.mbmon)
    recs = mblog.read_file_records(a.log, side='T', agp=True) if a.log else None
    derived = {}
    if rows:
        derived['duration_s'] = mblog.fmt(mblog.fnum(rows[-1], 'up') - mblog.fnum(rows[0], 'up'), 0)
        derived['date_utc'] = mblog.utc(mblog.fnum(rows[0], 'ep'))
    if recs:
        ren = [r for r in recs if r.comp == 'render' and r.ev == 'stats']
        vs = mblog.percentile([r.num('vsync_ms_p50') for r in ren], 50)
        if vs:
            derived['real_hz'] = '%.1f (vsync p50 %.2f ms)' % (1000.0 / vs, vs)
        th = mblog.mode_of([r.num('target_hz') for r in ren])
        if th is not None:
            derived['target_hz'] = mblog.fmt(th, 0)
        for r in recs:
            if r.comp == 'session' and r.ev in ('app_start', 'profile') and r.f.get('sha'):
                derived['apk_sha'] = r.f['sha']
            if r.comp == 'session' and r.ev == 'app_start' and r.f.get('os_build'):
                derived['harmonyos'] = r.f['os_build']
    h, run, runs = mblog.merged_header(a, derived)
    out = mblog.header_lines(h, run, runs)
    if not rows:
        out.append('no mbmon samples in %s' % a.mbmon)
        print('\n'.join(out))
        return 1
    offset = {'up0': mblog.fnum(rows[0], 'up'), 'ep_minus_up': None}
    if mblog.fnum(rows[0], 'ep') is not None:
        offset['ep_minus_up'] = mblog.fnum(rows[0], 'ep') - mblog.fnum(rows[0], 'up')
    windows = [(rows, 0)]
    if a.window:
        windows, cur, lead, start = [], [], 0, offset['up0']
        for r in rows:
            if mblog.fnum(r, 'up') - start >= a.window and len(cur) > lead:
                windows.append((cur, lead))
                # the boundary sample opens the next window too, so no tick delta is lost between windows
                cur, lead = [cur[-1]], 1
                start += a.window * int((mblog.fnum(r, 'up') - start) // a.window)
            cur.append(r)
        if len(cur) > lead:
            windows.append((cur, lead))
    for i, (w, lead) in enumerate(windows, 1):
        out.extend(window_block(i, w, meta, recs, offset, lead))
    print('\n'.join(out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
