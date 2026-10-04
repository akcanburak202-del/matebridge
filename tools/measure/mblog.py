#!/usr/bin/env python3
"""Shared MateBridge measurement helpers (T-173). Python 3 stdlib only.

- Log-line parsing for the docs/LOGGING.md format `<mono_ms> <LEVEL> <component> sid= gen= ev=<name> key=value ...`,
  bare (host.log) or behind a logcat prefix (`-v threadtime` or `-v epoch`).
- The privacy filter: only known (component, event) lines pass, and of those only numeric values (`12`, `-3.5`,
  `7.1/7.5/9.0`, `-`) plus a short list of identity keys checked against strict patterns. Everything else is dropped,
  so clipboard, key, text, file-name, address and serial content cannot reach the output.
- Percentiles and the result header every tool prints.

CLI (a filter for live pipes; raw logs never touch the disk):
  mblog.py filter --side tablet|host [--seconds S] [--skip-first N] [--agp] [--events]
"""

import argparse
import math
import os
import re
import select
import sys
import time

# ---------------------------------------------------------------------------------------------------------------
# Parsing

# sid/gen are optional: the client's decoder lifecycle lines (codec_start, give_up, detach_slow) carry none.
_MB_RE = re.compile(r'(?:^|\s)(-?\d+) ([EWID]) ([a-z_]+) (?:sid=(\d+) gen=(\d+) )?ev=([a-z0-9_]+)(.*)$')
_EPOCH_RE = re.compile(r'^\s*(\d{9,11}\.\d+)\s')
_NUM = r'-?\d+(?:\.\d+)?'
_NUM_RE = re.compile(r'^(?:-|%s(?:/%s)*)$' % (_NUM, _NUM))
# A line this module wrote: "<T|H> <epoch|-> <mono|-> <component> <event> k=v ..."
_FILTERED_RE = re.compile(r'^([TH]) (\S+) (\S+) ([a-z_]+) ([a-z0-9_]+)((?: \S+)*)\s*$')

# Identity keys that may carry a non-numeric value, each with the only shape it may have.
_ID = {
    'sha': r'[0-9a-f]{7,40}(?:-dirty)?|unknown',
    'version': r'[0-9A-Za-z._-]{1,32}',
    'build': r'\d{8,14}',
    'built': r'[0-9TZ:._-]{1,32}|unknown',
    'os': r'[A-Za-z0-9._()-]{1,64}',
    'os_build': r'[A-Za-z0-9._()-]{1,64}',
    'name': r'(?:OMX|c2|C2)\.[A-Za-z0-9._-]{1,72}',
    'mime': r'video/[A-Za-z0-9.+-]{1,24}',
    'codec': r'[A-Za-z0-9._-]{1,16}',
    'size': r'\d{1,5}x\d{1,5}',
    'display': r'native|\d{1,5}x\d{1,5}(?:@\dx)?',
    'mode': r'[a-z0-9_]{1,16}',
    'stream_mode': r'[a-z0-9_]{1,16}',
    'transport': r'usb|wifi|-',
    'transport_mode': r'auto|usb|wifi',
    'pacer': r'adaptive|buffer-?\d{1,2}',
    'lowlat': r'[a-z]{1,10}',
    'oprate': r'[a-z]{1,10}',
    'is_hw': r'[01?]',
    'sw_only': r'[01?]',
    'low_latency': r'[a-z0-9]{1,8}',
    'requested_rate': r'\d{1,6}|none',
    'encoder_profile': r'[a-z_]{1,16}',
    'bitrate_source': r'[a-z_]{1,16}',
    'bitrate_setting': r'\d{1,7}|auto',
    'audio_out': r'auto|aaudio|track',
    'knobs': r'[A-Za-z0-9_:;.,-]{1,240}',
    'using_hw': r'[01]|unknown',
    'action': r'enter|exit',
    'jitter': r'adaptive|-?\d{1,2}',
    'fingers': r'all|gestures|off',
    'overrides': r'[a-z,]{1,64}',
}
_ID_RE = {k: re.compile(r'^(?:%s)$' % v) for k, v in _ID.items()}

