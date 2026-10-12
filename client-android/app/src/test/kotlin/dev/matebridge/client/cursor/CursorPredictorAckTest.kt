package dev.matebridge.client.cursor

import dev.matebridge.client.protocol.CursorState
import dev.matebridge.client.protocol.PointerRel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random
import kotlin.math.hypot

/** T-345 (decision 0036 v3): the host's `rel_ack_count` tells exactly which deltas a state contains. */
class CursorPredictorAckTest {
    private companion object {
        const val W = 4000
        const val H = 2400
        const val OFFSET = 9_000_000L
    }

    /**
     * Client sends `POINTER_REL` at 120 Hz while moving right/down, the host applies them on arrival (TCP order), samples its
     * position every 8 ms and reports it with the number of messages applied. Delays: [baseOneWayMs] plus jitter in each
     * direction, plus now and then a [spikeMs] hiccup.
     */
    private class Sim(val baseOneWayMs: Int, val jitterMs: Int, val spikeMs: Int, val withAck: Boolean, seed: Long = 3) {
        val stats = CursorStats()
        private val rnd = Random(seed)
        val p = CursorPredictor({ h -> h - OFFSET }, { baseOneWayMs * 1000L }, stats)
        val out = CursorPredictor.Result()
        var hostX = 500f
        var hostY = 500f
        private var hostCount = 0L
        private var seq = 0L
        var lastSeq = 0L

        private class Rel(val atUs: Long, val dx: Float, val dy: Float)
        private class St(val atUs: Long, val sampleUs: Long, val x: Float, val y: Float, val seq: Long, val ack: Long)

        private val relQ = ArrayList<Rel>()
        private val stQ = ArrayList<St>()
        private var lastRelRx = 0L
        private var lastStRx = 0L
        private var nextRelUs = 0L
        private var nextStUs = 0L
        private var prevX = Float.NaN
        var maxBackPt = 0f

        private fun delayUs(): Long {
            var ms = baseOneWayMs + rnd.nextDouble() * jitterMs
            if (spikeMs > 0 && rnd.nextInt(60) == 0) ms += spikeMs
            return (ms * 1000).toLong()
        }

        init {
            p.setStream(W, H)
            p.setLayerOn(true)
            p.beginSession(1)
            p.onState(CursorState(0, (hostX / W * 65535).toInt(), (hostY / H * 65535).toInt(), true, 1, OFFSET, if (withAck) 0L else null), 0)
        }

        fun run(fromMs: Int, toMs: Int, moving: Boolean) {
            for (ms in fromMs until toMs) {
                val nowUs = ms * 1000L
                while (moving && nextRelUs <= nowUs) {
                    val dx = 2f
                    val dy = 0.5f
                    p.onSent(PointerRel(nextRelUs, dx, dy, 0), nextRelUs, 1)
                    lastRelRx = maxOf(lastRelRx, nextRelUs + delayUs())
                    relQ.add(Rel(lastRelRx, dx, dy))
                    nextRelUs += 1_000_000L / 120
                }
                if (!moving) nextRelUs = nowUs
                val ri = relQ.iterator()
                while (ri.hasNext()) {
                    val a = ri.next()
                    if (a.atUs <= nowUs) {
                        hostX += a.dx; hostY += a.dy; hostCount++
                        ri.remove()
                    }
                }
                while (nextStUs <= nowUs) {
                    seq++
                    lastStRx = maxOf(lastStRx, nextStUs + delayUs())
                    stQ.add(St(lastStRx, nextStUs, hostX, hostY, seq, hostCount))
                    nextStUs += 8_000
                }
                val si = stQ.iterator()
                while (si.hasNext()) {
                    val s = si.next()
                    if (s.atUs <= nowUs) {
                        p.onState(
                            CursorState(s.seq, (s.x / W * 65535).toInt(), (s.y / H * 65535).toInt(), true, 1, s.sampleUs + OFFSET,
                                if (withAck) s.ack else null),
                            s.atUs,
                        )
                        lastSeq = s.seq
                        si.remove()
                    }
                }
                if (ms % 7 == 0 && p.advance(lastSeq, nowUs, out)) {
                    val x = out.xNorm / 65535f * W
                    if (ms > 1_000 && moving && !prevX.isNaN()) maxBackPt = maxOf(maxBackPt, prevX - x)
                    prevX = x
                }
            }
        }
    }

    @Test fun withTheAckTheDrawnCursorNeverJumpsBackOnDelayJitter() {
        val sim = Sim(baseOneWayMs = 20, jitterMs = 60, spikeMs = 0, withAck = true) // RTT 40 ms, 40..100 ms jitter
        sim.run(0, 10_000, moving = true)
        val s = sim.stats.take()
        assertTrue("states measured ${s.predN}", s.predN > 500)
        assertTrue("snap back ${sim.maxBackPt} pt", sim.maxBackPt <= 1f)
        assertTrue("pred p95 ${s.predErrP95Pt}", s.predErrP95Pt <= 0.5f)
        assertTrue("hold p95 should be large: ${s.holdErrP95Pt}", s.holdErrP95Pt > 5f)
        assertTrue(s.fields().endsWith(" ack_n=${s.ackN}") && s.ackN > 500)
    }

    @Test fun aHomeWifiWithSpikesStaysStraight() {
        val sim = Sim(baseOneWayMs = 7, jitterMs = 4, spikeMs = 60, withAck = true) // about 15 ms plus a 60 ms hiccup
        sim.run(0, 10_000, moving = true)
        val s = sim.stats.take()
        assertTrue("snap back ${sim.maxBackPt} pt", sim.maxBackPt <= 1f)
        assertTrue("pred p95 ${s.predErrP95Pt}", s.predErrP95Pt <= 0.5f)
    }

