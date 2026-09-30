package dev.matebridge.client.clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.widget.Toast
import dev.matebridge.client.protocol.Clipboard
import dev.matebridge.client.session.MbLog

/**
 * Android glue for [ClipboardSync] (T-055). Main thread only. Reading the clipboard only works while the app has focus
 * (Android 10+), so the listener is active between [start] and [stop] and [check] runs when the app comes to the front.
 * Content is never logged: only direction and length.
 */
class ClipboardBridge(
    private val context: Context,
    val sync: ClipboardSync,
    private val send: (Clipboard) -> Boolean,
) {
    private val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    private var listening = false
    private val listener = ClipboardManager.OnPrimaryClipChangedListener { check(fromListener = true) }

    fun start() {
        if (listening) return
        listening = true
        cm.addPrimaryClipChangedListener(listener)
        check(fromListener = false)
    }

    fun stop() {
        if (!listening) return
        listening = false
        cm.removePrimaryClipChangedListener(listener)
    }

    private fun check(fromListener: Boolean) {
        if (!sync.enabled) return
        val clip = readClip() ?: return
        when (val d = sync.onLocalClip(clip.text, clip.sensitive, if (fromListener) 0L else clip.timestampMs)) {
            ClipboardSync.Decision.Ignore -> Unit
            ClipboardSync.Decision.TooLarge -> {
                MbLog.i("clipboard", "dir=out skipped=too_large", "clipboard")
                Toast.makeText(context, "Pano metni çok uzun, Mac'e gönderilmedi", Toast.LENGTH_SHORT).show()
            }
            is ClipboardSync.Decision.Send -> {
                val ok = send(d.msg)
                MbLog.i("clipboard", "dir=out bytes=${d.msg.data.size} sent=$ok", "clipboard")
            }
        }
    }

    /** Text from the Mac: written with setPrimaryClip (the listener event it causes is suppressed by [ClipboardSync]). */
    fun onRemote(msg: Clipboard) {
        val text = sync.onRemote(msg) ?: return
        MbLog.i("clipboard", "dir=in bytes=${msg.data.size}", "clipboard")
        try {
            cm.setPrimaryClip(ClipData.newPlainText("MateBridge", text))
        } catch (e: RuntimeException) {
            MbLog.w("clipboard", "dir=in write_failed", "clipboard")
        }
    }

    private class Clip(val text: String?, val sensitive: Boolean, val timestampMs: Long)

    private fun readClip(): Clip? = try {
        val clip = cm.primaryClip
        if (clip == null || clip.itemCount == 0) {
            null
        } else {
            val desc = clip.description
            val sensitive = desc.extras?.getBoolean(EXTRA_IS_SENSITIVE, false) ?: false
            val timestamp = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) desc.timestamp else 0L
            // Sensitive content is never even converted to a String.
            Clip(if (sensitive) null else clip.getItemAt(0).coerceToText(context)?.toString(), sensitive, timestamp)
        }
    } catch (e: SecurityException) {
        null // not focused: Android 10+ hides the clipboard
    }

    private companion object {
        // ClipDescription.EXTRA_IS_SENSITIVE (API 33); the literal also works on older releases that honour it.
        const val EXTRA_IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"
    }
}
