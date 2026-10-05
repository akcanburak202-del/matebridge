package dev.matebridge.client.video

import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FullChromaSupportTest {
    @Test fun planeCopyRemovesRowPadding() {
        // 3x2 plane in a buffer with row stride 5
        val raw = byteArrayOf(1, 2, 3, 9, 9, 4, 5, 6, 9, 9)
        assertEquals(listOf<Byte>(1, 2, 3, 4, 5, 6), PlaneCopy.tight(ByteBuffer.wrap(raw), 5, 1, 3, 2).toList())
    }

    @Test fun planeCopyHandlesInterleavedChroma() {
        // NV12-like chroma viewed as one plane: pixel stride 2
        val raw = byteArrayOf(1, 100, 2, 101, 3, 102, 4, 103)
        assertEquals(listOf<Byte>(1, 2, 3, 4), PlaneCopy.tight(ByteBuffer.wrap(raw), 4, 2, 2, 2).toList())
    }

    @Test fun planeCopyDoesNotDisturbTheSourcePosition() {
        val b = ByteBuffer.wrap(ByteArray(8) { it.toByte() })
        b.position(3)
        PlaneCopy.tight(b, 4, 1, 4, 2)
        assertEquals(3, b.position())
    }

    @Test fun rawVerdictReadsTheNativeLine() {
        assertEquals(true, RawVerdict.exact("ok=1 exact=1 flip=1 ahb_fmt=0x23"))
        assertEquals(false, RawVerdict.exact("ok=1 exact=0 flip=0 y_mis=3/100"))
        assertNull(RawVerdict.exact("ok=0 err=no_ahb"))
        assertNull(RawVerdict.exact("ok=1 flip=0")) // no verdict field
    }

    @Test fun selfTestClipIsOneIntraFrameWithParameterSets() {
        val frames = AnnexBSplitter.split(FullChromaSelfTestClip.data)
        assertEquals(1, frames.count { it.isCodecConfig })
        assertEquals(1, frames.count { it.isKeyframe })
        assertTrue(frames.size == 2)
        assertTrue(FullChromaSelfTestClip.data.size in 1_000..20_000)
        assertNotNull(frames.first { it.isCodecConfig })
    }

    @Test fun statsFieldsOfTheDirectPathAreDashes() {
        val f = FullChromaStatsFormat.fields(0, null)
        assertEquals("chroma_layout=0 aux_paired_pct=- aux_late=- gl_ms_p50=- gl_ms_p95=-", f)
    }

    @Test fun statsFieldsOfThePackedPath() {
        val snap = PackedPresenter.Snapshot(
            drawn = 60, mainOnly = 3, paired = 57, displaced = 1, drawErrors = 0, glMsP50 = 2.94, glMsP95 = 4.5, outstandingMax = 2,
        )
        val f = FullChromaStatsFormat.fields(1, snap, auxDropped = 4, auxKfRequests = 1, auxRestarts = 0, auxDead = false)
        assertTrue(f, f.startsWith("chroma_layout=1 aux_paired_pct=95.0 aux_late=3 gl_ms_p50=2.94 gl_ms_p95=4.50"))
        assertTrue(f, f.contains("gl_drawn=60 gl_displaced=1 gl_errors=0 gl_outstanding_max=2 aux_drop=4 aux_kf_req=1 aux_restarts=0 aux_dead=0"))
        assertFalse(f.contains("  "))
    }

    @Test fun pairedPercentIsNullWithoutFrames() {
        val s = PackedPresenter.Snapshot(0, 0, 0, 0, 0, null, null, 0)
        assertNull(s.pairedPct)
    }
}
