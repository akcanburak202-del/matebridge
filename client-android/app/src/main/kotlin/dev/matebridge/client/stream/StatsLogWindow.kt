package dev.matebridge.client.stream

import dev.matebridge.client.video.VideoStats

/**
 * T-141: when the video stats log lines (`MB/decoder ev=stats`, `MB/render ev=stats`, `MB/render ev=present`) are
 * written. They summarize a log window of [windowMs] (10 s by default, 1 s with `--ez stats_1s true`) made of the
 * per-second stats windows; the per-second STATS message to the host is not affected. Pure logic, one thread.
 */
class StatsLogWindow(val windowMs: Long = DEFAULT_MS) {
    companion object {
        const val DEFAULT_MS = 10_000L
        const val FAST_MS = 1_000L
        /**
         * A window closes on the first per-second tick at or after `windowMs - SLACK_MS`: the ticks are about a second
         * apart but drift late by a few ms, which must not stretch a 10 s window to 11 s.
         */
        const val SLACK_MS = 250L

        /** The window carried video frames; a window without any is not logged (idle screen). */
        fun hasFrames(s: VideoStats.Snapshot): Boolean = s.received + s.decoded + s.rendered + s.dropped > 0
    }

    private var startMs = -1L

    /** A window is open (between [start] and [close]). */
    val isOpen: Boolean get() = startMs >= 0

    /** Opens a new window at [nowMs] (stream configured). */
    fun start(nowMs: Long) { startMs = nowMs }

    /** After a per-second stats window ended at [nowMs]: true when the log window is complete now. */
    fun due(nowMs: Long): Boolean {
        if (startMs < 0) return false
        val slack = if (windowMs > SLACK_MS * 2) SLACK_MS else 0L
        return nowMs - startMs >= windowMs - slack
    }

    /** Closes the window at [nowMs] and returns its length in ms (`interval_ms`), or -1 when none was open. */
    fun close(nowMs: Long): Long {
        if (startMs < 0) return -1
        val len = (nowMs - startMs).coerceAtLeast(0)
        startMs = -1
        return len
    }
}
