import dev.matebridge.client.files.DavServer;
import dev.matebridge.client.files.FilesConfig;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * T-137 repro: runs the tablet's DavServer on the Mac's JVM (no Android) and puts a logging TCP proxy in front of it,
 * so a real NetFS/webdavfs mount can be timed and its HTTP exchange dumped.
 *
 * Usage: java -cp ... DavRepro <root-dir> <proxy-port>   (token from env MB_DAV_TOKEN; never printed)
 *
 * The dump has one line per request/response head: time since start, connection number, direction, start line and
 * header names with values, except that the Authorization value is reduced to its scheme and the token never appears.
 */
public final class DavRepro {
    private static final long T0 = System.nanoTime();

    public static void main(String[] args) throws Exception {
        if (args.length != 2) {
            System.err.println("usage: DavRepro <root-dir> <proxy-port>");
            System.exit(2);
        }
        String token = System.getenv("MB_DAV_TOKEN");
        if (token == null || token.isEmpty()) {
            System.err.println("MB_DAV_TOKEN not set");
            System.exit(2);
        }
        File root = new File(args[0]);
        int proxyPort = Integer.parseInt(args[1]);
        byte[] secret = new byte[32];
        new java.security.SecureRandom().nextBytes(secret);

        CountDownLatch listening = new CountDownLatch(1);
        int[] serverPort = new int[1];
        // MB_DAV_RATE (bytes/s): the rate cap; default 200 MB/s (T-137 mount timing). T-138 uses the device's 20 MB/s.
        long rate = System.getenv("MB_DAV_RATE") != null ? Long.parseLong(System.getenv("MB_DAV_RATE")) : 200_000_000L;
        // MB_DAV_MAXCONN: the server's connection limit (default the app's). MB_DAV_DIRECT=1: no proxy, the server
        // itself listens on <proxy-port> (rules out proxy artefacts; no HTTP dump then).
        int maxConn = System.getenv("MB_DAV_MAXCONN") != null ? Integer.parseInt(System.getenv("MB_DAV_MAXCONN"))
                : FilesConfig.MAX_CONNECTIONS;
        boolean direct = "1".equals(System.getenv("MB_DAV_DIRECT"));
        // MB_DAV_OVERFLOW: connections taken beyond the limit when none is idle (T-139; 0 = the old wait, then 503).
        int overflow = System.getenv("MB_DAV_OVERFLOW") != null ? Integer.parseInt(System.getenv("MB_DAV_OVERFLOW"))
                : FilesConfig.OVERFLOW_CONNECTIONS;
        // MB_DAV_PROFILE=wifi (T-266): the Wi-Fi profile (64 KiB bursts, 16 KiB buffers, small-request lane) at MB_DAV_RATE.
        // MB_DAV_LANE=0: the same profile without the small-request lane (the "before" of the lane measurement).
        boolean wifi = "wifi".equals(System.getenv("MB_DAV_PROFILE"));
        boolean lane = !"0".equals(System.getenv("MB_DAV_LANE"));
        long burst = wifi ? FilesConfig.WIFI_BURST_BYTES : 256L * 1024;
        int buffer = wifi ? FilesConfig.WIFI_BUFFER_BYTES : FilesConfig.BUFFER_BYTES;
        long smallRate = wifi && lane ? FilesConfig.WIFI_SMALL_RATE_BYTES_PER_SEC : 0L;
        FilesConfig cfg = new FilesConfig(rate, burst, maxConn, buffer,
                FilesConfig.IDLE_TIMEOUT_MS, FilesConfig.READ_TIMEOUT_MS, direct ? proxyPort : 0,
                FilesConfig.EVICT_IDLE_MS, overflow, FilesConfig.ADMIT_WAIT_MS, FilesConfig.WRITE_TIMEOUT_MS,
                false, smallRate, FilesConfig.SMALL_BURST_BYTES, FilesConfig.SMALL_THRESHOLD_BYTES);
        DavServer server = new DavServer(root, token, secret, cfg, new DavServer.Hooks() {
            @Override public void threadStarted() { }
            @Override public void log(String ev, String fields) {
                if (fields.contains(token)) throw new IllegalStateException("token in log");
                out("server", "ev=" + ev + " " + fields);
            }
            @Override public void onListening(int port) { serverPort[0] = port; listening.countDown(); }
            @Override public void onStopped(boolean failed) { out("server", "stopped failed=" + failed); }
        }, System::currentTimeMillis, null);
        server.start();
        listening.await();
        out("server", "listening port=" + serverPort[0] + " rate=" + rate + " max_conn=" + maxConn + " profile=" + (wifi ? "wifi" : "usb") + " lane=" + (smallRate > 0 ? 1 : 0) + " overflow=" + overflow);
        if (direct) {
            out("proxy", "listening port=" + proxyPort + " (direct: no proxy)");
            Thread.sleep(Long.MAX_VALUE);
        }

        ServerSocket ss = new ServerSocket();
        ss.setReuseAddress(true);
        ss.bind(new InetSocketAddress(InetAddress.getByAddress(new byte[] {127, 0, 0, 1}), proxyPort));
        out("proxy", "listening port=" + proxyPort);
        AtomicInteger connNo = new AtomicInteger();
        while (true) {
            Socket c = ss.accept();
            int n = connNo.incrementAndGet();
            Socket s = new Socket(InetAddress.getByAddress(new byte[] {127, 0, 0, 1}), serverPort[0]);
            c.setTcpNoDelay(true);
            s.setTcpNoDelay(true);
            out("c" + n, "open");
            pump(c, s, c, "c" + n + " >", token);
            pump(s, c, c, "c" + n + " <", token);
        }
    }

