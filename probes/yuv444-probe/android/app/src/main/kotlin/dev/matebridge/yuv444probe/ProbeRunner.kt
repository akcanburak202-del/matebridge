package dev.matebridge.yuv444probe

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.Image
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.view.Surface
import java.io.File
import java.util.Locale
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** What the activity offers the runner: a surface of an exact size, a refresh-rate request and the live refresh rate. */
interface Host {
    /** The SurfaceView's Surface sized to w x h (buffer geometry), or null if it could not be obtained. */
    fun surfaceFor(w: Int, h: Int): Surface?
    fun requestPanel(hz: Int): String
    fun refreshRate(): Float
    fun setStatus(text: String)
}

/**
 * Runs the tests of the 4:4:4 packing gates (research 2026-10-05 section 7). Every result line starts with
 * `Y444PROBE <test>`; the activity also appends it to `files/y444-results.txt`.
 */
class ProbeRunner(
    private val ctx: Context,
    private val dir: File,
    private val args: Args,
    private val host: Host,
    private val log: (String) -> Unit,
    private val running: () -> Boolean,
) {
    private val fileNames: List<String> = dir.list()?.toList() ?: emptyList()

    fun runAll() {
        val (kinds, bad) = args.tests
        if (bad.isNotEmpty()) log("Y444PROBE info ignored tests: $bad")
        log("Y444PROBE info device=${Build.MODEL} sdk=${Build.VERSION.SDK_INT} tests=${kinds.joinToString(",") { it.key }} " +
            "size=${args.size} fps=${args.fps} panel=${args.panel} gl=${args.gl?.key} warmup=${args.warmup} " +
            "clips=${fileNames.mapNotNull { ClipName.parse(it)?.fileName }}")
        for (k in kinds) {
            if (!running()) break
            try {
                when (k) {
                    TestKind.T2 -> runT2()
                    TestKind.T1 -> runT1()
                    TestKind.DIRECT -> runDirect()
                    TestKind.T3 -> runT3(long = false)
                    TestKind.T4 -> runT3(long = true)
                }
            } catch (t: Throwable) {
                log("Y444PROBE ${k.key} EXCEPTION ${t.javaClass.simpleName}:${t.message}")
            }
            pauseMs(1500)
        }
        log(if (running()) "Y444PROBE done" else "Y444PROBE aborted (paused)")
    }

    // ---- clip and codec selection ----

    private fun sizeOrNull(): Pair<Int, Int>? = args.size.also {
        if (it == null) log("Y444PROBE info bad size '${args.str("size")}' (full, small or WxH)")
    }

    private fun load(c: ClipName): LoadedClip {
        val lc = LoadedClip(c, File(dir, c.fileName).readBytes())
        log("Y444PROBE info clip ${c.id} ${c.width}x${c.height} units=${lc.units.size} bytes=${lc.data.size} " +
            "csd=${lc.csd?.size ?: 0} max_unit=${lc.maxUnit}")
        return lc
    }

    /** Main clip (and aux clip unless `aux=none`) for the requested size; null when a clip is missing. */
    private fun pickClips(wantAux: Boolean): Pair<LoadedClip, LoadedClip?>? {
        val (w, h) = sizeOrNull() ?: return null
        val mainName = args.str("main")?.let { ClipName.find(fileNames, it) } ?: ClipName.ofSize(fileNames, w, h, 0)
        if (mainName == null) {
            log("Y444PROBE info no main clip for ${w}x$h in ${dir.path} (adb push one, see the README)")
            return null
        }
        val main = load(mainName)
        if (!wantAux || args.str("aux") == "none") return main to null
        val auxName = args.str("aux")?.let { ClipName.find(fileNames, it) }
            ?: ClipName.ofSize(fileNames, mainName.width, mainName.height, 1) ?: mainName
        val aux = if (auxName.fileName == mainName.fileName) main else load(auxName)
        if (aux === main) log("Y444PROBE info aux = main clip (only one clip of this size; two decoders still run)")
        return main to aux
    }

    private fun codecFor(c: LoadedClip): String? {
        args.str("codec")?.let { return it }
        val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, c.name.width, c.name.height)
        return MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(fmt)
    }

    // ---- T2: raw sampling ----

    private fun runT2() {
        val caps = Native.caps()
        File(dir, "y444-caps.txt").writeText(caps)
        val kv = caps.lines().filter { it.contains('=') }.associate { it.substringBefore('=') to it.substringAfter('=') }
        for (line in caps.lines()) {
            if (line.isEmpty() || line.contains("_all=")) continue
            log("Y444PROBE t2 caps $line")
        }
        log("Y444PROBE t2 caps extension lists in ${File(dir, "y444-caps.txt").path}")
        val glYuv = kv["gl_EXT_YUV_target"] == "1"
        val vkYcbcr = kv.entries.any { it.key.endsWith("_ycbcr_feature") && it.value == "1" } &&
            kv.entries.any { it.key.endsWith("_ext_KHR_sampler_ycbcr_conversion") && it.value == "1" }
        val vkAhb = kv.entries.any { it.key.endsWith("_ext_ANDROID_external_memory_android_hardware_buffer") && it.value == "1" }
        log("Y444PROBE t2 gate1_caps gl_yuv_target=${yn(glYuv)} vk_ycbcr_conversion=${yn(vkYcbcr)} vk_ahb_import=${yn(vkAhb)} " +
            "(vk RGB_IDENTITY is mandatory with the feature; not queried separately)")

        val clips = pickClips(wantAux = false) ?: return
        val main = clips.first
        val codec = codecFor(main) ?: run { log("Y444PROBE t2 raw no HEVC decoder"); return }
        val err = Native.rawInit()
        if (err.isNotEmpty()) {
            log("Y444PROBE t2 raw SKIPPED $err")
            log("Y444PROBE t2 gate1 verdict=FAIL reason=raw_sampling_unavailable")
            return
        }
        try {
            val queue = LinkedBlockingQueue<Image>()
            val dec = ClipDecoder("t2", main, codec, Output.IMAGE_YUV, null, args.fps, 6, { _, _ -> },
                { img, _ -> queue.add(img) }, log)
            val startErr = dec.start()
            if (startErr != null) {
                log("Y444PROBE t2 raw decoder $startErr")
                log("Y444PROBE t2 gate1 verdict=INCONCLUSIVE reason=yuv420888_reader_unsupported")
                dec.stop()
                return
            }
            val targets = args.frames.toSortedSet()
            val last = targets.maxOrNull() ?: 0
            var compared = 0
            var exact = 0
            val deadline = System.nanoTime() + 20_000_000_000L
            var fed = 0
            while (running() && System.nanoTime() < deadline && compared < targets.size) {
                if (fed <= last + 2 && dec.trySubmit()) fed++
                val img = queue.poll(15, TimeUnit.MILLISECONDS) ?: continue
                val frame = (img.timestamp / 1000 / dec.stepUs).toInt()
                if (frame in targets) {
                    val line = compare(img, main.name.width, main.name.height)
                    log("Y444PROBE t2 raw frame=$frame ${main.name.width}x${main.name.height} $line")
                    compared++
                    if (RawVerdict.exact(line) == true) exact++
                }
                img.close()
            }
            while (true) (queue.poll() ?: break).close()
            dec.stop()
            val verdict = when {
                compared == 0 -> "INCONCLUSIVE reason=no_frame_compared"
                exact == compared -> "PASS reason=bit_exact_y_cb_cr frames=$compared"
                else -> "FAIL reason=raw_samples_differ exact_frames=$exact/$compared"
            }
            log("Y444PROBE t2 gate1 verdict=$verdict")
        } finally {
            Native.rawShutdown()
        }
    }

    /** CPU planes of the YUV_420_888 [img] vs the GPU's raw sampling of the same buffer. */
    private fun compare(img: Image, w: Int, h: Int): String {
        val p = img.planes
        val y = PlaneCopy.tight(p[0].buffer, p[0].rowStride, p[0].pixelStride, w, h)
        val u = PlaneCopy.tight(p[1].buffer, p[1].rowStride, p[1].pixelStride, w / 2, h / 2)
        val v = PlaneCopy.tight(p[2].buffer, p[2].rowStride, p[2].pixelStride, w / 2, h / 2)
        val hw = img.hardwareBuffer ?: return "ok=0 err=no_hardware_buffer"
        return try {
            Native.rawCompare(hw, w, h, y, u, v) +
                " cpu_strides=${p[0].rowStride}/${p[0].pixelStride},${p[1].rowStride}/${p[1].pixelStride}," +
                "${p[2].rowStride}/${p[2].pixelStride}"
        } finally {
            hw.close()
        }
    }

    // ---- T1: dual decode ----

    private fun runT1() {
        val clips = pickClips(wantAux = true) ?: return
        val main = clips.first
        val codec = codecFor(main) ?: run { log("Y444PROBE t1 no HEVC decoder"); return }
        val out = if (args.bufferOut) Output.BUFFER else Output.IMAGE_PRIVATE
        // Single stream first (the baseline of the same clip), then main + aux.
        decodeRun("single", main, null, codec, out)
        if (clips.second != null && running()) decodeRun("dual", main, clips.second, codec, out)
    }

    private fun decodeRun(label: String, main: LoadedClip, aux: LoadedClip?, codec: String, out: Output) {
        val fps = args.fps
        val seconds = args.seconds(TestKind.T1)
        val frames = (fps * seconds).toInt() + 8
        val outMain = LongArray(frames + 64)
        val outAux = LongArray(frames + 64)
        val closeImage: (Image, Long) -> Unit = { img, _ -> img.close() }
        val imageSink = if (out == Output.BUFFER) null else closeImage
        val decoders = ArrayList<ClipDecoder>()
        decoders.add(ClipDecoder("main", main, codec, out, null, fps, 6,
            { s, t -> if (s < outMain.size) outMain[s.toInt()] = t }, imageSink, log))
        if (aux != null) {
            decoders.add(ClipDecoder("aux", aux, codecFor(aux) ?: codec, out, null, fps, 6,
                { s, t -> if (s < outAux.size) outAux[s.toInt()] = t }, imageSink, log))
        }
        val errs = decoders.map { it.start() }
        if (errs.any { it != null }) {
            log("Y444PROBE t1 $label start_failed=$errs")
            decoders.forEach { it.stop() }
            return
        }
        pauseMs(300)
        val t0 = System.nanoTime() + 100_000_000L
        val feeder = Feeder(fps, decoders, t0, frames)
        feeder.start()
        val warmFrames = (args.warmup * fps).toInt()
        val deadline = t0 + (seconds * 1e9).toLong()
        val thermal0 = thermal()
        while (running() && System.nanoTime() < deadline) pauseMs(100)
        feeder.halt()
        feeder.join(2000)
        pauseMs(200)
        val ticks = feeder.ticks
        val errors = decoders.mapNotNull { it.error }
        decoders.forEach { it.stop() }
        val r = PairLatency.compute(t0, feeder.periodNs, outMain, if (aux != null) outAux else null, warmFrames, ticks - 2)
        log(String.format(
            Locale.US,
            "Y444PROBE t1 %s size=%dx%d fps=%d out=%s seconds=%.0f ticks=%d pair_ms=%s aux_after_main_ms=%s " +
                "main_ms=%s aux_ms=%s main_only=%d aux_only=%d neither=%d missed_main=%d missed_aux=%d " +
                "thermal=%d->%d errors=%s",
            label, main.name.width, main.name.height, fps, out, seconds, ticks, msDist(r.pairNs),
            msDist(r.auxAfterMainNs), msDist(r.mainNs), msDist(r.auxNs), r.mainOnly, r.auxOnly, r.neither,
            feeder.missed[0], if (aux != null) feeder.missed[1] else -1, thermal0, thermal(), errors,
        ))
    }

    // ---- direct SurfaceView baseline ----

    private fun runDirect() {
        val dmode = args.directMode ?: run { log("Y444PROBE direct bad direct_mode '${args.str("direct_mode")}' (immediate, pts)"); return }
        val clips = pickClips(wantAux = false) ?: return
        val main = clips.first
        val codec = codecFor(main) ?: run { log("Y444PROBE direct no HEVC decoder"); return }
        val surface = host.surfaceFor(main.name.width, main.name.height) ?: run {
            log("Y444PROBE direct no surface"); return
        }
        val fps = args.fps
        val seconds = args.seconds(TestKind.T1)
        val frames = (fps * seconds).toInt() + 8
        val outMain = LongArray(frames + 64)
        val rendered = LongArray(frames + 64)
        val panel = host.requestPanel(args.panel)
        val vsync = VsyncTracker(args.vsyncOffsetNs)
        vsync.start()
        val slots = SlotAllocator(args.leadNs)
        val releaseTarget: ((Long) -> Long)? = if (dmode == DirectMode.PTS) {
            { now -> vsync.grid()?.let { slots.targetNs(now, it) } ?: 0L }
        } else null
        val dec = ClipDecoder("direct", main, codec, Output.SURFACE, surface, fps, 0,
            { s, t -> if (s < outMain.size) outMain[s.toInt()] = t }, null, log, releaseTarget,
            { s, t -> if (s >= 0 && s < rendered.size) rendered[s.toInt()] = t })
        val err = dec.start()
        if (err != null) { log("Y444PROBE direct $err"); dec.stop(); vsync.stop(); return }
        pauseMs(700)  // display mode and the first vsync samples settle
        val t0 = System.nanoTime() + 100_000_000L
        val feeder = Feeder(fps, listOf(dec), t0, frames)
        feeder.start()
        val rates = LongList()
        val deadline = t0 + (seconds * 1e9).toLong()
        while (running() && System.nanoTime() < deadline) {
            pauseMs(1000)
            rates.add((host.refreshRate() * 100).toLong())
        }
        feeder.halt()
        feeder.join(2000)
        val ticks = feeder.ticks
        val derr = dec.error
        pauseMs(200)
        dec.stop()
        val grid = vsync.grid()
        vsync.stop()
        val warm = (args.warmup * fps).toInt()
        val r = PairLatency.compute(t0, feeder.periodNs, outMain, null, warm, ticks - 2)
        // Per-frame arrival (decoder output) -> estimated display, same quads as the GL path's EGL timestamps.
        val quads = LongList()
        var notShown = 0
        for (k in warm.coerceAtLeast(0) until minOf(ticks - 2, outMain.size, rendered.size)) {
            if (outMain[k] == 0L) continue
            if (rendered[k] == 0L || grid == null) { notShown++; continue }
            quads.add(outMain[k]); quads.add(rendered[k])
            quads.add(DisplayEstimate.presentNs(grid, rendered[k], args.leadNs)); quads.add(0L)
        }
        val shown = PresentStats.analyze(quads.toArray(), feeder.periodNs)
        val hz = rates.toArray().map { it / 100.0 }
        log(LatLine.format("direct", dmode.key, "est", "${main.name.width}x${main.name.height}", fps, args.panel, hz,
            shown, quads.size / 4, notShown,
            String.format(Locale.US, "lead_ms=%.1f vsync_period_ms=%.3f slot_bumps=%d slot_folds=%d no_grid=%s missed=%d " +
                "latch_col=render_time decode_out_ms=%s errors=%s thermal=%d",
                args.leadNs / 1e6, (grid?.periodNs ?: 0L) / 1e6, slots.bumps, slots.folds, grid == null,
                feeder.missed[0], msDist(r.mainNs), derr, thermal())))
        log(String.format(
            Locale.US, "Y444PROBE direct mode=${dmode.key} size=%dx%d fps=%d panel_req=%d(%s) refresh_hz_samples=%s decode_out_ms=%s " +
                "missed=%d errors=%s thermal=%d",
            main.name.width, main.name.height, fps, args.panel, panel, rates.toArray().map { it / 100.0 },
            msDist(r.mainNs), feeder.missed[0], derr, thermal(),
        ))
        log("Y444PROBE direct note: compare with t3 using `dumpsys SurfaceFlinger --latency` (README / Handoff)")
    }

    // ---- T3 / T4: decoder -> ImageReader -> GL merge -> SurfaceView ----

    private fun runT3(long: Boolean) {
        val tag = if (long) "t4" else "t3"
        val gl = args.gl ?: run { log("Y444PROBE $tag bad gl '${args.str("gl")}' (oes, main, merge)"); return }
        val pmode = args.present ?: run { log("Y444PROBE $tag bad present '${args.str("present")}' (queue, depth1, pts)"); return }
        val clips = pickClips(wantAux = gl == GlMode.MERGE) ?: return
        val main = clips.first
        val aux = if (gl == GlMode.MERGE) clips.second else null
        val codec = codecFor(main) ?: run { log("Y444PROBE $tag no HEVC decoder"); return }
        val surface = host.surfaceFor(main.name.width, main.name.height) ?: run {
            log("Y444PROBE $tag no surface"); return
        }
        val panel = host.requestPanel(args.panel)
        val fps = args.fps
        val seconds = args.seconds(if (long) TestKind.T4 else TestKind.T3)
        val frames = (fps * seconds).toInt() + 8
        val outMain = LongArray(frames + 64)
        val outAux = LongArray(frames + 64)
        val retired = ConcurrentLinkedQueue<Image>()
        val mailbox = Mailbox(retired)
        val feedPeriodNs = 1_000_000_000L / fps
        val vsync = VsyncTracker(args.vsyncOffsetNs)
        if (pmode == PresentMode.PTS) vsync.start()
        val loop = PresentLoop(surface, main.name.width, main.name.height, gl, args.swap, feedPeriodNs, retired, mailbox,
            pmode, args.leadNs) { vsync.grid() }
        loop.start()
        while (!loop.started) pauseMs(10)
        loop.result()?.let { r ->
            log("Y444PROBE $tag FAILED ${r.error}")
            vsync.stop()
            loop.join(2000)
            return
        }
        val decoders = ArrayList<ClipDecoder>()
        decoders.add(ClipDecoder("main", main, codec, Output.IMAGE_PRIVATE, null, fps, 6,
            { s, t -> if (s < outMain.size) outMain[s.toInt()] = t },
            { img, t -> mailbox.offerMain(Arrived(img, t)) }, log))
        if (aux != null) {
            decoders.add(ClipDecoder("aux", aux, codecFor(aux) ?: codec, Output.IMAGE_PRIVATE, null, fps, 6,
                { s, t -> if (s < outAux.size) outAux[s.toInt()] = t },
                { img, t -> mailbox.offerAux(Arrived(img, t)) }, log))
        }
        val errs = decoders.map { it.start() }
        if (errs.any { it != null }) {
            log("Y444PROBE $tag start_failed=$errs")
            decoders.forEach { it.stop() }
            loop.halt(); loop.join(2000); mailbox.closeAll(); vsync.stop()
            return
        }
        pauseMs(1000)  // let the requested display mode settle
        val t0 = System.nanoTime() + 100_000_000L
        loop.windowStartNs = t0 + (args.warmup * 1e9).toLong()
        val feeder = Feeder(fps, decoders, t0, frames)
        feeder.start()
        val deadline = t0 + (seconds * 1e9).toLong()
        val thermal0 = thermal()
        val rates = LongList()
        var nextSample = t0 + (if (long) 10 else 1) * 1_000_000_000L
        while (running() && System.nanoTime() < deadline) {
            pauseMs(100)
            if (System.nanoTime() >= nextSample) {
                nextSample += (if (long) 10 else 1) * 1_000_000_000L
                rates.add((host.refreshRate() * 100).toLong())
                if (long) log("Y444PROBE t4 sample t=${(System.nanoTime() - t0) / 1_000_000_000L}s ${powerSnapshot()} " +
                    "refresh_hz=${host.refreshRate()} drawn=${loop.drawnSoFar}")
            }
        }
        feeder.halt()
        feeder.join(2000)
        val ticks = feeder.ticks
        val errors = decoders.mapNotNull { it.error }
        decoders.forEach { it.stop() }
        loop.halt()
        loop.join(5000)
        vsync.stop()
        mailbox.closeAll()
        while (true) (retired.poll() ?: break).close()
        val res = loop.result()
        val pr = PairLatency.compute(t0, feeder.periodNs, outMain, if (aux != null) outAux else null,
            (args.warmup * fps).toInt(), ticks - 2)
        if (res == null) { log("Y444PROBE $tag no result"); return }
        val winSec = seconds - args.warmup
        log(String.format(
            Locale.US,
            "Y444PROBE %s present=${pmode.key} size=%dx%d fps=%d gl=%s aux=%s swap=%d panel_req=%d(%s) refresh_hz_samples=%s seconds=%.0f " +
                "drawn=%d/%d decode_pair_ms=%s arrival_to_swap_ms=%s draw_call_ms=%s gpu_ms_mean=%.2f gpu_ms=%s " +
                "arrival_to_latch_ms=%s arrival_to_present_ms=%s present_gap_ms=%s skipped_gaps=%d unresolved_ts=%d " +
                "ts_frames=%d missed_main=%d missed_aux=%d features=[%s] draw_errors=%d error=%s decoder_errors=%s " +
                "thermal=%d->%d win=%.0fs",
            tag, main.name.width, main.name.height, fps, gl.key, aux != null, args.swap, args.panel, panel,
            rates.toArray().map { it / 100.0 }.takeLast(8), seconds, res.drawn, ticks, msDist(pr.pairNs),
            msDist(res.arrivalToSwapNs), msDist(res.drawCallNs), meanMs(res.gpuNs), msDist(res.gpuNs),
            msDist(res.present.arrivalToLatchNs), msDist(res.present.arrivalToPresentNs),
            msDist(res.present.presentGapNs), res.present.skippedGaps, res.present.unresolved,
            res.present.arrivalToLatchNs.size, feeder.missed[0], if (aux != null) feeder.missed[1] else -1,
            res.features, res.drawErrors, res.error, errors, thermal0, thermal(), winSec,
        ))
        log(LatLine.format("gl", pmode.key + if (args.swap == 0) "+swapint0" else "", "measured",
            "${main.name.width}x${main.name.height}", fps, args.panel, rates.toArray().map { it / 100.0 }.takeLast(8),
            res.present, res.present.arrivalToLatchNs.size, res.drawn - res.present.arrivalToLatchNs.size,
            String.format(Locale.US, "swap=%d lead_ms=%.1f draws=%d/%d draw_call_ms=%s arrival_to_swap_ms=%s " +
                "gate_waits=%d gate_wait_ms=%s slot_bumps=%d slot_folds=%d no_grid=%d missed_main=%d draw_errors=%d " +
                "features=[%s] thermal=%d",
                args.swap, args.leadNs / 1e6, res.drawn, ticks, msDist(res.drawCallNs), msDist(res.arrivalToSwapNs),
                res.gateWaitsNs.size, msDist(res.gateWaitsNs), res.slotBumps, res.slotFolds, res.noGridDraws,
                feeder.missed[0], res.drawErrors, res.features, thermal())))
        log("Y444PROBE $tag note: layer composition (HWC vs GPU) and SurfaceFlinger latency come from dumpsys (README / Handoff)")
    }

    // ---- helpers ----

    private fun yn(b: Boolean) = if (b) "yes" else "no"

    private fun pauseMs(ms: Long) {
        try { Thread.sleep(ms) } catch (_: InterruptedException) {}
    }

    private fun thermal(): Int =
        runCatching { (ctx.getSystemService(Context.POWER_SERVICE) as PowerManager).currentThermalStatus }.getOrDefault(-1)

    private fun powerSnapshot(): String {
        val bm = ctx.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val now = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
        val avg = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_AVERAGE)
        val cap = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        val sticky: Intent? = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val temp = sticky?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE) ?: Int.MIN_VALUE
        val plugged = sticky?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1) ?: -1
        return "thermal=${thermal()} current_now_ua=$now current_avg_ua=$avg battery_pct=$cap " +
            "battery_temp_dC=${if (temp == Int.MIN_VALUE) "-" else temp} plugged=$plugged"
    }
}
