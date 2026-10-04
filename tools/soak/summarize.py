#!/usr/bin/env python3
"""Soak summary (T-173, T-194): per-hour trends and linear slopes. It reports numbers only; the thresholds and the
verdict are the orchestrator's (T-194 step 2).

  summarize.py [--host host-soak.txt] [--tablet tablet-soak.txt] [--events tablet-events.txt] [--from-h H]
               [--header FILE] [--content T] [--run K --runs N]

- host-soak.txt: tools/soak/host-soak.sh (macmon.sh --soak) lines.
- tablet-soak.txt / tablet-events.txt: `tools/soak/tablet-soak.sh pull DIR`.
- Slopes are least squares over every sample with hour >= --from-h (default 0; T-194 compares hour 1..8).
  RSS/PSS in MB/h, fds/threads/codec lines in count/h.
"""

import argparse
import os
import sys
from collections import Counter, defaultdict

sys.dont_write_bytecode = True  # no __pycache__ next to the tools
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'measure'))
import mblog  # noqa: E402

# Thread-name groups (names arrive with trailing numbers stripped, e.g. thr_mb-ctl-read=3).
GROUPS = [('mb-ctl-read', 'mb-ctl-read*'), ('mb-video', 'mb-video*'), ('mb-audio', 'mb-audio*'),
          ('mb-decoder', 'mb-decoder*'), ('mb-', 'mb-other*'), ('Binder', 'binder*'), ('binder', 'binder*')]


def group_of(name):
    for prefix, label in GROUPS:
        if name.startswith(prefix):
            return label
    return 'other'


def load(path):
    rows = []
    if not path:
        return rows
    with open(path, errors='replace') as fh:
        for line in fh:
            d = mblog.parse_kv_line(line)
            if d and mblog.fnum(d, 'ep') is not None:
                rows.append(d)
    return rows


def thread_groups(row):
    g = Counter()
    for k, v in row.items():
        if k.startswith('thr_'):
            n = mblog.fnum(row, k)
            if n is not None:
                g[group_of(k[4:])] += n
    return g


def group_count(row, group):
    """Threads of `group` in one sample; None when the sample could not read thread names (threads=-)."""
    if mblog.fnum(row, 'threads') is None:
        return None
    return thread_groups(row).get(group, 0)


def mean(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) / len(xs) if xs else None


def pid_changes(rows):
    pids = [r.get('pid') for r in rows if r.get('pid') not in (None, '-')]
    return sum(1 for a, b in zip(pids, pids[1:]) if a != b)


