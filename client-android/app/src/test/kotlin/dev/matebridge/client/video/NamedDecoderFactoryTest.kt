package dev.matebridge.client.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-388: `decoder=<name>` selection and fallback with fake factories. */
class NamedDecoderFactoryTest {
    private val mime = "video/hevc"
    private val logs = ArrayList<String>()
    private val log: (Char, String, String) -> Unit = { l, ev, f -> logs.add("$l $ev $f") }

    @Test fun namedCodecIsUsedAndLogged() {
        val fallback = FakeDecoderFactory()
        val named = FakeDecoderFactory()
        var asked: Pair<String, String>? = null
        val f = NamedDecoderFactory("c2.mtk.hevc.decoder.lowlatency", { n, m -> asked = n to m; named.create(m) }, fallback, log)
        val c = f.create(mime)
        assertSame(named.codecs[0], c)
        assertEquals("c2.mtk.hevc.decoder.lowlatency" to mime, asked)
        assertEquals(0, fallback.createCalls)
        assertEquals(1, logs.size)
        assertTrue(logs[0], logs[0].startsWith("I decoder_select requested=c2.mtk.hevc.decoder.lowlatency name="))
    }

    @Test fun unsupportedMimeFallsBackAndSaysWhy() {
        val fallback = FakeDecoderFactory()
        val f = NamedDecoderFactory("c2.mtk.avc.decoder", { _, _ -> throw NamedDecoderFactory.Unsupported("x") }, fallback, log)
        val c = f.create(mime)
        assertSame(fallback.codecs[0], c)
        assertEquals(1, fallback.createCalls)
        assertEquals(listOf("W decoder_fallback requested=c2.mtk.avc.decoder mime=video/hevc reason=mime_unsupported err=Unsupported"), logs)
    }

    @Test fun createFailureFallsBackAndSaysWhy() {
        val fallback = FakeDecoderFactory()
        val f = NamedDecoderFactory("nope", { _, _ -> throw IllegalArgumentException("unknown") }, fallback, log)
        f.create(mime)
        assertEquals(1, fallback.createCalls)
        assertEquals(listOf("W decoder_fallback requested=nope mime=video/hevc reason=create_failed err=IllegalArgumentException"), logs)
    }

    @Test fun fallbackFailureStillPropagates() {
        val fallback = FakeDecoderFactory().also { it.failCreates = 1 }
        val f = NamedDecoderFactory("nope", { _, _ -> throw java.io.IOException() }, fallback, log)
        try { f.create(mime); org.junit.Assert.fail() } catch (_: java.io.IOException) {}
    }

    @Test fun absentKnobKeepsTheDefaultFactory() {
        assertEquals(null, NamedDecoderFactory.forKnob(null, FakeDecoderFactory(), log))
    }
}
