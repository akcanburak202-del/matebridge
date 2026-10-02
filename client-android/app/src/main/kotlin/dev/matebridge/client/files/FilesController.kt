package dev.matebridge.client.files

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Process
import dev.matebridge.client.protocol.FilesInfo
import dev.matebridge.client.session.MbLog
import java.security.SecureRandom

/**
 * Android side of the tablet-files server (decision 0015, T-135): the "all files access" permission, starting and
 * stopping [DavServer] on the shared storage, and reporting its state as FILES_INFO through [publish].
 *
 * Lifecycle (Handoff): the server runs only while the activity is started, the setting is on and the permission is
 * granted ([FilesSwitch.shouldRun]); every start has a new token. READY is published only once the socket listens; OFF
 * is published before the server stops. [sync] and [shutdown] are main-thread calls; [publish] and [onStatus] may run on
 * the server's accept thread.
 */
class FilesController(
    private val publish: (FilesInfo) -> Unit,
    private val onStatus: () -> Unit,
) {
    private val random = SecureRandom()
    private val lock = Any()
    private var server: DavServer? = null
    /** The last stopped server: the next one listens only after its workers (a running COPY/DELETE) ended. */
    private var retired: DavServer? = null
    private var gen = 0

    @Volatile var status = FilesStatus.DISABLED
        private set

    fun hasPermission(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()

    /** Starts or stops the server for the current [enabled] setting and [foreground] state. Main thread. */
    fun sync(enabled: Boolean, foreground: Boolean) {
        val permission = hasPermission()
        if (FilesSwitch.shouldRun(enabled, permission, foreground)) {
            synchronized(lock) { if (server == null) startLocked() }
        } else {
            stop(if (!enabled) "disabled" else if (!permission) "no_permission" else "background")
            setStatus(FilesSwitch.idleStatus(enabled, permission))
        }
    }

    fun shutdown() = stop("destroy")

    /**
     * Opens the system's "all files access" screen for this app (Android 11+), falling back to the general list and
     * then to the app's details. False when nothing could be opened.
     */
    fun openPermissionScreen(activity: Activity): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        val pkg = Uri.parse("package:${activity.packageName}")
        val intents = listOf(
            Intent(android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, pkg),
            Intent(android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION),
            Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkg),
        )
        for (i in intents) {
            try {
                activity.startActivity(i)
                MbLog.i("permission_screen", "step=${intents.indexOf(i)}", COMPONENT)
                return true
            } catch (e: ActivityNotFoundException) {
                // try the next one
            } catch (e: SecurityException) {
                // try the next one
            }
        }
        MbLog.w("permission_screen_missing", "", COMPONENT)
        return false
    }

    private fun startLocked() {
        val myGen = ++gen
        val token = FilesSwitch.newToken(random)
        val secret = ByteArray(32).also { random.nextBytes(it) }
        @Suppress("DEPRECATION") // the shared storage root (/storage/emulated/0) is exactly what decision 0015 serves
        val root = Environment.getExternalStorageDirectory()
        val s = DavServer(root, token, secret, FilesConfig(), object : DavServer.Hooks {
            override fun threadStarted() = Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)

            override fun log(ev: String, fields: String) = MbLog.i(ev, fields, COMPONENT)

            // Publishing happens under the lock (it only posts to a mailbox), so a READY can never overtake the OFF of
            // a stop() that raced with it.
            override fun onListening(port: Int) {
                synchronized(lock) {
                    if (gen != myGen) return
                    publish(FilesInfo(FilesInfo.STATE_READY, port, token))
                    setStatus(FilesStatus.READY)
                }
                MbLog.i("server", "state=on port=$port", COMPONENT)
            }

            override fun onStopped(failed: Boolean) {
                synchronized(lock) {
                    if (gen != myGen) return // stopped on purpose: stop() already reported OFF
                    retired = server
                    server = null
                    publish(FilesInfo.OFF)
                    setStatus(FilesStatus.FAILED)
                }
                MbLog.w("server", "state=off port=0 reason=${if (failed) "failed" else "ended"}", COMPONENT)
            }
        }, after = retired)
        retired = null
        server = s
        setStatus(FilesStatus.STARTING)
        s.start()
    }

    private fun stop(reason: String) {
        val s = synchronized(lock) {
            val cur = server ?: return
            server = null
            retired = cur
            gen++ // late callbacks of the old server are ignored
            publish(FilesInfo.OFF) // queued before the listener closes, so the host learns OFF as early as possible
            cur
        }
        s.stop()
        MbLog.i("server", "state=off port=0 reason=$reason", COMPONENT)
    }

    private fun setStatus(s: FilesStatus) {
        synchronized(lock) {
            if (status == s) return
            status = s
        }
        onStatus()
    }

    private companion object {
        const val COMPONENT = "files"
    }
}