def main(argv=None):
    ap = argparse.ArgumentParser(description='Soak summary (T-173)')
    ap.add_argument('--host')
    ap.add_argument('--tablet')
    ap.add_argument('--events')
    ap.add_argument('--from-h', type=float, default=0.0, help='slopes use samples from this hour on')
    mblog.add_header_args(ap)
    a = ap.parse_args(argv)

    host, tab = load(a.host), load(a.tablet)
    events = mblog.read_file_records(a.events, side='T') if a.events else []
    eps = [mblog.fnum(r, 'ep') for r in host + tab] + [r.ep for r in events if r.ep is not None]
    out = []
    if not eps:
        h, run, runs = mblog.merged_header(a, {})
        print('\n'.join(mblog.header_lines(h, run, runs) + ['no soak samples']))
        return 1
    t0, t1 = min(eps), max(eps)
    h, run, runs = mblog.merged_header(a, {'duration_s': mblog.fmt(t1 - t0, 0), 'date_utc': mblog.utc(t0)})
    out.extend(mblog.header_lines(h, run, runs))

    def hour(ep):
        return (ep - t0) / 3600.0

    # Per-hour table
    groups = sorted({g for r in tab for g in thread_groups(r)})
    host_ev = sorted({k for r in host for k in r if k.startswith('ev_')})
    tab_ev = sorted({r.ev for r in events})
    bins = defaultdict(lambda: {'host': [], 'tab': [], 'ev': Counter()})
    for r in host:
        bins[int(hour(mblog.fnum(r, 'ep')))]['host'].append(r)
    for r in tab:
        bins[int(hour(mblog.fnum(r, 'ep')))]['tab'].append(r)
    for r in events:
        if r.ep is not None:
            bins[int(hour(r.ep))]['ev'][r.ev] += 1

    cols = ['hour', 'h_n', 'rss_mb', 'h_fds', 'h_thr', 'h_inst', 't_n', 'pss_mb', 't_fds', 't_thr', 'codec']
    cols += ['thr:' + g for g in groups] + ['h:' + e[3:] for e in host_ev] + ['t:' + e for e in tab_ev]
    out.append('')
    out.append('-- per hour (means; events are counts) --')
    table = [cols]
    for hr in sorted(bins):
        b = bins[hr]
        hs, ts = b['host'], b['tab']

        def m(rows, k, div=1.0):
            v = mean([mblog.fnum(r, k) for r in rows])
            return None if v is None else v / div
        vals = [hr, len(hs), m(hs, 'rss_kb', 1024.0), m(hs, 'fds'), m(hs, 'threads'),
                max([mblog.fnum(r, 'instances') or 0 for r in hs], default=None),
                len(ts), m(ts, 'pss_kb', 1024.0), m(ts, 'fds'), m(ts, 'threads'), m(ts, 'codec_res')]
        vals += [mean([group_count(r, g) for r in ts]) if ts else None for g in groups]
        vals += [int(sum(mblog.fnum(r, e) or 0 for r in hs)) if hs else None for e in host_ev]
        vals += [b['ev'].get(e, 0) for e in tab_ev]
        table.append([mblog.fmt(v, 1) if isinstance(v, float) else ('-' if v is None else str(v)) for v in vals])
    widths = [max(len(row[i]) for row in table) for i in range(len(cols))]
    for row in table:
        out.append('  '.join(c.rjust(w) for c, w in zip(row, widths)))

    # Slopes
    def pts(rows, key, div=1.0, getter=None):
        res = []
        for r in rows:
            x = hour(mblog.fnum(r, 'ep'))
            if x < a.from_h:
                continue
            y = getter(r) if getter else mblog.fnum(r, key)
            res.append((x, None if y is None else y / div))
        return res
    out.append('')
    out.append('-- slopes per hour (from hour %s; least squares) --' % mblog.fmt(a.from_h, 1))
    series = [
        ('host rss MB/h', pts(host, 'rss_kb', 1024.0)),
        ('host fds /h', pts(host, 'fds')),
        ('host threads /h', pts(host, 'threads')),
        ('tablet pss MB/h', pts(tab, 'pss_kb', 1024.0)),
        ('tablet fds /h', pts(tab, 'fds')),
        ('tablet threads /h', pts(tab, 'threads')),
        ('tablet codec lines /h', pts(tab, 'codec_res')),
    ]
    for g in groups:
        series.append(('tablet thr %s /h' % g, pts(tab, None, getter=lambda r, g=g: group_count(r, g))))
    for name, p in series:
        ys = [y for _, y in p if y is not None]
        out.append('%-28s %10s   (n=%d, first %s, last %s)' % (
            name, mblog.fmt(mblog.slope_per_hour(p), 3), len(ys),
            mblog.fmt(ys[0] if ys else None), mblog.fmt(ys[-1] if ys else None)))

    out.append('')
    out.append('-- restarts and totals --')
    out.append('host MateBridgeApp pid changes: %d; samples with >1 instance: %d' % (
        pid_changes(host), sum(1 for r in host if (mblog.fnum(r, 'instances') or 0) > 1)))
    out.append('tablet client pid changes: %d' % pid_changes(tab))
    for e in host_ev:
        out.append('host %s: %d' % (e[3:], sum(mblog.fnum(r, e) or 0 for r in host)))
    tot = Counter(r.ev for r in events)
    for e in sorted(tot):
        out.append('tablet %s: %d' % (e, tot[e]))
    gaps = [b - a2 for a2, b in zip([mblog.fnum(r, 'ep') for r in tab], [mblog.fnum(r, 'ep') for r in tab[1:]])]
    if gaps:
        out.append('tablet sample gaps > 3 min: %d (longest %s s)' % (sum(1 for g in gaps if g > 180),
                                                                      mblog.fmt(max(gaps), 0)))
    print('\n'.join(out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
