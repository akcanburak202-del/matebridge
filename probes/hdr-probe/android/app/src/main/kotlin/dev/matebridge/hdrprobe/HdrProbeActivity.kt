package dev.matebridge.hdrprobe

import android.app.Activity
import android.graphics.Color
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import java.io.File
import java.nio.ByteBuffer

/**
 * T-226: decodes an HDR10 / HLG HEVC Main10 clip (made by the Mac probe: `hdr-probe encode --out ...`) into a
 * SurfaceView the same way MateBridge's client does (MediaCodec -> Surface), with an SDR UI overlay on top
 * (white text and a white patch) to compare SDR white with the clip's 203-nit patch.
 *
 * What it answers: does the HiSilicon decoder take Main10 PQ/HLG, what output format does it report, and does
 * HarmonyOS 4.3 put the display into HDR mode for a third-party SurfaceView (read `dumpsys SurfaceFlinger` while
 * it runs: mIsHdrLayerPresent, layer dataspace BT2020_PQ / BT2020_HLG, format P010 vs NV12).
 *
 * Extras: clip=<file in getExternalFilesDir> (default hdr.mp4); static_info=false skips KEY_HDR_STATIC_INFO;
 * tags=explicit also sets KEY_COLOR_STANDARD/TRANSFER/RANGE (default: leave them to the bitstream VUI).
 * Logs: tag MBHDR. Everything stops in onPause; nothing runs in the background.
 */
class HdrProbeActivity : Activity(), SurfaceHolder.Callback {

    private lateinit var status: TextView
    private val lines = ArrayList<String>()
    @Volatile private var running = false
    private var worker: Thread? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val root = FrameLayout(this)
        val surface = SurfaceView(this)
        surface.holder.addCallback(this)
        root.addView(surface, FrameLayout.LayoutParams(-1, -1))

