package dev.matebridge.client.clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import dev.matebridge.client.protocol.Clipboard
import dev.matebridge.client.session.Latest
import dev.matebridge.client.session.MbLog
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android glue for [ClipboardSync] (T-055). Main thread only. Reading the clipboard only works while the app has focus
 * (Android 10+), so the listener is active between [start] and [stop] and [check] runs when the app comes to the front.
 * Content is never logged: only direction and length.
 */
class ClipboardBridge(
    private val context: Context,
    val sync: ClipboardSync,
    private val send: (Clipboard) -> Boolean,
    private val postToMain: (Runnable) -> Unit,
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

    /** The session was just accepted: a clip copied while the app was in the background (no session) goes out now. Only while focused. */
    fun recheck() { if (listening) check(fromListener = false) }

    fun stop() {
        if (!listening) return
        listening = false
        cm.removePrimaryClipChangedListener(listener)
    }

    private fun check(fromListener: Boolean) {
        val clip = readClip()
        val d = sync.onLocalClip(clip.text, clip.sensitive, if (fromListener) 0L else clip.timestampMs)
        when (d) {
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

    private class Pending(val msg: Clipboard, val gen: Int)

    private val pending = Latest<Pending>()
    private val drainScheduled = AtomicBoolean(false)

    /**
     * Any thread. Latest-value mailbox: at most one pending write and one scheduled main-thread drain, however fast the
     * peer sends; a newer message replaces an undelivered older one. [gen] is the control generation it arrived on.
     */
    fun postRemote(msg: Clipboard, gen: Int) {
        pending.post(Pending(msg, gen))
        if (drainScheduled.compareAndSet(false, true)) postToMain(Runnable { drain() })
    }

    private fun drain() {
        drainScheduled.set(false)
        val p = pending.take() ?: return
        onRemote(p.msg, p.gen)
    }

    /** Text from the Mac: written with setPrimaryClip (the listener event it causes is suppressed by [ClipboardSync]). */
    private fun onRemote(msg: Clipboard, gen: Int) {
        val text = sync.onRemote(msg, gen) ?: return
        MbLog.i("clipboard", "dir=in bytes=${msg.data.size}", "clipboard")
        try {
            cm.setPrimaryClip(ClipData.newPlainText("MateBridge", text))
        } catch (e: RuntimeException) {
            MbLog.w("clipboard", "dir=in write_failed", "clipboard")
        }
    }

    /** [status]: ok | null_clip | security (T-063 diag). */
    private class Clip(val text: String?, val sensitive: Boolean, val timestampMs: Long, val status: String = "ok", val items: Int = -1)

    private fun readClip(): Clip = try {
        val clip = cm.primaryClip
        if (clip == null) {
            Clip(null, false, 0L, "null_clip")
        } else if (clip.itemCount == 0) {
            Clip(null, false, 0L, "ok", 0)
        } else {
            val desc = clip.description
            val sensitive = desc.extras?.getBoolean(EXTRA_IS_SENSITIVE, false) ?: false
            val timestamp = desc.timestamp
            // Sensitive content is never even converted to a String.
            Clip(if (sensitive) null else clip.getItemAt(0).coerceToText(context)?.toString(), sensitive, timestamp, "ok", clip.itemCount)
        }
    } catch (e: SecurityException) {
        Clip(null, false, 0L, "security") // not focused: Android 10+ hides the clipboard
    }

    private companion object {
        // ClipDescription.EXTRA_IS_SENSITIVE (API 33); the literal also works on older releases that honour it.
        const val EXTRA_IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"
    }
}
