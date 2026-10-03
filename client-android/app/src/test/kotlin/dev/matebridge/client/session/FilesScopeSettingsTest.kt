package dev.matebridge.client.session

import dev.matebridge.client.files.FilesRoot
import dev.matebridge.client.files.FilesScope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-190 (decision 0028): the shared folder and read-only settings persist and default to the narrow choice. */
class FilesScopeSettingsTest {
    private val map = HashMap<String, String>()
    private val store = object : KeyValueStore {
        override fun getString(key: String): String? = map[key]
        override fun putString(key: String, value: String) { map[key] = value }
    }

    @Test fun defaultsAreTheMateBridgeFolderReadWrite() {
        val s = Settings(store)
        assertEquals(FilesRoot.MATEBRIDGE, s.filesRoot())
        assertEquals(FilesRoot.DEFAULT, s.filesRoot())
        assertFalse(s.filesReadOnly())
        assertEquals(FilesScope(FilesRoot.MATEBRIDGE, readOnly = false), s.filesScope())
        assertFalse(s.filesShare()) // sharing itself stays off by default (T-135)
    }

    @Test fun choicesPersistAcrossInstances() {
        for (r in FilesRoot.entries) for (ro in listOf(false, true)) {
            val a = Settings(store)
            a.setFilesRoot(r)
            a.setFilesReadOnly(ro)
            val b = Settings(store) // a new instance on the same store
            assertEquals(r, b.filesRoot())
            assertEquals(ro, b.filesReadOnly())
            assertEquals(FilesScope(r, ro), b.filesScope())
        }
    }

    @Test fun unknownStoredValuesFallBackToTheNarrowDefault() {
        map["files_root"] = "sdcard"
        map["files_read_only"] = "yes"
        val s = Settings(store)
        assertEquals(FilesRoot.MATEBRIDGE, s.filesRoot()) // never the whole storage
        assertFalse(s.filesReadOnly())
        map["files_read_only"] = "1"
        assertTrue(s.filesReadOnly())
    }

    @Test fun logFieldsAreClassesOnly() {
        assertEquals("root=matebridge ro=0", FilesScope(FilesRoot.MATEBRIDGE, false).logFields())
        assertEquals("root=download ro=1", FilesScope(FilesRoot.DOWNLOAD, true).logFields())
        assertEquals("root=all ro=0", FilesScope(FilesRoot.ALL, false).logFields())
    }
}
