package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.VideoFrame
import java.io.ByteArrayOutputStream

/**
 * Splits an Annex-B HEVC stream (T-011 dump) into VIDEO_FRAME-shaped units: parameter sets
 * (VPS/SPS/PPS) become CODEC_CONFIG frames, each picture becomes one frame (KEYFRAME for IRAP).
 * HEVC only. A new picture starts at a VCL NAL with first_slice_segment_in_pic_flag set.
 */
object AnnexBSplitter {
    private const val VPS = 32
    private const val PPS = 34
    private val START = byteArrayOf(0, 0, 0, 1)

    fun split(data: ByteArray, captureIntervalUs: Long = 16_667): List<VideoFrame> {
        val out = ArrayList<VideoFrame>()
        var seq = 0L
        val cfg = ByteArrayOutputStream()
        val cur = ByteArrayOutputStream()
        var curHasVcl = false
        var curKey = false

        fun emit(buf: ByteArrayOutputStream, flags: Int) {
            if (buf.size() == 0) return
            val bytes = buf.toByteArray()
            buf.reset()
            out += VideoFrame(seq, seq * captureIntervalUs, flags, 0, 1, bytes.size.toLong(), Bytes(bytes))
            seq++
        }
        fun flushPicture() {
            if (curHasVcl) emit(cur, if (curKey) VideoFrame.KEYFRAME else 0)
            curHasVcl = false
            curKey = false
        }

        for ((start, end) in nalRanges(data)) {
            if (end - start < 2) continue
            val type = (data[start].toInt() shr 1) and 0x3f
            when {
                type in VPS..PPS -> {
                    flushPicture()
                    cfg.write(START); cfg.write(data, start, end - start)
                }
                type < 32 -> {
                    val first = end - start > 2 && (data[start + 2].toInt() and 0x80) != 0
                    if (first) flushPicture()
                    emit(cfg, VideoFrame.CODEC_CONFIG)
                    cur.write(START); cur.write(data, start, end - start)
                    curHasVcl = true
                    if (type in 16..21) curKey = true
                }
                else -> { // AUD, SEI, ...: belongs to the picture that follows
                    flushPicture()
                    cur.write(START); cur.write(data, start, end - start)
                }
            }
        }
        flushPicture()
        emit(cfg, VideoFrame.CODEC_CONFIG)
        return out
    }

    /** NAL payload ranges [start, end) excluding start codes and trailing zero bytes. */
    internal fun nalRanges(d: ByteArray): List<Pair<Int, Int>> {
        val starts = ArrayList<Int>() // index of first byte after a start code
        var i = 0
        while (i + 2 < d.size) {
            if (d[i].toInt() == 0 && d[i + 1].toInt() == 0 && d[i + 2].toInt() == 1) {
                starts += i + 3
                i += 3
            } else i++
        }
        return starts.mapIndexed { n, s ->
            var e = if (n + 1 < starts.size) starts[n + 1] - 3 else d.size
            while (e > s && d[e - 1].toInt() == 0) e--
            s to e
        }
    }
}
