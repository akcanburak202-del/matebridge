package dev.matebridge.probe.usbtether;

import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;

import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * T-273 probe: drives the tethering service as the adb shell user (uid 2000, TETHER_PRIVILEGED)
 * and measures TCP reachability of the Mac from the app uid (run-as). Not product code.
 *
 * Launched with: CLASSPATH=/data/local/tmp/usb-tether-probe.jar app_process / dev.matebridge.probe.usbtether.TetherProbe CMD...
 * Every result line starts with "RESULT " so run.sh can grep it.
 */
public final class TetherProbe {
    private static final String CALLER_PKG = "com.android.shell";
    private static final String LISTENER_DESCRIPTOR = "android.net.IIntResultListener";

    // android.net.TetheringManager constants (public API values)
    private static final int TETHERING_WIFI = 0;
    private static final int TETHERING_USB = 1;
    private static final int TETHERING_BLUETOOTH = 2;
    private static final int TETHERING_WIFI_P2P = 3;
    private static final int TETHERING_NCM = 4;
    private static final int TETHERING_ETHERNET = 5;

    // TetheringManager.CONNECTIVITY_SCOPE_*
    private static final int SCOPE_GLOBAL = 1;
    private static final int SCOPE_LOCAL = 2;

    private static final String[] ERROR_NAMES = {
        "NO_ERROR", "UNKNOWN_IFACE", "SERVICE_UNAVAIL", "UNSUPPORTED", "UNAVAIL_IFACE",
        "INTERNAL_ERROR", "TETHER_IFACE_ERROR", "UNTETHER_IFACE_ERROR", "ENABLE_FORWARDING_ERROR",
        "DISABLE_FORWARDING_ERROR", "IFACE_CFG_ERROR", "PROVISIONING_FAILED", "DHCPSERVER_ERROR",
        "ENTITLEMENT_UNKNOWN", "NO_CHANGE_TETHERING_PERMISSION", "NO_ACCESS_TETHERING_PERMISSION",
        "UNKNOWN_TYPE",
    };

    private TetherProbe() {}

    public static void main(String[] args) {
        if (args.length == 0) {
            usage();
            System.exit(2);
        }
        try {
            String cmd = args[0];
            switch (cmd) {
                case "info": info(); break;
                case "start": startTethering(parseType(arg(args, 1)), args.length > 2 ? parseScope(args[2]) : SCOPE_GLOBAL); break;
                case "stop": stopTethering(parseType(arg(args, 1))); break;
                case "stopall": stopAll(); break;
                case "legacy-usb": legacyUsb("on".equals(arg(args, 1))); break;
                case "tether": tetherIface(arg(args, 1), true); break;
                case "untether": tetherIface(arg(args, 1), false); break;
                case "rtt": rtt(arg(args, 1), Integer.parseInt(arg(args, 2)), Integer.parseInt(arg(args, 3))); break;
                case "tput": tput(arg(args, 1), Integer.parseInt(arg(args, 2)), Integer.parseInt(arg(args, 3))); break;
                default: usage(); System.exit(2);
            }
        } catch (Throwable t) {
            Throwable root = t;
            while (root.getCause() != null) root = root.getCause();
            System.out.println("RESULT exception " + root.getClass().getName() + ": " + root.getMessage());
            System.exit(1);
        }
        System.exit(0);
    }

    private static void usage() {
        System.out.println("usage: info | start usb|ncm|ethernet [global|local] | stop usb|ncm|ethernet | stopall"
            + " | legacy-usb on|off | tether IFACE | untether IFACE | rtt HOST PORT N | tput HOST PORT SECONDS");
    }

    private static String arg(String[] args, int i) {
        if (i >= args.length) throw new IllegalArgumentException("missing argument " + i);
        return args[i];
    }

    private static int parseType(String s) {
        switch (s) {
            case "usb": return TETHERING_USB;
            case "ncm": return TETHERING_NCM;
            case "ethernet": return TETHERING_ETHERNET;
            default: return Integer.parseInt(s);
        }
    }

    private static int parseScope(String s) {
        switch (s) {
            case "global": return SCOPE_GLOBAL;
            case "local": return SCOPE_LOCAL;
            default: return Integer.parseInt(s);
        }
    }

    static String errorName(int code) {
        return code >= 0 && code < ERROR_NAMES.length ? ERROR_NAMES[code] : "UNKNOWN(" + code + ")";
    }

    // ---- tethering service access (reflection on hidden AIDL classes) ----

