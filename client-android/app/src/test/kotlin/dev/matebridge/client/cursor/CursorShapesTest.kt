package dev.matebridge.client.cursor

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.CursorShape
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.RejectedExecutionException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class CursorShapesTest {
    /** A header-only PNG prefix with the given size: enough for [PngInfo]; the fake decoder never reads pixels. */
    private fun png(w: Int, h: Int): ByteArray {
        fun be(v: Int) = byteArrayOf((v ushr 24).toByte(), (v ushr 16).toByte(), (v ushr 8).toByte(), v.toByte())
        return byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) + be(13) + "IHDR".toByteArray() + be(w) + be(h) +
            ByteArray(9)
    }

    private fun shape(id: Long, data: ByteArray = png(18, 36), format: Int = CursorShape.FORMAT_PNG) =
        CursorShape(id, 144, 288, 64, 144, format, Bytes(data))

    private class Rig(val executor: Executor = Executor { it.run() }, val decodeResult: (ByteArray) -> String? = { "bmp" }) {
        var ready = 0
        val decodes = ArrayList<ByteArray>()
        val shapes = CursorShapes<String>(
            executor = executor,
            decode = { decodes += it; decodeResult(it) },
            onReady = { ready++ },
        )
    }

    @Test fun pngDimensionsAreReadFromTheHeader() {
        assertEquals(18 to 36, PngInfo.dimensions(png(18, 36)))
        assertNull(PngInfo.dimensions(ByteArray(10)))
        assertNull(PngInfo.dimensions(png(18, 36).also { it[0] = 0 })) // signature
        assertNull(PngInfo.dimensions(png(18, 36).also { it[13] = 'X'.code.toByte() })) // not IHDR
        assertNull(PngInfo.dimensions(png(0, 36)))
        assertNull(PngInfo.dimensions(png(-1, 36))) // 0xFFFFFFFF
    }

    @Test fun theRealFixtureHeaderParses() {
        val hex = File(System.getProperty("matebridge.fixtures") ?: "../../protocol/fixtures", "cursor_shape.hex")
        val bytes = hex.readLines().map { it.substringBefore('#').trim() }.filter { it.isNotEmpty() }
            .flatMap { it.split(Regex("\\s+")) }.map { it.toInt(16).toByte() }.toByteArray()
        val data = bytes.copyOfRange(5 + 16, bytes.size) // frame header + fixed fields
        assertEquals(18 to 36, PngInfo.dimensions(data))
    }

    @Test fun aPngIsDecodedInTheBackgroundAndBecomesReady() {
        val queued = ArrayList<Runnable>()
        val rig = Rig(executor = { queued += it })
        rig.shapes.onShape(shape(7))
        val e = rig.shapes.lookup(7)!!
        assertEquals(ShapeStatus.PENDING, e.status) // nothing decoded on the caller's thread
        assertNull(e.bitmap)
        assertEquals(0, rig.decodes.size)
        queued.single().run()
        assertEquals(ShapeStatus.READY, e.status)
        assertEquals("bmp", e.bitmap)
        assertEquals(1, rig.ready)
        assertEquals(144, e.widthPt16)
        assertEquals(64, e.hotXPt16)
    }

    @Test fun unknownFormatKeepsItsIdAndDrawsTheArrow() {
        val rig = Rig()
        rig.shapes.onShape(shape(7, format = 9))
        assertEquals(ShapeStatus.FALLBACK, rig.shapes.lookup(7)!!.status)
        assertEquals(0, rig.decodes.size)
    }

    @Test fun anOversizedOrBrokenPngIsRefusedBeforeDecoding() {
        val rig = Rig()
        rig.shapes.onShape(shape(1, png(257, 10)))
        rig.shapes.onShape(shape(2, png(10, 100_000)))
        rig.shapes.onShape(shape(3, ByteArray(40)))
        for (id in 1L..3L) assertEquals(ShapeStatus.FALLBACK, rig.shapes.lookup(id)!!.status)
        assertEquals(0, rig.decodes.size)
        rig.shapes.onShape(shape(4, png(256, 256)))
        assertEquals(ShapeStatus.READY, rig.shapes.lookup(4)!!.status)
    }

    @Test fun aFailedOrThrowingDecoderFallsBackToTheArrow() {
        val nullRig = Rig(decodeResult = { null })
        nullRig.shapes.onShape(shape(1))
        assertEquals(ShapeStatus.FALLBACK, nullRig.shapes.lookup(1)!!.status)
        val throwing = Rig(decodeResult = { throw IllegalStateException("boom") })
        throwing.shapes.onShape(shape(1))
        assertEquals(ShapeStatus.FALLBACK, throwing.shapes.lookup(1)!!.status)
        assertEquals(2, nullRig.ready + throwing.ready) // a redraw is still due: the pending shape becomes the arrow
    }

    @Test fun aFullBackgroundQueueNeverBlocksAndFallsBack() {
        val rig = Rig(executor = { throw RejectedExecutionException("full") })
        rig.shapes.onShape(shape(1))
        assertEquals(ShapeStatus.FALLBACK, rig.shapes.lookup(1)!!.status)
    }

    @Test fun shapeIdZeroIsIgnored() {
        val rig = Rig()
        rig.shapes.onShape(shape(0))
        assertEquals(0, rig.shapes.size)
    }

    @Test fun holdsAtLeast64ShapesAndEvictsTheLeastRecentlyUsed() {
        val rig = Rig()
        for (id in 1L..64L) rig.shapes.onShape(shape(id))
        assertEquals(64, rig.shapes.size)
        for (id in 1L..64L) assertNotNull("shape $id", rig.shapes.lookup(id))
        rig.shapes.use(1) // a state that names it counts as a use
        rig.shapes.onShape(shape(65))
        assertEquals(64, rig.shapes.size)
        assertNotNull(rig.shapes.lookup(1))
        assertNull(rig.shapes.lookup(2)) // the oldest unused one went
        assertNotNull(rig.shapes.lookup(65))
    }

    @Test fun lookupDoesNotCountAsUseButUseDoes() {
        val c = ShapeCache<String>(2)
        c.put(1, "a"); c.put(2, "b")
        c.peek(1) // not a use
        c.put(3, "c")
        assertNull(c.peek(1))
        c.put(1, "a"); // evicts 2 (3 is newer)
        c.touch(3)
        c.put(4, "d")
        assertEquals("c", c.peek(3))
        assertNull(c.peek(1))
    }

    @Test fun aDecodeThatFinishesAfterTheSessionWasClearedIsDropped() {
        val queued = ArrayList<Runnable>()
        val rig = Rig(executor = { queued += it })
        rig.shapes.onShape(shape(7))
        val e = rig.shapes.lookup(7)!!
        rig.shapes.clear() // session end
        queued.single().run()
        assertEquals(ShapeStatus.PENDING, e.status)
        assertNull(e.bitmap)
        assertEquals(0, rig.ready)
        assertNull(rig.shapes.lookup(7))
    }

    @Test fun aResentIdReplacesTheOldEntry() {
        val rig = Rig()
        rig.shapes.onShape(shape(7))
        val first = rig.shapes.lookup(7)!!
        rig.shapes.onShape(shape(7, png(20, 40)))
        assertTrue(first !== rig.shapes.lookup(7))
        assertSame(rig.shapes.lookup(7), rig.shapes.use(7))
    }
}
