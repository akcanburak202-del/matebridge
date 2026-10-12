package dev.matebridge.client.cursor

import dev.matebridge.client.protocol.CursorState
import dev.matebridge.client.protocol.PointerRel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random
import kotlin.math.hypot
import kotlin.math.sin

/**
 * T-343: long links (a relay with RTT 250 ms). A small network simulation: the client sends relative motion at 120 Hz, the
 * host applies it on arrival and reports its position at [Sim.stateHz], every packet is delayed by half the RTT plus jitter.
 * The predictor's measured `pred_err` must beat `hold_err`, and a stopped cursor must settle on the host position.
 */
class CursorPredictorRttTest {
    private companion object {
        const val W = 2000
        const val H = 1200
        const val OFFSET = 9_000_000L
    }

    private class Sim(val rttMs: Int, val jitterMs: Int, val stateHz: Int, seed: Long = 7) {
        val stats = CursorStats()
        private val rnd = Random(seed)

        // The client's clock sync keeps the best RTT: the fastest round trip seen, about RTT - jitter.
        private val bestOneWayUs = (rttMs - jitterMs).coerceAtLeast(2) * 500L
        val p = CursorPredictor({ h -> h - OFFSET }, { bestOneWayUs }, stats)
        val out = CursorPredictor.Result()
        var hostX = W / 2f
        var hostY = H / 2f
        private var seq = 0L
        var lastSeq = 0L

        private class Rel(val atUs: Long, val dx: Float, val dy: Float)
        private class St(val atUs: Long, val sampleUs: Long, val x: Float, val y: Float, val seq: Long)

        private val relQ = ArrayList<Rel>()
        private val stQ = ArrayList<St>()
        private var lastStRx = 0L
        private var lastRelRx = 0L
        private var nextRelUs = 0L
        private var nextStUs = 0L

        private fun oneWayUs(): Long = rttMs * 500L + ((rnd.nextDouble() * 2 - 1) * jitterMs * 500.0).toLong()

        init {
            p.setStream(W, H)
            p.setLayerOn(true)
            p.beginSession(1)
            p.onState(CursorState(0, (hostX / W * 65535).toInt(), (hostY / H * 65535).toInt(), true, 1, OFFSET), 0)
        }

        /** Runs [fromMs] until [toMs] in 1 ms steps; [speed] is the pointer speed in pt/s at a time in ms (0 = still). */
        fun run(fromMs: Int, toMs: Int, speed: (Int) -> Float) {
            if (nextRelUs < fromMs * 1000L) nextRelUs = fromMs * 1000L
            if (nextStUs < fromMs * 1000L) nextStUs = fromMs * 1000L
            for (ms in fromMs until toMs) {
                val nowUs = ms * 1000L
                while (nextRelUs <= nowUs) {
                    val v = speed(ms)
                    if (v != 0f) {
                        val dx = v / 120f
                        val dy = v / 400f
                        p.onSent(PointerRel(nextRelUs, dx, dy, 0), nextRelUs, 1)
                        lastRelRx = maxOf(lastRelRx, nextRelUs + oneWayUs())
                        relQ.add(Rel(lastRelRx, dx, dy))
                    }
                    nextRelUs += 1_000_000L / 120
                }
                val ri = relQ.iterator()
                while (ri.hasNext()) {
                    val a = ri.next()
                    if (a.atUs <= nowUs) {
                        hostX = (hostX + a.dx).coerceIn(0f, W.toFloat())
                        hostY = (hostY + a.dy).coerceIn(0f, H.toFloat())
                        ri.remove()
                    }
                }
                while (nextStUs <= nowUs) {
                    seq++
                    lastStRx = maxOf(lastStRx, nextStUs + oneWayUs())
                    stQ.add(St(lastStRx, nextStUs, hostX, hostY, seq))
                    nextStUs += 1_000_000L / stateHz
                }
                val si = stQ.iterator()
                while (si.hasNext()) {
                    val s = si.next()
                    if (s.atUs <= nowUs) {
                        p.onState(
                            CursorState(s.seq, (s.x / W * 65535).toInt(), (s.y / H * 65535).toInt(), true, 1, s.sampleUs + OFFSET),
                            s.atUs,
                        )
                        lastSeq = s.seq
                        lastStX = s.x
                        lastStY = s.y
                        si.remove()
                    }
                }
                if (ms % 7 == 0) sampleDraw(ms, speed(ms))
            }
        }

        private var lastStX = W / 2f
        private var lastStY = H / 2f
        private var prevDrawX = Float.NaN
        val drawErr = ArrayList<Float>()
        val holdDrawErr = ArrayList<Float>()

        /** Largest step against the motion direction between two frames while moving (a snap back). */
        var maxBackStepPt = 0f