# (side, component, event) -> identity keys allowed on that line. Numeric values are kept for every listed line.
ALLOWED = {
    ('T', 'session', 'app_start'): {'version', 'sha', 'built', 'os_build'},
    ('T', 'session', 'profile'): {'mode', 'size', 'display', 'bitrate_setting', 'transport', 'transport_mode',
                                  'audio_out', 'pacer', 'sha', 'built', 'knobs'},
    ('T', 'session', 'stream_config'): {'codec', 'size'},
    ('T', 'session', 'mode_layer'): {'mode', 'action', 'jitter', 'audio_out', 'fingers', 'overrides'},
    ('T', 'decoder', 'codec_start'): {'name', 'mime', 'size', 'low_latency', 'requested_rate', 'is_hw', 'sw_only',
                                      'lowlat', 'oprate'},
    ('T', 'decoder', 'stats'): set(),
    ('T', 'render', 'stats'): {'stream_mode'},
    ('T', 'render', 'present'): set(),
    ('T', 'render', 'stats_log'): set(),
    ('H', 'session', 'app_start'): {'version', 'build', 'sha', 'os'},
    ('H', 'encoder', 'profile'): {'codec', 'encoder_profile', 'bitrate_source', 'display', 'sha', 'knobs'},
    ('H', 'session', 'session_started'): {'transport'},
    ('H', 'video', 'encoder_hw'): {'using_hw'},
    ('H', 'video', 'latency'): set(),
    ('H', 'video', 'cadence'): set(),
    ('H', 'net', 'stats'): set(),
    ('H', 'net', 'display_rate'): set(),
}

# Events only counted (name, no fields) by --events: stability and restart signals for the soak (T-194 step 4).
COUNT_EVENTS = {
    'T': {'give_up', 'decoder_previous_stuck', 'detach_slow', 'retire_lock_slow', 'audio_previous_slow',
          'release_all', 'reconnect', 'connect_ok', 'connect_fail', 'video_lost', 'transport_migrate',
          'session_failed', 'app_start', 'codec_start'},
    'H': {'pipeline_retry', 'input_release', 'session_started', 'display_recreate', 'app_start',
          'keyframe_request'},
}

# Huawei AGP refresh decisions (NOTES 2026-10-02 ~21:30): numbers only.
_AGP_FPS_RE = re.compile(r'final lcd fps:\s*(\d+)')
_AGP_TOUCH_RE = re.compile(r'touch', re.I)


def parse_mb(line):
    """A raw MateBridge log line -> (epoch or None, mono_ms, level, component, event, rest) or None."""
    m = _MB_RE.search(line)
    if not m:
        return None
    e = _EPOCH_RE.match(line)
    return (float(e.group(1)) if e else None, int(m.group(1)), m.group(2), m.group(3), m.group(6), m.group(7))


def is_number(v):
    return bool(_NUM_RE.match(v))


def clean_fields(side, comp, ev, rest):
    """Keeps numeric key=value pairs and allowed identity keys with a valid shape; drops the rest."""
    ids = ALLOWED.get((side, comp, ev))
    if ids is None:
        return None
    out = []
    for tok in rest.split():
        k, sep, v = tok.partition('=')
        if not sep or not re.match(r'^[a-z][a-z0-9_]{0,63}$', k):
            continue
        if is_number(v) or (k in ids and _ID_RE[k].match(v)):
            out.append('%s=%s' % (k, v))
    return out


def filter_line(line, side, agp=False, events=False):
    """One raw line -> the filtered line, or None. Output: '<side> <epoch|-> <mono|-> <component> <event> k=v ...'."""
    p = parse_mb(line)
    if p is not None:
        ep, mono, _lvl, comp, ev, rest = p
        ept = '%.3f' % ep if ep is not None else '-'
        if events:
            return '%s %s %d %s %s' % (side, ept, mono, comp, ev) if ev in COUNT_EVENTS[side] else None
        f = clean_fields(side, comp, ev, rest)
        if f is None:
            return None
        return ' '.join(['%s %s %d %s %s' % (side, ept, mono, comp, ev)] + f)
    if agp and side == 'T' and 'AGP' in line and not events:
        e = _EPOCH_RE.match(line)
        ept = '%.3f' % float(e.group(1)) if e else '-'
        m = _AGP_FPS_RE.search(line)
        if m:
            return 'T %s - agp lcd_fps fps=%s' % (ept, m.group(1))
        if _AGP_TOUCH_RE.search(line):
            return 'T %s - agp touch' % ept
    return None


class Rec:
    """One filtered record: side, epoch (None), mono (None), component, event, fields (dict of str)."""
    __slots__ = ('side', 'ep', 'mono', 'comp', 'ev', 'f')

    def __init__(self, side, ep, mono, comp, ev, f):
        self.side, self.ep, self.mono, self.comp, self.ev, self.f = side, ep, mono, comp, ev, f

    def num(self, key, idx=None):
        """Field as float (idx picks one element of an 'a/b/c' tuple); None when absent or '-'."""
        v = self.f.get(key)
        if v is None or v == '-':
            return None
        parts = v.split('/')
        if idx is None:
            if len(parts) != 1:
                return None
            idx = 0
        if idx >= len(parts):
            return None
        try:
            return float(parts[idx])
        except ValueError:
            return None


