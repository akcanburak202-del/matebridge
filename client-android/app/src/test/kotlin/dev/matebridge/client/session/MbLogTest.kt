package dev.matebridge.client.session

import org.junit.Assert.assertEquals
import org.junit.Test

class MbLogTest {
    @Test fun formatsLine() {
        assertEquals(
            "1234 I session sid=7 gen=2 ev=connect_ok host=10.0.0.5 port=7420",
            MbLog.format(1234, 'I', "session", 7, 2, "connect_ok", "host=10.0.0.5 port=7420"),
        )
        assertEquals("5 W session sid=0 gen=0 ev=x", MbLog.format(5, 'W', "session", 0, 0, "x", ""))
    }
}
