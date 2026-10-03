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
 * Scope (T-190, decision 0028): every start reads [scope] and serves only its folder ([FilesScope.directory]), read-only
 * when asked. A folder that is missing and cannot be created keeps the server off (OFF, FAILED, [statusText] says why);
 * it never falls back to the whole storage. [rescope] restarts a running server whose scope changed.
 *
 * Lifecycle: [FilesLifecycle] (T-153). The server runs only while the activity is started, the setting is on, the
 * permission is granted and the session is trusted and on USB ([FilesSwitch.shouldRun]); every start has a new token.
 * READY is published only once the socket listens; OFF is published before the server stops. [sync] and [shutdown] are
 * main-thread calls; [publish] and [onStatus] may run on the server's accept thread.
 */
class FilesController(
    publish: (FilesInfo) -> Unit,
    /** The stored scope (T-190); read at every server start. Main thread. */
    private val scope: () -> FilesScope,
    onStatus: () -> Unit,
) {
    private val random = SecureRandom()

    /** The scope of the last server start (main thread); null before the first. */
    private var startedScope: FilesScope? = null

    /** The last start found no usable folder (T-190): the FAILED status line names the folder. */
    @Volatile private var folderMissing = false

    /** The last [sync] inputs, so [rescope] can start again with them (main thread). */
    private var lastSync: (() -> Unit)? = null

    /**
     * Adapter: [FilesLifecycle] knows servers only by start/stop. A scope without a usable folder has no [server]: its
     * start reports a failed server at once ([fail]). [predecessor] carries a stopped server's workers to the next start.
     */
    private class Dav(val server: DavServer?, val predecessor: DavServer?, val fail: (() -> Unit)?) : FilesLifecycle.Server {
        override fun start() { server?.start() ?: fail?.invoke() }
        override fun stop() { server?.stop() }
        /** The server the next start must wait for. */
        fun waitFor(): DavServer? = server ?: predecessor
    }

    private val lifecycle = FilesLifecycle<Dav>(
        factory = { token, events, after ->
            val sc = scope()
            startedScope = sc
            @Suppress("DEPRECATION") // the shared storage root (/storage/emulated/0); decision 0028 picks a folder in it
            val storage = Environment.getExternalStorageDirectory()
            val dir = sc.directory(storage)
            folderMissing = dir == null
            if (dir == null) {
                MbLog.w("scope_missing", sc.logFields(), COMPONENT)
                Dav(null, after?.waitFor()) { events.onStopped(failed = true) }
            } else {
                MbLog.i("scope", sc.logFields(), COMPONENT)
                val secret = ByteArray(32).also { random.nextBytes(it) }
                Dav(DavServer(dir, token, secret, FilesConfig(readOnly = sc.readOnly), object : DavServer.Hooks {
                    override fun threadStarted() = Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
                    override fun log(ev: String, fields: String) = MbLog.i(ev, fields, COMPONENT)
                    override fun onListening(port: Int) = events.onListening(port)
                    override fun onStopped(failed: Boolean) = events.onStopped(failed)
                }, after = after?.waitFor()), null, null)
            }
        },
        newToken = { FilesSwitch.newToken(random) },
        publish = publish,
        onStatus = onStatus,
        log = { warn, ev, fields -> if (warn) MbLog.w(ev, fields, COMPONENT) else MbLog.i(ev, fields, COMPONENT) },
    )

    val status: FilesStatus get() = lifecycle.status

    /** The "Tablet dosyaları" status line (T-190: a missing folder is named instead of the generic failure). */
    val statusText: String
        get() = lifecycle.status.let { st ->
            if (st == FilesStatus.FAILED && folderMissing) FilesScope.missingFolderText(startedScope?.root ?: scope().root)
            else FilesSwitch.statusText(st)
        }

    fun hasPermission(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && Environment.isExternalStorageManager()

    /**
     * Starts or stops the server for the current [enabled] setting, [foreground] state and session ([sessionTrusted]
     * and its [transport], see [FilesSessionGate]). Main thread.
     */
    fun sync(enabled: Boolean, foreground: Boolean, sessionTrusted: Boolean, transport: Transport?) {
        lastSync = { lifecycle.sync(enabled, hasPermission(), foreground, sessionTrusted, transport) }
        lastSync?.invoke()
    }

    /**
     * The stored scope changed (T-190). A running server with another scope stops (OFF) and, with the last [sync]
     * inputs, starts again: a new token, READY once it listens; the Mac remounts (T-136). A server that is not running
     * is only re-synced (a FAILED missing-folder start retries with the new folder). Main thread.
     */
    fun rescope() {
        val sc = scope()
        val running = lifecycle.status == FilesStatus.STARTING || lifecycle.status == FilesStatus.READY
        if (running && sc == startedScope) return
        MbLog.i("scope_change", "${sc.logFields()} running=${if (running) 1 else 0}", COMPONENT)
        if (running) lifecycle.shutdown() // OFF before the stop; FilesLifecycle has no restart reason of its own
        lastSync?.invoke()
    }

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
