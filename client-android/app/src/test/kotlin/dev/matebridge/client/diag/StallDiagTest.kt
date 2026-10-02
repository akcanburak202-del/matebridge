package dev.matebridge.client.diag

import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class StallDiagTest {
    private val readers = object : StallDetector.Readers {
        override fun lastControlReadNs() = 0L
        override fun lastVideoReadNs() = 0L
    }

    @Test fun offCreatesNoDetector() = assertNull(StallDiag.create(false, readers))

    @Test fun onCreatesDetector() = assertNotNull(StallDiag.create(true, readers))
}
