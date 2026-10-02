#!/usr/bin/env python3
"""T-138: a thumbnailer's access pattern without any UI.

  readers.py <hold-seconds> <file>...

For every file at once (one thread each), like AudiovisualThumbnailExtension does for a folder of videos: open it
(webdavfs then starts downloading the whole file), read the first 64 KB, then the last 64 KB (where a phone video keeps
its `moov` index), then keep it open for <hold-seconds> (or until the reads are done, whichever is later) and close.
Prints one line per step with the time since start, so a stalled read is visible.
"""
import os
import sys
import threading
import time

T0 = time.monotonic()
hold = float(sys.argv[1])
lock = threading.Lock()


def say(msg):
    with lock:
        print(f"{(time.monotonic() - T0) * 1000:8.0f} ms readers: {msg}", flush=True)


def reader(path):
    name = os.path.basename(path)
    with open(path, "rb") as f:
        say(f"{name} open")
        f.read(65536)
        say(f"{name} head read")
        size = os.fstat(f.fileno()).st_size
        f.seek(max(0, size - 65536))
        f.read(65536)
        say(f"{name} tail read")
        left = hold - (time.monotonic() - T0)
        if left > 0:
            time.sleep(left)
    say(f"{name} closed")


threads = [threading.Thread(target=reader, args=(p,), daemon=True) for p in sys.argv[2:]]
for t in threads:
    t.start()
for t in threads:
    t.join()
say("all closed")
