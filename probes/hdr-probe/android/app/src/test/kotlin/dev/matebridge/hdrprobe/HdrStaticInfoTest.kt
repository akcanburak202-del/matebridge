package dev.matebridge.hdrprobe

import org.junit.Assert.assertEquals
import org.junit.Test

class HdrStaticInfoTest {
    @Test fun layoutIs25BytesLittleEndian() {
        val b = HdrStaticInfo.encode(HdrStaticInfo.P3_D65_1000)
        assertEquals(25, b.size)
        assertEquals(0, b[0].toInt())
        // R.x = 0.680 / 0.00002 = 34000 = 0x84D0 -> D0 84
        assertEquals(0xD0, b[1].toInt() and 0xff)
        assertEquals(0x84, b[2].toInt() and 0xff)
        // max mastering luminance 1000 = 0x03E8 at bytes 17..18
        assertEquals(0xE8, b[17].toInt() and 0xff)
        assertEquals(0x03, b[18].toInt() and 0xff)
        // min 0.0001 cd/m² = 1
        assertEquals(1, b[19].toInt() and 0xff)
        // MaxFALL 400 = 0x0190 at bytes 23..24
        assertEquals(0x90, b[23].toInt() and 0xff)
        assertEquals(0x01, b[24].toInt() and 0xff)
    }
}
