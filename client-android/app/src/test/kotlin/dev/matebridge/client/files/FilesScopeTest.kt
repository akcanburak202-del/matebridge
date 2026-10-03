package dev.matebridge.client.files

import dev.matebridge.client.session.Transport
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** T-190 (decision 0028): which directory a scope serves, and a missing folder never falls back to the whole storage. */
class FilesScopeTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun storage(): File = tmp.newFolder("storage").canonicalFile

    @Test fun parseDefaultsToTheMateBridgeFolder() {
        assertEquals(FilesRoot.MATEBRIDGE, FilesRoot.DEFAULT)
        assertEquals(FilesRoot.MATEBRIDGE, FilesRoot.parse(null))
        assertEquals(FilesRoot.MATEBRIDGE, FilesRoot.parse("ALL")) // ids are exact
        assertEquals(FilesRoot.DOWNLOAD, FilesRoot.parse("download"))
        assertEquals(FilesRoot.ALL, FilesRoot.parse("all"))
    }

    @Test fun allServesTheStorageItself() {
        val s = storage()
        assertEquals(s, FilesScope(FilesRoot.ALL, readOnly = false).directory(s))
        assertEquals(s, FilesScope(FilesRoot.ALL, readOnly = true).directory(s))
    }

    @Test fun aMissingFolderIsCreatedDirectlyUnderTheStorage() {
        val s = storage()
        val d = FilesScope(FilesRoot.MATEBRIDGE, false).directory(s)!!
        assertEquals(File(s, "MateBridge"), d)
        assertTrue(d.isDirectory)
        // An existing one is used as it is (contents kept).
        File(d, "keep.txt").writeText("x")
        assertEquals(d, FilesScope(FilesRoot.MATEBRIDGE, true).directory(s))
        assertEquals("x", File(d, "keep.txt").readText())
        File(s, "Download").mkdir()
        assertEquals(File(s, "Download"), FilesScope(FilesRoot.DOWNLOAD, false).directory(s))
    }

    @Test fun neverFallsBackToTheWholeStorage() {
        // A file in the folder's place.
        val s1 = tmp.newFolder("s1").canonicalFile
        File(s1, "MateBridge").writeText("not a folder")
        assertNull(FilesScope(FilesRoot.MATEBRIDGE, false).directory(s1))
        // A symbolic link in the folder's place, even to a folder inside the storage.
        val s2 = tmp.newFolder("s2").canonicalFile
        File(s2, "DCIM").mkdir()
        Files.createSymbolicLink(File(s2, "Download").toPath(), File(s2, "DCIM").toPath())
        assertNull(FilesScope(FilesRoot.DOWNLOAD, false).directory(s2))
        // A dangling link.
        Files.createSymbolicLink(File(s2, "MateBridge").toPath(), File(s2, "nowhere").toPath())
        assertNull(FilesScope(FilesRoot.MATEBRIDGE, false).directory(s2))
        assertFalse(File(s2, "nowhere").exists())
        // The folder cannot be created (the storage itself is missing).
        val gone = File(tmp.root, "no-storage")
        assertNull(FilesScope(FilesRoot.MATEBRIDGE, false).directory(gone))
        assertFalse(gone.exists())
    }

    @Test fun aReadOnlyStorageWithoutTheFolderGivesNull() {
        val s = storage()
        assertTrue(s.setWritable(false))
        try {
            if (File(s, "probe").mkdir()) return // running as root: permissions are not enforced, nothing to check
            assertNull(FilesScope(FilesRoot.MATEBRIDGE, false).directory(s))
        } finally {
            s.setWritable(true)
        }
    }

    @Test fun missingFolderTextNamesTheFolder() {
        assertEquals("Durum: \"MateBridge\" klasörü açılamadı; paylaşım kapalı", FilesScope.missingFolderText(FilesRoot.MATEBRIDGE))
        assertEquals("Durum: \"Download\" klasörü açılamadı; paylaşım kapalı", FilesScope.missingFolderText(FilesRoot.DOWNLOAD))
    }

    // ---- with FilesLifecycle, the way FilesController builds its servers ----

    private class Server(val token: String, val dir: File?, val events: FilesLifecycle.Events, val log: MutableList<String>) :
        FilesLifecycle.Server {
        override fun start() {
            log += "start:$token"
            if (dir == null) events.onStopped(failed = true) // FilesController: no folder, the start fails at once
        }
        override fun stop() { log += "stop:$token" }
    }

    private class Rig(val storage: File, var scope: FilesScope) {
        val log = mutableListOf<String>()
        val servers = mutableListOf<Server>()
        private var n = 0
        val lc = FilesLifecycle<Server>(
            factory = { token, ev, _ -> Server(token, scope.directory(storage), ev, log).also { servers += it } },
            newToken = { "tok${++n}" },
            publish = { log += if (it.ready) "ready:${it.token}" else "off" },
            onStatus = {},
            log = { _, _, _ -> },
        )

        fun sync() = lc.sync(enabled = true, permission = true, foreground = true, sessionTrusted = true, transport = Transport.USB)
    }

    @Test fun aMissingFolderKeepsTheServerOffAndNeverPublishesReady() {
        val s = storage()
        File(s, "MateBridge").writeText("blocked")
        val r = Rig(s, FilesScope(FilesRoot.MATEBRIDGE, false))
        r.sync()
        assertEquals(listOf("start:tok1", "off"), r.log)
        assertEquals(FilesStatus.FAILED, r.lc.status)
        assertNull(r.servers.single().dir) // never the storage root
        // The next sync retries; once the folder can be made, it serves that folder only.
        File(s, "MateBridge").delete()
        r.sync()
        assertEquals(File(s, "MateBridge"), r.servers.last().dir)
        r.servers.last().events.onListening(5)
        assertEquals(FilesStatus.READY, r.lc.status)
        assertTrue(r.log.none { it == "ready:tok1" })
    }

    @Test fun aScopeChangeRestartsWithOffFirstAndANewToken() { // FilesController.rescope: shutdown, then sync again
        val s = storage()
        val r = Rig(s, FilesScope(FilesRoot.MATEBRIDGE, false))
        r.sync()
        r.servers[0].events.onListening(1)
        r.log.clear()
        r.scope = FilesScope(FilesRoot.ALL, readOnly = true)
        r.lc.shutdown()
        r.sync()
        r.servers[1].events.onListening(2)
        assertEquals(listOf("off", "stop:tok1", "start:tok2", "ready:tok2"), r.log)
        assertNotEquals(r.servers[0].dir, r.servers[1].dir)
        assertEquals(s, r.servers[1].dir)
    }
}
