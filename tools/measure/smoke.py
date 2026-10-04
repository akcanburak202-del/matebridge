#!/usr/bin/env python3
"""Report of scripts/device-smoke.sh (T-173): result header, build identity and p50/p95 of the key stats fields.

Inputs are files already passed through `mblog.py filter` (numeric fields only). Raw log lines are filtered in memory
when given by mistake, so the output stays numeric either way.

  smoke.py --host-ident F --tablet-ident F --host-win F --tablet-win F --seconds 60 \
           [--macos X] [--harmonyos X] [--apk-version-code N] [--host-instances N] [--content T] [--run K --runs N]
"""

import argparse
import datetime
import os
import sys

sys.dont_write_bytecode = True  # no __pycache__ next to the tools
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mblog  # noqa: E402

# (side, component, event, label, getter, kind). kind 'v' = distribution, 'c' = counter (also totalled).
def _per_s(key):
    def g(r):
        n, iv = r.num(key), r.num('interval_ms')
        return n * 1000.0 / iv if n is not None and iv else None
    return g


def _f(key, idx=None):
    return lambda r: r.num(key, idx)


ROWS = [
    ('T', 'decoder', 'stats', 'recv_fps', _per_s('recv'), 'v'),
    ('T', 'decoder', 'stats', 'released_fps', _per_s('released'), 'v'),
    ('T', 'decoder', 'stats', 'decode_avg_us', _f('decode_avg_us'), 'v'),
    ('T', 'decoder', 'stats', 'drop', _f('drop'), 'c'),
    ('T', 'decoder', 'stats', 'kf_req', _f('kf_req'), 'c'),
    ('T', 'decoder', 'stats', 'overflows', _f('overflows'), 'c'),
    ('T', 'render', 'stats', 'fps', _f('fps'), 'v'),
    ('T', 'render', 'stats', 'display_hz', _f('display_hz'), 'v'),
    ('T', 'render', 'stats', 'vsync_ms_p50', _f('vsync_ms_p50'), 'v'),
    ('T', 'render', 'stats', 'skip_pct', _f('skip_pct'), 'v'),
    ('T', 'render', 'stats', 'cb_skip_pct', _f('cb_skip_pct'), 'v'),
    ('T', 'render', 'stats', 'dec_p50_us', _f('dec_p50_us'), 'v'),
    ('T', 'render', 'stats', 'net_p95_us', _f('net_p95_us'), 'v'),
    ('T', 'render', 'stats', 'cap_dec_p50_us', _f('cap_dec_p50_us'), 'v'),
    ('T', 'render', 'stats', 'cap_dec_p95_us', _f('cap_dec_p95_us'), 'v'),
    ('T', 'render', 'stats', 'ready_slot_p50_us', _f('ready_slot_p50_us'), 'v'),
    ('T', 'render', 'stats', 'cap_rel_p50_us', _f('cap_rel_p50_us'), 'v'),
    ('T', 'render', 'stats', 'cap_cb_p50_us', _f('cap_cb_p50_us'), 'v'),
    ('T', 'render', 'stats', 'clock_unc_us', _f('clock_unc_us'), 'v'),
    ('T', 'render', 'stats', 'lat_neg', _f('lat_neg'), 'c'),
    ('H', 'video', 'latency', 'enc_ms.p50', _f('enc_ms_p50_95_99_max', 0), 'v'),
    ('H', 'video', 'latency', 'enc_ms.p95', _f('enc_ms_p50_95_99_max', 1), 'v'),
    ('H', 'video', 'latency', 'cap_to_sent_ms.p50', _f('cap_to_sent_ms_p50_95_99_max', 0), 'v'),
    ('H', 'video', 'latency', 'cap_to_sent_ms.p95', _f('cap_to_sent_ms_p50_95_99_max', 1), 'v'),
    ('H', 'video', 'latency', 'write_ms.p95', _f('write_ms_p50_95_99_max', 1), 'v'),
    ('H', 'video', 'latency', 'pts_vs_deliv_ms.p50', _f('pts_vs_deliv_ms_p1_50_99', 1), 'v'),
    ('H', 'video', 'cadence', 'cap_fps', _f('cap_fps'), 'v'),
    ('H', 'video', 'cadence', 'enc_fps', _f('enc_fps'), 'v'),
    ('H', 'video', 'cadence', 'sent_fps', _f('sent_fps'), 'v'),
    ('H', 'video', 'cadence', 'queue_drops', _f('queue_drops'), 'c'),
    ('H', 'video', 'cadence', 'enc_behind', _f('enc_behind'), 'c'),
    ('H', 'net', 'stats', 'fps', _f('fps'), 'v'),
    ('H', 'net', 'stats', 'sent_kbps', _f('sent_kbps'), 'v'),
    ('H', 'net', 'stats', 'cap_dec_ms', _f('cap_dec_ms'), 'v'),
    ('H', 'net', 'stats', 'decode_ms', _f('decode_ms'), 'v'),
    ('H', 'net', 'stats', 'dropped', _f('dropped'), 'c'),
    ('H', 'net', 'stats', 'idr', _f('idr'), 'c'),
]


