package dev.matebridge.client.clipboard

import dev.matebridge.client.session.Latest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

// The remote-write mailbox is a Latest slot: a flood keeps one value (O(1) memory), the newest wins.
class LatestMailboxTest {
    @Test fun floodKeepsOnlyNewest() {
        val m = Latest<Int>()
        for (i in 1..100_000) m.post(i)
        assertEquals(100_000, m.take())
        assertNull(m.take())
    }
}
