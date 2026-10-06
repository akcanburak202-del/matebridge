package dev.matebridge.probe.usbtether;

import java.util.Arrays;
import java.util.Locale;

/** Latency summary (nanosecond samples → "n=… min=… p50=… p99=… max=… ms"). Pure logic. */
final class Stats {
    private Stats() {}

    static String summary(long[] samplesNs) {
        if (samplesNs.length == 0) return "n=0";
        long[] s = samplesNs.clone();
        Arrays.sort(s);
        return String.format(Locale.ROOT, "n=%d min=%.3f p50=%.3f p99=%.3f max=%.3f ms",
            s.length, ms(s[0]), ms(percentile(s, 50)), ms(percentile(s, 99)), ms(s[s.length - 1]));
    }

    /** Nearest-rank percentile on a sorted array. */
    static long percentile(long[] sorted, int p) {
        int rank = (int) Math.ceil(p / 100.0 * sorted.length);
        return sorted[Math.max(0, Math.min(sorted.length - 1, rank - 1))];
    }

    private static double ms(long ns) {
        return ns / 1e6;
    }
}
