#!/usr/bin/env python3
"""T-273 temporary Mac listener: TCP echo (RTT) and sink (throughput) on the tether interface only.

Usage: mac_server.py BIND_IP [ECHO_PORT=47900] [SINK_PORT=47901]
Never binds MateBridge host ports (47001/47002/47003/47012). Ctrl-C / SIGTERM to stop.
"""
import socket
import sys
import threading
import time

HOST_PORTS = {47001, 47002, 47003, 47012}


def serve(bind_ip, port, handler):
    # getaddrinfo handles IPv4 and scoped IPv6 link-local ("fe80::1%en8") alike
    family, _, _, _, addr = socket.getaddrinfo(bind_ip, port, 0, socket.SOCK_STREAM)[0]
    srv = socket.socket(family, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(addr)
    srv.listen(4)
    print(f"listening {bind_ip}:{port} ({handler.__name__})", flush=True)
    while True:
        conn, peer = srv.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        print(f"{handler.__name__}: connection from {peer[0]}:{peer[1]}", flush=True)
        threading.Thread(target=handler, args=(conn,), daemon=True).start()


def echo(conn):
    with conn:
        while True:
            data = conn.recv(65536)
            if not data:
                return
            conn.sendall(data)


def sink(conn):
    with conn:
        total = 0
        t0 = time.monotonic()
        while True:
            data = conn.recv(1 << 20)
            if not data:
                break
            total += len(data)
        sec = time.monotonic() - t0
        msg = f"received={total} B in {sec:.2f} s = {total * 8 / max(sec, 1e-9) / 1e6:.1f} Mbit/s"
        print(f"sink: {msg}", flush=True)
        conn.sendall(msg.encode("ascii"))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    bind_ip = sys.argv[1]
    echo_port = int(sys.argv[2]) if len(sys.argv) > 2 else 47900
    sink_port = int(sys.argv[3]) if len(sys.argv) > 3 else 47901
    if {echo_port, sink_port} & HOST_PORTS:
        sys.exit("refusing to bind a MateBridge host port")
    threading.Thread(target=serve, args=(bind_ip, sink_port, sink), daemon=True).start()
    serve(bind_ip, echo_port, echo)


if __name__ == "__main__":
    main()