        /** One frame at [ms]: the drawn cursor against the intent (host position plus what is still in flight). */
        private fun sampleDraw(ms: Int, v: Float) {
            var ix = hostX
            var iy = hostY
            for (a in relQ) { ix += a.dx; iy += a.dy }
            ix = ix.coerceIn(0f, W.toFloat())
            iy = iy.coerceIn(0f, H.toFloat())
            val pos = predicted(ms * 1000L) ?: (lastStX to lastStY)
            if (ms < 1_000) return
            drawErr.add(hypot(pos.first - ix, pos.second - iy))
            holdDrawErr.add(hypot(lastStX - ix, lastStY - iy))
            if (v != 0f && !prevDrawX.isNaN()) {
                val back = -(pos.first - prevDrawX) * Math.signum(v)
                if (back > maxBackStepPt) maxBackStepPt = back
            }
            prevDrawX = pos.first
        }

        fun pct(l: List<Float>, p: Int): Float = l.sorted().let { it[((it.size - 1) * p + 50) / 100] }

        fun predicted(nowUs: Long): Pair<Float, Float>? {
            if (!p.advance(lastSeq, nowUs, out)) return null
            return out.xNorm / 65535f * W to out.yNorm / 65535f * H
        }
    }

    /** Moves 1.5 s at 100..900 pt/s (a sine), still 1 s; repeating, right then left (the host clamps at the edges). */
    private val wobble: (Int) -> Float = { ms ->
        val t = ms % 2500
        val dir = if ((ms / 2500) % 2 == 0) 1f else -1f
        if (t < 1500) dir * (100f + 800f * (0.5f + 0.5f * sin(t / 1500f * Math.PI.toFloat() * 2 - 1.2f))) else 0f
    }

    @Test fun onALongLinkThePredictionBeatsHoldingTheLastState() {
        val sim = Sim(rttMs = 250, jitterMs = 30, stateHz = 15)
        sim.run(0, 12_500, wobble)
        val s = sim.stats.take()
        assertTrue("states measured: ${s.predN}", s.predN > 100)
        assertTrue("p50 pred ${s.predErrP50Pt} hold ${s.holdErrP50Pt}", s.predErrP50Pt < s.holdErrP50Pt * 0.5f)
        assertTrue("p95 pred ${s.predErrP95Pt} hold ${s.holdErrP95Pt}", s.predErrP95Pt < s.holdErrP95Pt * 0.7f)
        // What the user sees: the drawn cursor against where the cursor is heading (host plus motion still in flight).
        val d50 = sim.pct(sim.drawErr, 50)
        val d95 = sim.pct(sim.drawErr, 95)
        val h50 = sim.pct(sim.holdDrawErr, 50)
        val h95 = sim.pct(sim.holdDrawErr, 95)
        assertTrue("draw p50 $d50 hold $h50", d50 < h50 * 0.2f)
        assertTrue("draw p95 $d95 hold $h95", d95 < h95 * 0.3f)
        assertTrue("snap back ${sim.maxBackStepPt} pt", sim.maxBackStepPt < 10f) // a frame moves up to 6 pt forward
    }

    @Test fun afterTheMotionStopsTheCursorSettlesOnTheHostPosition() {
        val sim = Sim(rttMs = 250, jitterMs = 30, stateHz = 15)
        sim.run(0, 2_500, wobble) // moves until 1500 ms, still after
        // Everything has arrived and been reported about RTT + one state interval + jitter after the last move.
        sim.run(2_500, 3_300) { 0f }
        val pos = sim.predicted(3_299_000L)
        assertNotNull(pos)
        val err = hypot(pos!!.first - sim.hostX, pos.second - sim.hostY)
        assertTrue("settle error $err pt", err < 2f)
    }

    @Test fun aLineBeyondTheCeilingFallsBackToTheHostPosition() {
        val sim = Sim(rttMs = 1_400, jitterMs = 0, stateHz = 15)
        sim.run(0, 4_000, wobble)
        assertFalse(sim.p.advance(sim.lastSeq, 3_999_000L, sim.out))
    }

    @Test fun onALanLinkTheSettleTimeIsTheOldOne() {
        // 15 ms RTT: a delta older than 100 ms is settled (as before T-343), one 90 ms old is still applied.
        val p = CursorPredictor({ h -> h - OFFSET }, { 7_500L }, null)
        p.setStream(W, H)
        p.setLayerOn(true)
        p.beginSession(1)
        p.onState(CursorState(1, 32768, 32768, true, 1, OFFSET), 0)
        val out = CursorPredictor.Result()
        p.onSent(PointerRel(10_000, 20f, 0f, 0), 10_000, 1)
        assertTrue(p.advance(1, 100_000, out)) // 90 ms old
        assertEquals(1000f + 20f, out.xNorm / 65535f * W, 0.1f)
        assertTrue(p.advance(1, 111_000, out)) // 101 ms old: settled
        assertEquals(1000f, out.xNorm / 65535f * W, 0.1f)
    }
}
