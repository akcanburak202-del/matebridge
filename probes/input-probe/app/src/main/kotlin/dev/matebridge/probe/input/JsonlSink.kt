package dev.matebridge.probe.input

import java.io.BufferedWriter
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
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
        error = null
        dir.mkdirs()
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val f = File(dir, "probe-$stamp.jsonl")
        writer = BufferedWriter(OutputStreamWriter(FileOutputStream(f), Charsets.UTF_8), 64 * 1024)
        file = f
        lines = 0
        return f
    }

    /** Set on the first I/O failure; the UI shows it. Cleared by startSession(). */
    var error: String? = null
        private set

    fun write(line: String) {
        val w = writer ?: return
        try {
            w.write(line)
            w.write("\n")
            lines++
        } catch (e: IOException) {
            error = "WRITE FAILED: ${e.message}"
        }
    }

    fun flush() {
        try { writer?.flush() } catch (e: IOException) { error = "FLUSH FAILED: ${e.message}" }
    }

    fun close() {
        try { writer?.flush(); writer?.close() } catch (e: IOException) { error = "CLOSE FAILED: ${e.message}" }
        writer = null
    }
}