    /**
     * MB_DAV_PROXY_RESET=stall: when the client resets a connection, close only the client side and leave the server
     * side open and unread, the way a tunnel that stops reading but never closes would (models an adb forward whose
     * device end lingers). Default: close both sides, as a plain TCP path does.
     */
    private static final boolean STALL = "stall".equals(System.getenv("MB_DAV_PROXY_RESET"));

    private static void pump(Socket from, Socket to, Socket client, String tag, String token) {
        Thread t = new Thread(() -> {
            HeadSniffer sniff = new HeadSniffer(tag, token);
            byte[] buf = new byte[65536];
            try {
                InputStream in = from.getInputStream();
                OutputStream o = to.getOutputStream();
                int r;
                while ((r = in.read(buf)) > 0) {
                    sniff.feed(buf, r);
                    if (RAW) out(tag, "raw " + escape(buf, r, token));
                    o.write(buf, 0, r);
                    o.flush();
                }
                out(tag, "eof");
                try { to.shutdownOutput(); } catch (IOException ignored) { }
            } catch (IOException e) {
                // A reset (webdavfs aborting a download) closes both sides fully, as adb does on the device; a
                // half-close would leave the server writing into a socket nobody reads (T-138).
                out(tag, "closed " + e.getClass().getSimpleName() + (STALL ? " (stall: server side left open)" : ""));
                if (STALL) {
                    try { client.close(); } catch (IOException ignored) { }
                    return;
                }
                try { from.close(); } catch (IOException ignored) { }
                try { to.close(); } catch (IOException ignored) { }
            }
        });
        t.setDaemon(true);
        t.start();
    }

    /** Finds HTTP heads (request or status line + headers) in a byte stream; bodies are counted, not printed. */
    private static final class HeadSniffer {
        private final String tag;
        private final String token;
        private final ByteArrayOutputStream pending = new ByteArrayOutputStream();
        private long bodyBytes;

        HeadSniffer(String tag, String token) { this.tag = tag; this.token = token; }

        void feed(byte[] b, int n) {
            pending.write(b, 0, n);
            String s = new String(pending.toByteArray(), StandardCharsets.ISO_8859_1);
            int from = 0;
            while (true) {
                int start = findStart(s, from);
                if (start < 0) {
                    // keep a tail that may hold the beginning of a head
                    int keep = Math.max(from, s.length() - 64);
                    bodyBytes += keep - from;
                    reset(s.substring(keep));
                    return;
                }
                bodyBytes += start - from;
                int end = s.indexOf("\r\n\r\n", start);
                if (end < 0) {
                    reset(s.substring(start));
                    return;
                }
                if (bodyBytes > 0) out(tag, "  (+" + bodyBytes + " body bytes)");
                bodyBytes = 0;
                print(s.substring(start, end));
                from = end + 4;
            }
        }

        private void reset(String rest) {
            pending.reset();
            pending.writeBytes(rest.getBytes(StandardCharsets.ISO_8859_1));
        }

        private static int findStart(String s, int from) {
            int best = -1;
            java.util.regex.Matcher m = java.util.regex.Pattern
                    .compile("(?m)^(HTTP/1\\.[01] \\d{3}|[A-Z]+ \\S+ HTTP/1\\.[01](?=\\r\\n))").matcher(s);
            if (m.find(from)) best = m.start();
            return best;
        }

        private void print(String head) {
            StringBuilder sb = new StringBuilder();
            for (String line : head.split("\r\n")) {
                String l = line;
                if (l.regionMatches(true, 0, "authorization:", 0, 14)) {
                    String v = l.substring(14).trim();
                    int sp = v.indexOf(' ');
                    l = "Authorization: " + (sp > 0 ? v.substring(0, sp) : v) + " <redacted>";
                }
                if (l.contains(token)) l = "<line with token redacted>";
                sb.append(sb.length() == 0 ? "" : " | ").append(l);
            }
            out(tag, sb.toString());
        }
    }

    /** MB_DAV_RAW=1: also print every chunk read, escaped (bodies included; Authorization lines redacted). */
    private static final boolean RAW = "1".equals(System.getenv("MB_DAV_RAW"));

    private static String escape(byte[] b, int n, String token) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < n; i++) {
            int c = b[i] & 0xff;
            if (c == '\r') sb.append("\\r");
            else if (c == '\n') sb.append("\\n");
            else if (c < 32 || c > 126) sb.append(String.format("\\x%02x", c));
            else sb.append((char) c);
        }
        return sb.toString().replaceAll("(?i)(authorization: *\\S+)[^\\\\]*", "$1 <redacted>").replace(token, "<token>");
    }

    static synchronized void out(String who, String msg) {
        long ms = (System.nanoTime() - T0) / 1_000_000;
        System.out.printf("%8.3f %-6s %s%n", ms / 1000.0, who, msg);
        System.out.flush();
    }
}
