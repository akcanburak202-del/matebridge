#!/usr/bin/env python3
"""Host window summary (T-173): macmon.sh samples, optionally with the matching host.log slice.

  macan.py MACMON.txt [--host-log ~/Library/Logs/MateBridge/host.log] [--window S]
           [--header FILE] [--content T] [--run K --runs N]

- Every numeric sampler field gets p50 / p95 / max per window (GPU %, system and per-process %CPU, soak RSS/fds/threads).
- `--host-log`: the bytes between the window's first and last `hl_off=` are read and filtered in memory (numeric
  fields of `ev=latency`, `ev=cadence`, `net ev=stats` only) and summarised like scripts/device-smoke.sh. A host.log
  that rotated during the run is not sliced (the offsets no longer match); the summary then says so.
"""

import argparse
import os
import sys

sys.dont_write_bytecode = True  # no __pycache__ next to the tools
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mblog  # noqa: E402
import smoke  # noqa: E402

SKIP = {'ep', 'dt', 'hl_off', 'pid'}


def load(path):
    rows = []
    with open(path, errors='replace') as fh:
        for line in fh:
            d = mblog.parse_kv_line(line)
            if d and 'ep' in d:
                rows.append(d)
    return rows


def host_slice(path, start, end):
    if not path or start is None or end is None:
        return None
    try:
        size = os.path.getsize(path)
    except OSError:
        return None
    if size < end:
        return None
    with open(path, 'rb') as fh:
        fh.seek(int(start))
        data = fh.read(int(end - start)).decode('utf-8', 'replace')
    return mblog.read_records(data.splitlines(), side='H')


def block(idx, rows, t0, host_log):
    a, b = mblog.fnum(rows[0], 'ep'), mblog.fnum(rows[-1], 'ep')
    out = ['window %d: t=%.0f..%.0f s (%d samples)' % (idx, a - t0, b - t0, len(rows))]
    keys = []
    for r in rows:
        for k in r:
            if k not in SKIP and k not in keys:
                keys.append(k)
    out.append('  %-26s %10s %10s %10s' % ('field', 'p50', 'p95', 'max'))
    for k in keys:
        vs = [mblog.fnum(r, k) for r in rows]
        vs = [v for v in vs if v is not None]
        if not vs:
            continue
        if k.startswith('ev_'):
            out.append('  %-26s %10s %10s %10s  total %d' % (k, '', '', mblog.fmt(max(vs), 0), sum(vs)))
            continue
        out.append('  %-26s %10s %10s %10s' % (k, mblog.fmt(mblog.percentile(vs, 50)),
                                               mblog.fmt(mblog.percentile(vs, 95)), mblog.fmt(max(vs))))
    pids = [r.get('pid') for r in rows if r.get('pid') not in (None, '-')]
    if pids:
        changes = sum(1 for x, y in zip(pids, pids[1:]) if x != y)
        out.append('  MateBridgeApp pid changes (restarts): %d' % changes)
    if host_log:
        recs = host_slice(host_log, mblog.fnum(rows[0], 'hl_off'), mblog.fnum(rows[-1], 'hl_off'))
        if recs is None:
            out.append('  host.log: slice unavailable (rotated, or no hl_off)')
        else:
            out.extend('  ' + line for line in smoke.summary(recs, [], sides=('H',)))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description='Host window summary (T-173)')
    ap.add_argument('macmon')
    ap.add_argument('--host-log')
    ap.add_argument('--window', type=float)
    mblog.add_header_args(ap)
    a = ap.parse_args(argv)
    rows = load(a.macmon)
    derived = {}
    if rows:
        derived['duration_s'] = mblog.fmt(mblog.fnum(rows[-1], 'ep') - mblog.fnum(rows[0], 'ep')
                                          + (mblog.fnum(rows[0], 'dt') or 0), 0)
        derived['date_utc'] = mblog.utc(mblog.fnum(rows[0], 'ep'))
    h, run, runs = mblog.merged_header(a, derived)
    out = mblog.header_lines(h, run, runs)
    if not rows:
        out.append('no macmon samples in %s' % a.macmon)
        print('\n'.join(out))
        return 1
    t0 = mblog.fnum(rows[0], 'ep')
    windows = [rows]
    if a.window:
        windows, cur = [], []
        for r in rows:
            if cur and mblog.fnum(r, 'ep') - mblog.fnum(cur[0], 'ep') >= a.window:
                windows.append(cur)
                cur = []
            cur.append(r)
        if cur:
            windows.append(cur)
    for i, w in enumerate(windows, 1):
        out.extend(block(i, w, t0, a.host_log))
    print('\n'.join(out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