    private static Object connector() throws Exception {
        Class<?> sm = Class.forName("android.os.ServiceManager");
        IBinder binder = (IBinder) sm.getMethod("getService", String.class).invoke(null, "tethering");
        if (binder == null) throw new IllegalStateException("tethering service not found");
        Class<?> stub = Class.forName("android.net.ITetheringConnector$Stub");
        return stub.getMethod("asInterface", IBinder.class).invoke(null, binder);
    }

    private static Method method(Object target, String name) {
        for (Method m : target.getClass().getMethods()) {
            if (m.getName().equals(name)) return m;
        }
        throw new IllegalStateException("no method " + name + " on " + target.getClass().getName());
    }

    /** Receives IIntResultListener.onResult(int) on a binder thread. */
    private static final class ResultBinder extends Binder {
        final CountDownLatch done = new CountDownLatch(1);
        volatile int result = Integer.MIN_VALUE;

        @Override
        protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
            if (code == FIRST_CALL_TRANSACTION) {
                data.enforceInterface(LISTENER_DESCRIPTOR);
                result = data.readInt();
                done.countDown();
                return true;
            }
            try {
                return super.onTransact(code, data, reply, flags);
            } catch (Exception e) {
                return false;
            }
        }

        Object asListener() throws Exception {
            Class<?> stub = Class.forName("android.net.IIntResultListener$Stub");
            // No attachInterface: asInterface() then wraps us in a Proxy whose asBinder() is this object.
            return stub.getMethod("asInterface", IBinder.class).invoke(null, this);
        }