        val overlay = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 24, 24, 24)
        }
        status = TextView(this).apply {
            setTextColor(Color.WHITE)
            setBackgroundColor(0x99000000.toInt())
            textSize = 14f
        }
        overlay.addView(status)
        // SDR white reference patch (UI layer, sRGB 255).
        overlay.addView(View(this).apply { setBackgroundColor(Color.WHITE) }, LinearLayout.LayoutParams(240, 240))
        root.addView(overlay, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.END))
        setContentView(root)
    }

    private fun log(s: String) {
        Log.i(TAG, s)
        runOnUiThread {
            lines.add(s)
            while (lines.size > 18) lines.removeAt(0)
            status.text = lines.joinToString("\n")
        }
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        val d = display
        if (d != null) {
            val caps = d.hdrCapabilities
            log("display isHdr=${d.isHdr} wideColor=${d.isWideColorGamut} hdrTypes=${caps?.supportedHdrTypes?.joinToString()} " +
                "maxLum=${caps?.desiredMaxLuminance} maxAvg=${caps?.desiredMaxAverageLuminance} minLum=${caps?.desiredMinLuminance}")
        }
        running = true
        worker = Thread({ decodeLoop(holder) }, "hdr-probe-decode").also { it.start() }
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

    override fun surfaceDestroyed(holder: SurfaceHolder) = stop()

    override fun onPause() {
        super.onPause()
        stop()
    }

    private fun stop() {
        running = false
        worker?.join(2000)
        worker = null
    }

    private fun decodeLoop(holder: SurfaceHolder) {
        val name = intent.getStringExtra("clip") ?: "hdr.mp4"
        val file = File(getExternalFilesDir(null), name)
        if (!file.exists()) { log("missing ${file.path} (adb push it first)"); return }
        val ex = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            ex.setDataSource(file.path)
            val track = (0 until ex.trackCount).first { ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)!!.startsWith("video/") }
            ex.selectTrack(track)
            val fmt = ex.getTrackFormat(track)
            log("clip $name: ${describe(fmt)}")

            if (intent.getBooleanExtra("static_info", true) && !fmt.containsKey(MediaFormat.KEY_HDR_STATIC_INFO)) {
                fmt.setByteBuffer(MediaFormat.KEY_HDR_STATIC_INFO, ByteBuffer.wrap(HdrStaticInfo.encode(HdrStaticInfo.P3_D65_1000)))
                log("set KEY_HDR_STATIC_INFO (P3 D65, 1000 nit, MaxCLL 1000, MaxFALL 400)")
            }
            if (intent.getStringExtra("tags") == "explicit") {
                fmt.setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT2020)
                fmt.setInteger(MediaFormat.KEY_COLOR_TRANSFER,
                    if (name.contains("hlg")) MediaFormat.COLOR_TRANSFER_HLG else MediaFormat.COLOR_TRANSFER_ST2084)
                fmt.setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
                log("set explicit colour keys")
            }

            val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
            val decoderName = list.findDecoderForFormat(fmt)
            log("findDecoderForFormat=$decoderName")
            val mime = fmt.getString(MediaFormat.KEY_MIME)!!
            codec = if (decoderName != null) MediaCodec.createByCodecName(decoderName) else MediaCodec.createDecoderByType(mime)
            val caps = codec.codecInfo.getCapabilitiesForType(mime)
            val main10Hdr10 = caps.profileLevels.any { it.profile == MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10 }
            log("decoder=${codec.name} advertises Main10HDR10=$main10Hdr10")
            codec.configure(fmt, holder.surface, null, 0)
            codec.start()
            pump(ex, codec)
        } catch (t: Throwable) {
            log("error: $t")
        } finally {
            try { codec?.stop() } catch (_: Throwable) {}
            codec?.release()
            ex.release()
            log("stopped")
        }
    }

    private fun pump(ex: MediaExtractor, codec: MediaCodec) {
        val info = MediaCodec.BufferInfo()
        var startNs = -1L
        var basePtsUs = -1L
        var frames = 0
        while (running) {
            val inIdx = codec.dequeueInputBuffer(5_000)
            if (inIdx >= 0) {
                val buf = codec.getInputBuffer(inIdx)!!
                val n = ex.readSampleData(buf, 0)
                if (n < 0) {
                    // Loop the clip: flush and restart timing.
                    codec.queueInputBuffer(inIdx, 0, 0, 0, 0)
                    ex.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                    codec.flush()
                    startNs = -1L; basePtsUs = -1L
                    continue
                }
                codec.queueInputBuffer(inIdx, 0, n, ex.sampleTime, 0)
                ex.advance()
            }
            val outIdx = codec.dequeueOutputBuffer(info, 5_000)
            when {
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> log("output format: ${describe(codec.outputFormat)}")
                outIdx >= 0 -> {
                    if (startNs < 0) { startNs = System.nanoTime(); basePtsUs = info.presentationTimeUs }
                    val due = startNs + (info.presentationTimeUs - basePtsUs) * 1000
                    val wait = due - System.nanoTime()
                    if (wait > 0) Thread.sleep(wait / 1_000_000, (wait % 1_000_000).toInt())
                    codec.releaseOutputBuffer(outIdx, true)
                    frames++
                    if (frames % 600 == 0) log("rendered $frames frames")
                }
            }
        }
    }

    private fun describe(f: MediaFormat): String {
        fun int(k: String) = if (f.containsKey(k)) f.getInteger(k).toString() else "-"
        val profile = if (f.containsKey(MediaFormat.KEY_PROFILE)) f.getInteger(MediaFormat.KEY_PROFILE).toString() else "-"
        val w = if (f.containsKey(MediaFormat.KEY_WIDTH)) f.getInteger(MediaFormat.KEY_WIDTH) else -1
        val h = if (f.containsKey(MediaFormat.KEY_HEIGHT)) f.getInteger(MediaFormat.KEY_HEIGHT) else -1
        return "${f.getString(MediaFormat.KEY_MIME)} ${w}x$h profile=$profile " +
            "standard=${int(MediaFormat.KEY_COLOR_STANDARD)} transfer=${int(MediaFormat.KEY_COLOR_TRANSFER)} " +
            "range=${int(MediaFormat.KEY_COLOR_RANGE)} colorFormat=${int(MediaFormat.KEY_COLOR_FORMAT)} " +
            "hdrStaticInfo=${f.containsKey(MediaFormat.KEY_HDR_STATIC_INFO)}"
    }

    companion object { const val TAG = "MBHDR" }
}
