package dev.matebridge.client.files

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** T-288: PUT over an existing file never loses both the old and the new content, whatever the file system refuses. */
class DavPutReplaceTest {
    @get:Rule val tmp = TemporaryFolder()

    private val token = "0123456789abcdef0123456789abcdef"
    private lateinit var root: File
    private val logs = ArrayList<String>()

    /** Fails the selected operations; everything else is the real file system. Old content starts with "old". */
    private class FaultyFs(
        /** The atomic replace is refused. */
        val failReplace: Boolean = true,
        /** The upload ("new...") cannot be renamed onto the target. */
        val failIntoTarget: Boolean = false,
        /** The backup ("old...") cannot be renamed back onto the target. */
        val failRestore: Boolean = false,
        /** The target cannot be renamed aside. */
        val failBackup: Boolean = false,
    ) : DavFs {
        override fun replace(from: File, to: File) {
            if (failReplace) throw IOException("injected")
            DavFs.Default.replace(from, to)
        }

        override fun rename(from: File, to: File): Boolean {
            val fromTemp = DavHandler.isTempName(from.name)
            val toTemp = DavHandler.isTempName(to.name)
            if (failBackup && !fromTemp && toTemp) return false
            if (failIntoTarget && fromTemp && !toTemp && from.readText().startsWith("new")) return false
            if (failRestore && fromTemp && !toTemp && from.readText().startsWith("old")) return false
            return from.renameTo(to)
        }

        override fun delete(f: File) = f.delete()
    }

    @Before fun setUp() {
        root = tmp.newFolder("storage").canonicalFile
    }

    private fun handler(fs: DavFs) = DavHandler(
        root, DigestAuth(token, ByteArray(32) { 7 }), FilesConfig(preferredPort = 0), { ev, f -> logs += "ev=$ev $f" }, fs = fs,
    )

    private fun basic() = "Basic " + Base64.getEncoder().encodeToString("${FilesConfig.USER}:$token".toByteArray())

    /** Runs one request through [h]; returns the status code and the whole response text. */
    private fun call(
        h: DavHandler, method: String, target: String, body: ByteArray = ByteArray(0), extra: Map<String, String> = emptyMap(),
    ): Pair<Int, String> {
        val headers = mapOf("authorization" to basic(), "content-length" to body.size.toString()) + extra
        val out = ByteArrayOutputStream()
        h.handle(HttpRequest(method, target, "HTTP/1.1", headers), ByteArrayInputStream(body), out)
        val text = out.toString(Charsets.UTF_8)
        return text.substring(9, 12).toInt() to text
    }

    private fun hidden() = root.list()!!.filter { DavHandler.isTempName(it) }.map { File(root, it) }

    @Test fun successfulReplaceKeepsTheStatusCodes() {
        val h = handler(DavFs.Default)
        assertEquals(201, call(h, "PUT", "/MatePad/a.txt", "old".toByteArray()).first)
        assertEquals(204, call(h, "PUT", "/MatePad/a.txt", "new".toByteArray()).first)
        assertEquals("new", File(root, "a.txt").readText())
        assertEquals(emptyList<File>(), hidden())
    }

    @Test fun refusedReplaceFallsBackToBackupAndStillSucceeds() {
        File(root, "a.txt").writeText("old")
        val h = handler(FaultyFs())
        assertEquals(204, call(h, "PUT", "/MatePad/a.txt", "new".toByteArray()).first)
        assertEquals("new", File(root, "a.txt").readText())
        assertEquals(emptyList<File>(), hidden()) // the backup is gone once the upload is in place
        assertEquals(emptyList<String>(), logs)
    }

    @Test fun failedMoveInRestoresTheOldFile() {
        File(root, "a.txt").writeText("old")
        val h = handler(FaultyFs(failIntoTarget = true))
        assertEquals(500, call(h, "PUT", "/MatePad/a.txt", "new".toByteArray()).first)
        assertEquals("old", File(root, "a.txt").readText())
        assertEquals(emptyList<File>(), hidden())
        assertTrue(logs.any { it == "ev=put_replace_failed restored=1" })
    }

    @Test fun failedBackupLeavesTheOldFileUntouched() {
        File(root, "a.txt").writeText("old")
        val h = handler(FaultyFs(failBackup = true))
        assertEquals(500, call(h, "PUT", "/MatePad/a.txt", "new".toByteArray()).first)
        assertEquals("old", File(root, "a.txt").readText())
        assertEquals(emptyList<File>(), hidden())
    }

    @Test fun failedRollbackKeepsBothContentsAndHidesThem() {
        File(root, "a.txt").writeText("old")
        val h = handler(FaultyFs(failIntoTarget = true, failRestore = true))
        assertEquals(500, call(h, "PUT", "/MatePad/a.txt", "new".toByteArray()).first)
        assertEquals(setOf("old", "new"), hidden().map { it.readText() }.toSet())
        assertTrue(logs.any { it == "ev=put_replace_failed restored=0" })
        assertTrue(logs.none { it.contains("a.txt") })
        val (status, listing) = call(h, "PROPFIND", "/MatePad/", extra = mapOf("depth" to "1"))
        assertEquals(207, status)
        assertFalse(listing.contains(DavHandler.TEMP_PREFIX))
    }

    @Test fun failedReplaceOfAMissingTargetLeavesNothing() {
        val h = handler(FaultyFs())
        assertEquals(500, call(h, "PUT", "/MatePad/a.txt", "new".toByteArray()).first)
        assertFalse(File(root, "a.txt").exists())
        assertEquals(emptyList<File>(), hidden())
    }
}
