#!/usr/bin/env python3
"""T-138: one-line summaries of thread snapshots taken by bulk.sh.

agent-*.txt  `sample webdavfs_agent` call graphs. The agent is stripped, so threads are classified by frames:
             in CFReadStreamRead (a GET body being read: a download or a byte-range read), other network
             (stream open / connect / write), idle request workers (agent code waiting on a condition variable).
server-*.txt `jstack` of DavRepro: per mb-files-* thread, the frame that matters (admit wait, token-bucket sleep,
             socket write/read).
"""
import re
import sys


def agent(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    graph = text.split("Call graph:", 1)[-1].split("Total number in stack", 1)[0]
    blocks = re.split(r"\n(?=    \d+ Thread_)", graph)
    c = {"threads": 0, "in_CFReadStreamRead": 0, "other_network": 0, "idle_workers": 0}
    for b in blocks:
        if not re.match(r"\s*\d+ Thread_", b.strip("\n")):
            continue
        c["threads"] += 1
        if "CFReadStreamRead" in b:
            c["in_CFReadStreamRead"] += 1
        elif re.search(r"CFReadStreamOpen|CFWriteStream|__connect", b):
            c["other_network"] += 1
        elif "in webdavfs_agent" in b and "_pthread_cond_wait" in b:
            c["idle_workers"] += 1
    return " ".join(f"{k}={v}" for k, v in c.items())


def server(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    out = []
    for block in text.split("\n\n"):
        m = re.match(r'"(mb-files-[a-z]+)"', block.strip())
        if not m:
            continue
        frames = [l.strip()[3:] for l in block.splitlines() if l.strip().startswith("at ")]
        all_ = "\n".join(frames)
        method = re.search(r"DavHandler\.(get|put|propfind|lock|moveOrCopy|delete)\(", all_)
        if "DavServer.admit" in all_:
            state = "admit-wait(all slots busy)"
        elif "HttpIo.readHead" in all_:
            state = "idle-keepalive"
        elif "TokenBucket" in all_:
            state = "bucket-sleep"
        elif re.search(r"NioSocketImpl\.(write|implWrite)|SocketOutputStream\.write|socketWrite", all_):
            state = "socket-write"
        elif re.search(r"NioSocketImpl\.(read|implRead)|SocketInputStream\.read", all_):
            state = "socket-read"
        elif "accept" in all_:
            state = "accept"
        else:
            state = "?"
        if method:
            state += f"[{method.group(1)}]"
        out.append(f"{m.group(1)}:{state}")
    return " ".join(sorted(out))


for p in sys.argv[1:]:
    name = p.rsplit("/", 1)[-1]
    print(f"{name}: {agent(p) if name.startswith('agent-') else server(p)}")