def parse_filtered(line):
    m = _FILTERED_RE.match(line.rstrip('\n'))
    if not m:
        return None
    side, ep, mono, comp, ev, rest = m.groups()
    f = {}
    for tok in rest.split():
        k, _, v = tok.partition('=')
        f[k] = v
    return Rec(side, None if ep == '-' else float(ep), None if mono == '-' else int(mono), comp, ev, f)


def read_records(lines, side=None, agp=False):
    """Records from filtered lines, or from raw log lines (filtered in memory) when `side` is given."""
    out = []
    for line in lines:
        r = parse_filtered(line)
        if r is None and side is not None:
            fl = filter_line(line, side, agp=agp)
            r = parse_filtered(fl) if fl else None
        if r is not None:
            out.append(r)
    return out


def read_file_records(path, side=None, agp=False):
    if not path:
        return []
    with open(path, errors='replace') as fh:
        return read_records(fh, side=side, agp=agp)


def parse_kv_line(line):
    """'k=v k=v' sampler lines -> dict (values as str). Lines starting with '#' -> None."""
    line = line.strip()
    if not line or line.startswith('#'):
        return None
    d = {}
    for tok in line.split():
        k, sep, v = tok.partition('=')
        if sep:
            d[k] = v
    return d or None


def fnum(d, key):
    v = d.get(key)
    if v is None or v in ('-', ''):
        return None
    try:
        return float(v)
    except ValueError:
        return None


# ---------------------------------------------------------------------------------------------------------------
# Statistics

def percentile(values, q):
    """Linear-interpolated percentile (q in 0..100) of a non-empty list; None when empty."""
    xs = sorted(v for v in values if v is not None)
    if not xs:
        return None
    if len(xs) == 1:
        return xs[0]
    pos = (len(xs) - 1) * q / 100.0
    lo = int(math.floor(pos))
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (pos - lo)


def slope_per_hour(points):
    """Least-squares slope of (hours, value) points; None with fewer than 2 distinct x values."""
    pts = [(x, y) for x, y in points if y is not None]
    if len(pts) < 2:
        return None
    n = float(len(pts))
    mx = sum(p[0] for p in pts) / n
    my = sum(p[1] for p in pts) / n
    sxx = sum((p[0] - mx) ** 2 for p in pts)
    if sxx == 0:
        return None
    return sum((p[0] - mx) * (p[1] - my) for p in pts) / sxx


def fmt(v, nd=1):
    if v is None:
        return '-'
    if isinstance(v, float) and v.is_integer() and abs(v) >= 1000:
        return '%d' % v
    return ('%.' + str(nd) + 'f') % v


def utc(ep):
    """Epoch seconds -> 'YYYY-MM-DDTHH:MMZ'; None for None."""
    if ep is None:
        return None
    import datetime
    return datetime.datetime.fromtimestamp(ep, datetime.timezone.utc).strftime('%Y-%m-%dT%H:%MZ')


def mode_of(values):
    vs = [v for v in values if v is not None]
    if not vs:
        return None
    return max(set(vs), key=lambda v: (vs.count(v), v))


# ---------------------------------------------------------------------------------------------------------------
# Result header (T-173 rule: every recorded number names its build, setup and run count)

HEADER_KEYS = [
    ('date_utc', 'UTC time of the run'),
    ('host_sha', 'host commit (T-145 app_start)'),
    ('apk_sha', 'APK commit (T-146 app_start / profile)'),
    ('macos', 'macOS version (build)'),
    ('harmonyos', 'tablet ro.build.display.id'),
    ('codec', 'stream codec / decoder'),
    ('transport', 'topology / transport'),
    ('resolution', 'stream resolution (display)'),
    ('target_hz', 'requested panel Hz'),
    ('real_hz', 'measured panel Hz (vsync p50)'),
    ('bitrate_kbps', 'bitrate'),
    ('mode', 'stream mode / pacer'),
    ('content', 'what was on screen / being done'),
    ('duration_s', 'measured duration'),
    ('run', 'run k of n'),
]
HEADER_BEGIN = '== result header (T-173) =='
HEADER_END = '== end header =='


