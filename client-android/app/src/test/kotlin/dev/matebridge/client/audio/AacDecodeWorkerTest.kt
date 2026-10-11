package dev.matebridge.client.audio

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-341: the AAC decode thread's contract, driven with a fake decoder (no MediaCodec). */
class AacDecodeWorkerTest {
    private class Fake(private val outputFrames: IntArray = intArrayOf(1024), private val failOnInput: Int = -1) : AacCodecPort {
        var csd: ByteArray? = null
        val released = AtomicInteger()
        private val ready = ArrayDeque<AacCodecPort.Output>()
        private var inputs = 0

        override fun start(csd0: ByteArray) { csd = csd0 }

        override fun queueInput(data: ByteArray, ptsUs: Long, timeoutUs: Long): Boolean {
            inputs++
            if (inputs == failOnInput) throw IllegalStateException("boom")
            for (f in outputFrames) ready.addLast(AacCodecPort.Output(ByteArray(f * 4), f * 4, ptsUs))
            return true
        }

        override fun pollOutput(timeoutUs: Long) = ready.removeFirstOrNull()

        override fun release() { released.incrementAndGet() }
    }

    private data class Written(val idx: Long, val cap: Long, val frames: Int)

    private fun unit(i: Int) = AacUnit(i * 1024L + 100_000, 1_000_000L + i * 21_333L, ByteArray(200))

    private fun run(fake: Fake, units: Int, writes: Int = units, errors: MutableList<String> = mutableListOf()): Pair<List<Written>, AacDecodeWorker> {
        val q = AacUnitQueue()
        val out = java.util.Collections.synchronizedList(mutableListOf<Written>())
        val done = CountDownLatch(writes)
        val w = AacDecodeWorker(q, { fake }, { idx, cap, _, frames -> out += Written(idx, cap, frames); done.countDown() }, { errors += it })
        val t = Thread { w.runLoop() }.also { it.start() }
        for (i in 0 until units) q.offer(unit(i))
        assertTrue(done.await(3, TimeUnit.SECONDS))
        w.stop()
        t.join(2000)
        assertFalse(t.isAlive)
        return out.toList() to w
    }

    @Test fun configuresWithTheAudioSpecificConfigAndKeepsIndexAndCaptureTimePerUnit() {
        val fake = Fake()
        val (out, w) = run(fake, 3)
        assertEquals(listOf<Byte>(0x11, 0x90.toByte()), fake.csd!!.toList())
        assertEquals(listOf(Written(100_000, 1_000_000, 1024), Written(101_024, 1_021_333, 1024), Written(102_048, 1_042_666, 1024)), out)
        assertEquals(3, w.decodedUnits.toInt())
        assertEquals(1, fake.released.get()) // released when the thread ends
    }

    @Test fun aUnitThatYieldsSeveralOutputsAdvancesIndexAndTimeByTheFramesAlreadyHandedOn() {
        val (out, _) = run(Fake(outputFrames = intArrayOf(512, 512)), 1, writes = 2)
        assertEquals(Written(100_000, 1_000_000, 512), out[0])
        assertEquals(Written(100_512, 1_000_000 + 512 * 1_000_000L / 48_000, 512), out[1])
    }

    @Test fun aDecoderErrorIsReportedOnceAndTheDecoderIsReleased() {
        val fake = Fake(failOnInput = 2)
        val errors = mutableListOf<String>()
        val q = AacUnitQueue()
        val w = AacDecodeWorker(q, { fake }, { _, _, _, _ -> }, { errors += it })
        val t = Thread { w.runLoop() }.also { it.start() }
        for (i in 0 until 5) q.offer(unit(i))
        t.join(3000)
        assertFalse(t.isAlive)
        assertEquals(listOf("IllegalStateException"), errors)
        assertTrue(w.failed)
        assertEquals(1, fake.released.get())
        assertFalse(q.offer(unit(9))) // nothing is accepted any more
    }

    @Test fun aFailingStartIsContainedToo() {
        val errors = mutableListOf<String>()
        val w = AacDecodeWorker(AacUnitQueue(), { throw java.io.IOException("no codec") }, { _, _, _, _ -> }, { errors += it })
        w.runLoop()
        assertEquals(listOf("IOException"), errors)
    }

    @Test fun stopEndsAnIdleWorkerQuicklyAndReleases() {
        val fake = Fake()
        val q = AacUnitQueue()
        val w = AacDecodeWorker(q, { fake }, { _, _, _, _ -> }, {})
        val t = Thread { w.runLoop() }.also { it.start() }
        Thread.sleep(50)
        val t0 = System.nanoTime()
        w.stop()
        t.join(2000)
        assertFalse(t.isAlive)
        assertTrue((System.nanoTime() - t0) / 1_000_000 < 500)
        assertEquals(1, fake.released.get())
    }
}
