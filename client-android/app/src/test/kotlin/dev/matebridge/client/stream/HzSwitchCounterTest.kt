package dev.matebridge.client.stream

import org.junit.Assert.assertEquals
import org.junit.Test

class HzSwitchCounterTest {
    @Test fun switchCounterCountsChangesPerWindow() {
        val c = HzSwitchCounter()
        c.observe(60) // first report of a run is not a switch
        assertEquals(0, c.take())
        c.observe(120)
        c.observe(60)
        c.observe(60)
        c.observe(0) // unknown ignored
        assertEquals(2, c.take())
        assertEquals(0, c.take())
        c.observe(120) // the last rate survives the window
        assertEquals(1, c.take())
        c.restart()
        c.observe(60)
        assertEquals(0, c.take())
    }
}
