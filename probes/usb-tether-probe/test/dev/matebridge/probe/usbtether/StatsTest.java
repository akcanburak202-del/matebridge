package dev.matebridge.probe.usbtether;

/** Host-JVM self-test for the pure parts (run by build.sh; no JUnit, the probe has no Gradle). */
public final class StatsTest {
    private StatsTest() {}

    public static void main(String[] args) {
        long[] sorted = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};
        check(Stats.percentile(sorted, 50) == 5, "p50 of 1..10 is 5");
        check(Stats.percentile(sorted, 99) == 10, "p99 of 1..10 is 10");
        check(Stats.percentile(new long[] {7}, 99) == 7, "single sample");
        String s = Stats.summary(new long[] {3_000_000, 1_000_000, 2_000_000});
        check(s.equals("n=3 min=1.000 p50=2.000 p99=3.000 max=3.000 ms"), "summary: " + s);
        check(Stats.summary(new long[0]).equals("n=0"), "empty summary");
        check(TetherProbe.errorName(0).equals("NO_ERROR"), "error 0");
        check(TetherProbe.errorName(14).equals("NO_CHANGE_TETHERING_PERMISSION"), "error 14");
        check(TetherProbe.errorName(99).equals("UNKNOWN(99)"), "error 99");
        System.out.println("StatsTest OK");
    }

    private static void check(boolean ok, String what) {
        if (!ok) throw new AssertionError(what);
    }
}
