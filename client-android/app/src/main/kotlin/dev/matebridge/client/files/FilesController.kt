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
import dev.matebridge.client.session.Transport
import java.security.SecureRandom

/**
 * Android side of the tablet-files server (decision 0015, T-135): the "all files access" permission, starting and
 * stopping [DavServer] on the shared storage, and reporting its state as FILES_INFO through [publish].
 *
 * Lifecycle: [FilesLifecycle] (T-153). The server runs only while the activity is started, the setting is on, the
 * permission is granted and the session is trusted and on USB ([FilesSwitch.shouldRun]); every start has a new token.
 * READY is published only once the socket listens; OFF is published before the server stops. [sync] and [shutdown] are
 * main-thread calls; [publish] and [onStatus] may run on the server's accept thread.
 */
class FilesController(
    publish: (FilesInfo) -> Unit,
    onStatus: () -> Unit,
) {
    private val random = SecureRandom()

    /** Adapter: [FilesLifecycle] knows servers only by start/stop. */
    private class Dav(val server: DavServer) : FilesLifecycle.Server {
        override fun start() = server.start()
        override fun stop() = server.stop()
    }

    private val lifecycle = FilesLifecycle<Dav>(
        factory = { token, events, after ->
            val secret = ByteArray(32).also { random.nextBytes(it) }
            @Suppress("DEPRECATION") // the shared storage root (/storage/emulated/0) is exactly what decision 0015 serves
            val root = Environment.getExternalStorageDirectory()
            Dav(DavServer(root, token, secret, FilesConfig(), object : DavServer.Hooks {
                override fun threadStarted() = Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
                override fun log(ev: String, fields: String) = MbLog.i(ev, fields, COMPONENT)
                override fun onListening(port: Int) = events.onListening(port)
                override fun onStopped(failed: Boolean) = events.onStopped(failed)
            }, after = after?.server))
        },
        newToken = { FilesSwitch.newToken(random) },
        publish = publish,
        onStatus = onStatus,
        log = { warn, ev, fields -> if (warn) MbLog.w(ev, fields, COMPONENT) else MbLog.i(ev, fields, COMPONENT) },
    )

    val status: FilesStatus get() = lifecycle.status

    fun hasPermission(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()

    /**
     * Starts or stops the server for the current [enabled] setting, [foreground] state and session ([sessionTrusted]
     * and its [transport], see [FilesSessionGate]). Main thread.
     */
    fun sync(enabled: Boolean, foreground: Boolean, sessionTrusted: Boolean, transport: Transport?) =
        lifecycle.sync(enabled, hasPermission(), foreground, sessionTrusted, transport)

    fun shutdown() = lifecycle.shutdown()

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

    private companion object {
        const val COMPONENT = "files"
    }
}
