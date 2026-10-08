package dev.matebridge.client.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class QuickAckTest {
    @Test fun rearmsAfterEveryRead() {
        var n = 0
        val q = QuickAck(true, { n++ })
        repeat(3) { q.afterRead() }
        assertEquals(3, n)
    }

    @Test fun disabledNeverCalls() {
        var n = 0
        QuickAck(false, { n++ }).afterRead()
        assertEquals(0, n)
    }

    @Test fun failureLoggedOnceThenDisabled() {
        var calls = 0
        val fails = mutableListOf<String>()
        val q = QuickAck(true, { calls++; throw IllegalStateException("x") }) { fails.add(it) }
        repeat(4) { q.afterRead() }
        assertEquals(1, calls)
        assertEquals(listOf("IllegalStateException"), fails)
    }
}