def last(recs, comp, ev):
    for r in reversed(recs):
        if r.comp == comp and r.ev == ev:
            return r
    return None


def fv(r, key):
    if r is None:
        return None
    v = r.f.get(key)
    return None if v in (None, '-') else v


def join(*parts):
    ps = [p for p in parts if p]
    return ' '.join(ps) if ps else None


def identity(host, tablet, win_tablet, args):
    """Header values and the detailed identity lines from the filtered records (last value wins)."""
    h_start, h_prof = last(host, 'session', 'app_start'), last(host, 'encoder', 'profile')
    h_sess, h_hw = last(host, 'session', 'session_started'), last(host, 'video', 'encoder_hw')
    t_start, t_prof = last(tablet, 'session', 'app_start'), last(tablet, 'session', 'profile')
    t_cfg, t_codec = last(tablet, 'session', 'stream_config'), last(tablet, 'decoder', 'codec_start')

    renders = [r for r in win_tablet if r.comp == 'render' and r.ev == 'stats']
    vs = mblog.percentile([r.num('vsync_ms_p50') for r in renders], 50)
    dhz = mblog.percentile([r.num('display_hz') for r in renders], 50)
    target = mblog.mode_of([r.num('target_hz') for r in renders])
    if target is None and h_prof is not None:
        target = h_prof.num('refresh_hz')
    smode = mblog.mode_of([r.f.get('stream_mode') for r in renders])

    decoder = None
    if t_codec is not None:
        decoder = join(fv(t_codec, 'name'), 'is_hw=%s' % fv(t_codec, 'is_hw') if fv(t_codec, 'is_hw') else None,
                       'lowlat=%s' % fv(t_codec, 'lowlat') if fv(t_codec, 'lowlat') else None,
                       'oprate=%s' % fv(t_codec, 'oprate') if fv(t_codec, 'oprate') else None)
    codec = join(fv(h_prof, 'codec') or fv(t_cfg, 'codec'), '/ %s' % decoder if decoder else None)
    size = fv(t_prof, 'size') or fv(t_cfg, 'size')
    disp = fv(t_prof, 'display') or fv(h_prof, 'display')
    fps = fv(t_prof, 'fps') or fv(t_cfg, 'fps') or fv(h_prof, 'fps')
    t_tr, t_trm, h_tr = fv(t_prof, 'transport'), fv(t_prof, 'transport_mode'), fv(h_sess, 'transport')
    transport = None
    if t_tr or h_tr:
        transport = join(t_tr or h_tr, '(setting %s)' % t_trm if t_trm else None,
                         '[host sees %s]' % h_tr if h_tr and t_tr and h_tr != t_tr else None)
    bitrate = join(fv(t_prof, 'bitrate_kbps') or fv(h_prof, 'bitrate_kbps'),
                   '(setting %s)' % fv(t_prof, 'bitrate_setting') if fv(t_prof, 'bitrate_setting') else None)
    mode = join(fv(t_prof, 'mode') or smode, 'pacer=%s' % fv(t_prof, 'pacer') if fv(t_prof, 'pacer') else None)

    real = None
    if vs:
        real = '%.1f (vsync p50 %.2f ms%s)' % (1000.0 / vs, vs, '; display_hz %.1f' % dhz if dhz is not None else '')
    elif dhz is not None:
        real = '%.1f (display_hz only, no vsync sample)' % dhz

    hdr = {
        'date_utc': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%MZ'),
        'host_sha': fv(h_start, 'sha') or (fv(h_prof, 'sha') and '%s (from profile)' % fv(h_prof, 'sha')),
        'apk_sha': join(fv(t_start, 'sha') or fv(t_prof, 'sha'),
                        '(versionCode %s)' % args.apk_version_code if args.apk_version_code else None),
        'macos': args.macos or fv(h_start, 'os'),
        'harmonyos': args.harmonyos or fv(t_start, 'os_build'),
        'codec': codec,
        'transport': transport,
        'resolution': join(size, 'display=%s' % disp if disp else None, '@%s fps' % fps if fps else None),
        'target_hz': mblog.fmt(target, 0) if target is not None else None,
        'real_hz': real,
        'bitrate_kbps': bitrate,
        'mode': mode,
        'duration_s': args.seconds,
    }
    detail = [
        'host: version=%s build=%s instances=%s encoder_hw=%s knobs=%s' % (
            fv(h_start, 'version') or '-', fv(h_start, 'build') or '-', args.host_instances or '-',
            fv(h_hw, 'using_hw') or '-', fv(h_prof, 'knobs') or '-'),
        'host profile: fps=%s bitrate_kbps=%s refresh_hz=%s encoder_profile=%s display=%s' % tuple(
            fv(h_prof, k) or '-' for k in ('fps', 'bitrate_kbps', 'refresh_hz', 'encoder_profile', 'display')),
        'tablet: version=%s built=%s sdk=%s dev=%s knobs=%s' % tuple(
            fv(r, k) or '-' for r, k in ((t_start, 'version'), (t_start, 'built'), (t_start, 'sdk'),
                                         (t_prof, 'dev'), (t_prof, 'knobs'))),
        'stream_config: config_id=%s codec=%s size=%s fps=%s' % tuple(
            fv(t_cfg, k) or '-' for k in ('config_id', 'codec', 'size', 'fps')),
        'decoder: %s size=%s requested_rate=%s' % (decoder or '-', fv(t_codec, 'size') or '-',
                                                  fv(t_codec, 'requested_rate') or '-'),
    ]
    return hdr, detail