        void report(String what) throws InterruptedException {
            if (done.await(15, TimeUnit.SECONDS)) {
                System.out.println("RESULT " + what + " code=" + result + " " + errorName(result));
            } else {
                System.out.println("RESULT " + what + " timeout (no callback in 15 s)");
            }
        }
    }

    /** Fills a call's arguments by parameter type; strings are given in declaration order. */
    private static Object[] fill(Method m, Object listener, Object parcel, int intArg, boolean boolArg, String... strings) {
        Class<?>[] types = m.getParameterTypes();
        Object[] out = new Object[types.length];
        int si = 0;
        for (int i = 0; i < types.length; i++) {
            Class<?> t = types[i];
            if (t == String.class) out[i] = si < strings.length ? strings[si++] : null;
            else if (t == int.class) out[i] = intArg;
            else if (t == boolean.class) out[i] = boolArg;
            else if (t.getName().endsWith("IIntResultListener")) out[i] = listener;
            else if (t.getName().endsWith("TetheringRequestParcel")) out[i] = parcel;
            else out[i] = null;
        }
        return out;
    }

    private static Object requestParcel(int type, int scope) throws Exception {
        Class<?> c = Class.forName("android.net.TetheringRequestParcel");
        Constructor<?> ctor = c.getDeclaredConstructor();
        ctor.setAccessible(true);
        Object p = ctor.newInstance();
        setField(p, "tetheringType", type);
        // true makes TetheringService demand NETWORK_STACK (onlyAllowPrivileged) -> error 14 for the
        // shell user; with false, TETHER_PRIVILEGED suffices and no provisioning app is configured.
        setField(p, "exemptFromEntitlementCheck", false);
        setField(p, "showProvisioningUi", false);
        setField(p, "connectivityScope", scope);
        return p;
    }

    private static void setField(Object o, String name, Object value) {
        try {
            Field f = o.getClass().getField(name);
            f.set(o, value);
        } catch (NoSuchFieldException | IllegalAccessException e) {
            System.out.println("note: field " + name + " not set (" + e + ")");
        }
    }

    private static void info() throws Exception {
        Object c = connector();
        System.out.println("connector class: " + c.getClass().getName());
        Method[] ms = c.getClass().getDeclaredMethods();
        Arrays.sort(ms, (a, b) -> a.getName().compareTo(b.getName()));
        for (Method m : ms) {
            if (!Modifier.isPublic(m.getModifiers())) continue;
            StringBuilder sb = new StringBuilder("  ").append(m.getName()).append('(');
            Class<?>[] p = m.getParameterTypes();
            for (int i = 0; i < p.length; i++) sb.append(i == 0 ? "" : ", ").append(p[i].getSimpleName());
            System.out.println(sb.append(')'));
        }
        Class<?> rp = Class.forName("android.net.TetheringRequestParcel");
        for (Field f : rp.getFields()) {
            if (!Modifier.isStatic(f.getModifiers())) System.out.println("  parcel field " + f.getType().getSimpleName() + " " + f.getName());
        }
        System.out.println("RESULT info ok");
    }

    private static void startTethering(int type, int scope) throws Exception {
        Object c = connector();
        ResultBinder rb = new ResultBinder();
        Method m = method(c, "startTethering");
        m.invoke(c, fill(m, rb.asListener(), requestParcel(type, scope), type, true, CALLER_PKG, null));
        rb.report("startTethering type=" + type + " scope=" + scope);
    }

    private static void stopTethering(int type) throws Exception {
        Object c = connector();
        ResultBinder rb = new ResultBinder();
        Method m = method(c, "stopTethering");
        m.invoke(c, fill(m, rb.asListener(), null, type, false, CALLER_PKG, null));
        rb.report("stopTethering type=" + type);
    }

    private static void stopAll() throws Exception {
        Object c = connector();
        ResultBinder rb = new ResultBinder();
        Method m = method(c, "stopAllTethering");
        m.invoke(c, fill(m, rb.asListener(), null, 0, false, CALLER_PKG, null));
        rb.report("stopAllTethering");
    }

    private static void legacyUsb(boolean enable) throws Exception {
        Object c = connector();
        ResultBinder rb = new ResultBinder();
        Method m = method(c, "setUsbTethering");
        m.invoke(c, fill(m, rb.asListener(), null, 0, enable, CALLER_PKG, null));
        rb.report("setUsbTethering enable=" + enable);
    }

    private static void tetherIface(String iface, boolean tether) throws Exception {
        Object c = connector();
        ResultBinder rb = new ResultBinder();
        String name = tether ? "tether" : "untether";
        Method m = method(c, name);
        m.invoke(c, fill(m, rb.asListener(), null, 0, false, iface, CALLER_PKG, null));
        rb.report(name + " iface=" + iface);
    }

    // ---- network measurements (run under run-as dev.matebridge.client for the app uid) ----

    private static Socket connect(String host, int port) throws Exception {
        Socket s = new Socket();
        s.setTcpNoDelay(true);
        long t0 = System.nanoTime();
        s.connect(new InetSocketAddress(host, port), 3000);
        System.out.printf(java.util.Locale.ROOT, "RESULT connect %s:%d ok in %.2f ms (local %s)%n", host, port,
            (System.nanoTime() - t0) / 1e6, s.getLocalSocketAddress());
        return s;
    }

    /** Echo ping-pong with a 64-byte payload; prints min/p50/p99/max round-trip time. */
    private static void rtt(String host, int port, int n) throws Exception {
        try (Socket s = connect(host, port)) {
            s.setSoTimeout(3000);
            OutputStream out = s.getOutputStream();
            InputStream in = s.getInputStream();
            byte[] buf = new byte[64];
            long[] samples = new long[n];
            for (int i = 0; i < n; i++) {
                buf[0] = (byte) i;
                long t0 = System.nanoTime();
                out.write(buf);
                out.flush();
                int got = 0;
                while (got < buf.length) {
                    int r = in.read(buf, got, buf.length - got);
                    if (r < 0) throw new IllegalStateException("echo closed after " + i);
                    got += r;
                }
                samples[i] = System.nanoTime() - t0;
            }
            System.out.println("RESULT rtt " + Stats.summary(samples));
        }
    }

    /** Sends zeros to a sink for the given duration; prints throughput in Mbit/s. */
    private static void tput(String host, int port, int seconds) throws Exception {
        try (Socket s = connect(host, port)) {
            OutputStream out = s.getOutputStream();
            byte[] buf = new byte[64 * 1024];
            long bytes = 0;
            long t0 = System.nanoTime();
            long end = t0 + seconds * 1_000_000_000L;
            while (System.nanoTime() < end) {
                out.write(buf);
                bytes += buf.length;
            }
            out.flush();
            s.shutdownOutput();
            // Sink answers with its own byte count once we close, so the number is end-to-end.
            s.setSoTimeout(5000);
            InputStream in = s.getInputStream();
            byte[] ack = new byte[64];
            int n = in.read(ack);
            double sec = (System.nanoTime() - t0) / 1e9;
            System.out.printf(java.util.Locale.ROOT, "RESULT tput sent=%d B in %.2f s = %.1f Mbit/s; sink says %s%n", bytes, sec,
                bytes * 8 / sec / 1e6, n > 0 ? new String(ack, 0, n, "US-ASCII").trim() : "nothing");
        }
    }
}
