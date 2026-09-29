package dev.matebridge.probe.input

import java.io.BufferedWriter
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStreamWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Buffered JSON Lines writer. Main-thread only; flush() is called on a timer and on pause. */
class JsonlSink(private val dir: File) {
    var file: File? = null
        private set
    var lines = 0L
        private set
    private var writer: BufferedWriter? = null

    fun startSession(): File {
        close()
        dir.mkdirs()
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val f = File(dir, "probe-$stamp.jsonl")
        writer = BufferedWriter(OutputStreamWriter(FileOutputStream(f), Charsets.UTF_8), 64 * 1024)
        file = f
        lines = 0
        return f
    }

    fun write(line: String) {
        val w = writer ?: return
        w.write(line)
        w.write("\n")
        lines++
    }

    fun flush() {
        try { writer?.flush() } catch (_: Exception) {}
    }

    fun close() {
        try { writer?.flush(); writer?.close() } catch (_: Exception) {}
        writer = null
    }
}