def summary(win_host, win_tablet, sides=('T', 'H')):
    """Rows of the key fields: n windows, p50/p95/max over them, and the total for counters."""
    lines = ['%-7s %-16s %-22s %5s %10s %10s %10s %8s' % ('side', 'line', 'field', 'n', 'p50', 'p95', 'max', 'total')]
    for side, comp, ev, label, get, kind in ROWS:
        if side not in sides:
            continue
        recs = win_tablet if side == 'T' else win_host
        vals = [get(r) for r in recs if r.comp == comp and r.ev == ev]
        vals = [v for v in vals if v is not None]
        tot = mblog.fmt(sum(vals), 0) if kind == 'c' and vals else '-'
        lines.append('%-7s %-16s %-22s %5d %10s %10s %10s %8s' % (
            'tablet' if side == 'T' else 'host', '%s %s' % (comp, ev), label, len(vals),
            mblog.fmt(mblog.percentile(vals, 50), 2), mblog.fmt(mblog.percentile(vals, 95), 2),
            mblog.fmt(max(vals) if vals else None, 2), tot))
    return lines


def main(argv=None):
    ap = argparse.ArgumentParser(description='device-smoke.sh report (T-173)')
    ap.add_argument('--host-ident')
    ap.add_argument('--tablet-ident')
    ap.add_argument('--host-win')
    ap.add_argument('--tablet-win')
    ap.add_argument('--seconds', default=None)
    ap.add_argument('--macos')
    ap.add_argument('--harmonyos')
    ap.add_argument('--apk-version-code')
    ap.add_argument('--host-instances')
    ap.add_argument('--header-only', action='store_true')
    mblog.add_header_args(ap)
    a = ap.parse_args(argv)

    host_ident = mblog.read_file_records(a.host_ident, side='H')
    tablet_ident = mblog.read_file_records(a.tablet_ident, side='T')
    win_host = mblog.read_file_records(a.host_win, side='H')
    win_tablet = mblog.read_file_records(a.tablet_win, side='T')

    derived, detail = identity(host_ident + win_host, tablet_ident + win_tablet, win_tablet, a)
    if a.header_only:
        derived['duration_s'] = None
    h, run, runs = mblog.merged_header(a, derived)
    out = mblog.header_lines(h, run, runs)
    out.append('')
    out.extend(detail)
    if not a.header_only:
        out.append('')
        out.append('-- %s s window: p50/p95/max over log windows (tablet stats: 10 s windows by default, '
                   'host: 1 s) --' % (a.seconds or '?'))
        out.extend(summary(win_host, win_tablet))
        notes = []
        if not any(r.comp in ('render', 'decoder') and r.ev == 'stats' for r in win_tablet):
            notes.append('no tablet stats lines in the window (static screen writes none; adb missing?)')
        if not any(r.ev == 'latency' for r in win_host):
            notes.append('no host ev=latency lines in the window (no session or no frames)')
        for n in notes:
            out.append('note: ' + n)
    sys.stdout.write('\n'.join(out) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