    @Test fun withoutTheGroupTheOldBehaviourRemains() {
        val sim = Sim(baseOneWayMs = 20, jitterMs = 60, spikeMs = 0, withAck = false)
        sim.run(0, 5_000, moving = true)
        val s = sim.stats.take()
        assertEquals(0, s.ackN)
        assertTrue(!s.fields().contains("ack_n"))
    }

    private fun predictor(): CursorPredictor =
        CursorPredictor({ h -> h - OFFSET }, { 5_000L }, null).also { it.setStream(W, H); it.setLayerOn(true) }

    private fun seqOf(p: CursorPredictor, ack: Long?, t: Long = 1_000_000L): Pair<Float, Float> {
        p.onState(CursorState(1, 20000, 20000, true, 1, t + OFFSET - 20_000, ack), t)
        val out = CursorPredictor.Result()
        assertTrue(p.advance(1, t + 1_000, out))
        return out.xNorm / 65535f * W to out.yNorm / 65535f * H
    }

    @Test fun everyRelMessageIsNumberedIncludingButtonOnlyOnes() {
        val p = predictor()
        p.beginSession(1)
        p.onState(CursorState(0, 20000, 20000, true, 1, OFFSET, 0L), 900_000L)
        p.onSent(PointerRel(0, 10f, 0f, 0), 990_000L, 1) // 1
        p.onSent(PointerRel(0, 0f, 0f, 1), 991_000L, 1) // 2, button only
        p.onSent(PointerRel(0, 10f, 0f, 1), 992_000L, 1) // 3
        val base = 20000 / 65535f * W
        // ack 2: messages 1 and 2 are in the state, only message 3 (+10) is pending.
        assertEquals(base + 10f, seqOf(p, 2L).first, 0.2f)
        // ack 0: all pending.
        val q = predictor()
        q.beginSession(1)
        q.onState(CursorState(0, 20000, 20000, true, 1, OFFSET, 0L), 900_000L)
        q.onSent(PointerRel(0, 10f, 0f, 0), 990_000L, 1)
        q.onSent(PointerRel(0, 0f, 0f, 1), 991_000L, 1)
        q.onSent(PointerRel(0, 10f, 0f, 1), 992_000L, 1)
        assertEquals(base + 20f, seqOf(q, 0L).first, 0.2f)
    }

    @Test fun anOtherGenerationIsNotCountedAndANewSessionRestartsAtOne() {
        val p = predictor()
        p.beginSession(1)
        p.onState(CursorState(0, 20000, 20000, true, 1, OFFSET, 0L), 900_000L)
        p.onSent(PointerRel(0, 10f, 0f, 0), 990_000L, 7) // retired generation: ignored, no number
        p.onSent(PointerRel(0, 10f, 0f, 0), 991_000L, 1) // number 1
        val base = 20000 / 65535f * W
        assertEquals(base, seqOf(p, 1L).first, 0.2f) // ack 1 = the one counted message is in
        p.beginSession(2) // new connection: the host counts from 0 again
        p.onState(CursorState(0, 20000, 20000, true, 1, OFFSET, 0L), 1_900_000L)
        p.onSent(PointerRel(0, 10f, 0f, 0), 1_990_000L, 2) // number 1 again
        assertEquals(base + 10f, seqOf(p, 0L, 2_000_000L).first, 0.2f)
    }

    @Test fun layerToggleDoesNotRestartTheNumbering() {
        val p = predictor()
        p.beginSession(1)
        p.onSent(PointerRel(0, 10f, 0f, 0), 100_000L, 1) // 1 (no anchor: not kept, but numbered)
        p.setLayerOn(false)
        p.setLayerOn(true)
        p.onState(CursorState(0, 20000, 20000, true, 1, OFFSET, 1L), 900_000L)
        p.onSent(PointerRel(0, 10f, 0f, 0), 990_000L, 1) // 2
        val base = 20000 / 65535f * W
        assertEquals(base + 10f, seqOf(p, 1L).first, 0.2f) // ack 1: only number 2 is pending
    }

    @Test fun aStallHoldsTheDisplacedPositionAndStopsAskingForFrames() {
        val p = predictor()
        p.beginSession(1)
        p.onState(CursorState(0, 20000, 20000, true, 1, OFFSET, 0L), 900_000L)
        p.onSent(PointerRel(0, 10f, 0f, 0), 950_000L, 1) // 1
        p.onState(CursorState(1, 20000, 20000, true, 1, OFFSET + 40_000, 1L), 960_000L)
        p.onSent(PointerRel(0, 20f, 0f, 0), 970_000L, 1) // 2, then motion stops and delivery stalls
        val base = 20000 / 65535f * W
        val out = CursorPredictor.Result()
        assertTrue(p.advance(1, 971_000L, out))
        assertTrue(out.animating) // the first frame with the new delta
        var animating = true
        for (t in 980_000L..3_000_000L step 100_000L) { // far beyond the keep time, no state arrives
            assertTrue(p.advance(1, t, out))
            assertEquals(base + 20f, out.xNorm / 65535f * W, 0.2f)
            animating = out.animating
        }
        assertTrue("still animating during the stall", !animating)
        // Delivery resumes with ack 2: the state contains the delta, nothing jumps.
        p.onState(CursorState(2, (20000 + 20 / W.toFloat() * 65535).toInt(), 20000, true, 1, OFFSET + 3_000_000L, 2L), 3_010_000L)
        assertTrue(p.advance(2, 3_011_000L, out))
        assertEquals(base + 20f, out.xNorm / 65535f * W, 0.3f)
    }
}