def read_header(path):
    """key: value pairs of a header block in `path` (the first block found); {} when no path."""
    out = {}
    if not path:
        return out
    inside = False
    with open(path, errors='replace') as fh:
        for line in fh:
            s = line.rstrip('\n')
            if s.strip() == HEADER_BEGIN:
                inside = True
                continue
            if s.strip() == HEADER_END:
                break
            if inside:
                k, sep, v = s.partition(':')
                if sep and k.strip() in dict(HEADER_KEYS):
                    out[k.strip()] = v.strip()
    return out


def header_lines(values, run=None, runs=None):
    """The header block. Missing values print '-'; fewer than 3 runs is flagged as not a claim."""
    v = dict(values)
    if run is not None or runs is not None:
        v['run'] = '%s of %s' % (run if run is not None else '-', runs if runs is not None else '-')
    lines = [HEADER_BEGIN]
    for k, _desc in HEADER_KEYS:
        val = v.get(k)
        lines.append('%s: %s' % (k, val if val not in (None, '') else '-'))
    n = None
    m = re.search(r'of (\d+)', v.get('run') or '')
    if m:
        n = int(m.group(1))
    lines.append('claim_ok: %s' % ('yes (%d runs planned: quote the spread over all of them, not one run)' % n
                                   if n is not None and n >= 3 else
                                   'no (fewer than 3 runs: do not quote as a result)'))
    lines.append(HEADER_END)
    return lines


def add_header_args(ap):
    ap.add_argument('--header', help='header file from scripts/device-smoke.sh (--header-only or a full run)')
    ap.add_argument('--content', help='what was on screen / being done (e.g. "Krita pen strokes")')
    ap.add_argument('--run', type=int, help='this run number (k)')
    ap.add_argument('--runs', type=int, help='planned runs for this condition (n, >= 3 for any claim)')


def merged_header(args, derived):
    """Header values: derived from the inputs, overridden by --header file values, then by flags."""
    h = {k: v for k, v in derived.items() if v not in (None, '')}
    for k, v in read_header(getattr(args, 'header', None)).items():
        if v != '-':
            h.setdefault(k, v)
    if getattr(args, 'content', None):
        h['content'] = args.content
    run, runs = getattr(args, 'run', None), getattr(args, 'runs', None)
    if run is None and runs is None and 'run' in h:
        return h, None, None
    return h, run, runs


# ---------------------------------------------------------------------------------------------------------------
# CLI

def _raw_lines(fd, seconds=None):
    """Raw byte lines of file descriptor `fd` until EOF, or until `seconds` have passed (select-based, works on pipes
    and fifos). The last line may lack its newline."""
    deadline = None if seconds is None else time.monotonic() + seconds
    buf = b''
    while True:
        if deadline is not None:
            left = deadline - time.monotonic()
            if left <= 0:
                return
            r, _, _ = select.select([fd], [], [], left)
            if not r:
                return
        chunk = os.read(fd, 65536)
        if not chunk:
            if buf:
                yield buf
            return
        buf += chunk
        while b'\n' in buf:
            line, buf = buf.split(b'\n', 1)
            yield line + b'\n'


def main(argv=None):
    ap = argparse.ArgumentParser(description='MateBridge log privacy filter (T-173).')
    sub = ap.add_subparsers(dest='cmd', required=True)
    f = sub.add_parser('filter', help='stdin raw log -> stdout filtered numeric lines')
    f.add_argument('--side', choices=['tablet', 'host'], required=True)
    f.add_argument('--seconds', type=float, help='stop after this many seconds')
    f.add_argument('--skip-first', type=int, default=0, help='drop the first N non-divider input lines')
    f.add_argument('--agp', action='store_true', help='also keep Huawei AGP lcd fps / touch numbers (tablet)')
    f.add_argument('--events', action='store_true', help='only stability event names (soak counts), no fields')
    f.add_argument('--bytes-to', help='write the number of input bytes read to this file (transfer check)')
    a = ap.parse_args(argv)
    side = 'T' if a.side == 'tablet' else 'H'
    skip = a.skip_first
    nbytes = 0
    for raw in _raw_lines(sys.stdin.fileno(), a.seconds):
        nbytes += len(raw)
        line = raw.decode('utf-8', 'replace')
        if skip > 0 and not line.startswith('---------'):
            skip -= 1
            continue
        out = filter_line(line, side, agp=a.agp, events=a.events)
        if out:
            sys.stdout.write(out + '\n')
            sys.stdout.flush()
    if a.bytes_to:
        with open(a.bytes_to, 'w') as fh:
            fh.write('%d\n' % nbytes)
    return 0


if __name__ == '__main__':
    sys.exit(main())
