package dev.matebridge.client.files

import java.io.File
import java.nio.file.Files
import java.text.Normalizer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** T-135: request paths can never leave the shared-storage root. */
class DavPathTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun root(): File = tmp.newFolder("root").canonicalFile

    @Test fun parsesOriginAndAbsoluteForms() {
        assertEquals(listOf("a", "b"), DavPath.parseTarget("/a/b"))
        assertEquals(listOf("a", "b"), DavPath.parseTarget("/a//b/"))
        assertEquals(listOf("MatePad", "x y"), DavPath.parseTarget("http://localhost:47010/MatePad/x%20y?q=1#f"))
        assertEquals(emptyList<String>(), DavPath.parseTarget("/"))
        assertEquals(emptyList<String>(), DavPath.parseTarget("http://localhost:1"))
        assertEquals(emptyList<String>(), DavPath.parseTarget("*"))
        assertNull(DavPath.parseTarget("a/b"))
    }

    @Test fun traversalIsRefusedInEveryEncoding() {
        for (t in listOf("/..", "/a/../b", "/a/%2e%2e/b", "/a/%2E%2E", "/.", "/a/%2e", "/a%2fb", "/a%2F..%2Fb", "/a%00b")) {
            assertNull(t, DavPath.parseTarget(t))
        }
        // Dots that are not whole segments are ordinary names.
        assertEquals(listOf("..a", "b.."), DavPath.parseTarget("/..a/b.."))
    }

    @Test fun badEscapesAndBadUtf8AreRefused() {
        assertNull(DavPath.parseTarget("/%"))
        assertNull(DavPath.parseTarget("/%4"))
        assertNull(DavPath.parseTarget("/%zz"))
        assertNull(DavPath.parseTarget("/%C3")) // truncated UTF-8
        assertNull(DavPath.parseTarget("/%FF%FE"))
    }

    @Test fun turkishNamesRoundTrip() {
        val name = "Çizim ğüşıöİ (1).png"
        val enc = DavPath.encodeSegment(name)
        assertTrue(enc.all { it.code < 128 })
        assertEquals(listOf("Belgeler", name), DavPath.parseTarget("/Belgeler/$enc"))
        assertEquals("/a/%C3%A7izim.png", DavPath.href(listOf("a", "çizim.png"), false))
        assertEquals("/a/", DavPath.href(listOf("a"), true))
        assertEquals("/", DavPath.href(emptyList(), true))
        // Raw UTF-8 bytes in a target (head read as ISO-8859-1) decode too.
        val raw = String("ç".toByteArray(Charsets.UTF_8), Charsets.ISO_8859_1)
        assertEquals(listOf("ç"), DavPath.parseTarget("/$raw"))
    }

    @Test fun resolvesInsideRoot() {
        val r = root()
        File(r, "Pictures").mkdir()
        val res = DavPath.resolve(r, listOf("Pictures", "new.png"))!!
        assertEquals(File(r, "Pictures/new.png"), res.file)
        assertEquals(listOf("Pictures", "new.png"), res.segments)
        assertTrue(DavPath.resolve(r, emptyList())!!.isRoot)
    }

    @Test fun symlinkOutOfRootIsRefused() {
        val r = root()
        val outside = tmp.newFolder("outside")
        File(outside, "secret.txt").writeText("x")
        Files.createSymbolicLink(File(r, "escape").toPath(), outside.toPath())
        assertNull(DavPath.resolve(r, listOf("escape")))
        assertNull(DavPath.resolve(r, listOf("escape", "secret.txt")))
        assertNull(DavPath.resolve(r, listOf("escape", "new.txt")))
        // A dangling link pointing out of the root is refused as well.
        Files.createSymbolicLink(File(r, "dangling").toPath(), File(outside, "missing").toPath())
        assertNull(DavPath.resolve(r, listOf("dangling")))
        // A link that stays inside is fine.
        File(r, "inner").mkdir()
        Files.createSymbolicLink(File(r, "alias").toPath(), File(r, "inner").toPath())
        assertNotNull(DavPath.resolve(r, listOf("alias", "x")))
    }

    @Test fun aSubFolderRootDoesNotReachItsSiblingsOrParent() { // T-190: root = storage/MateBridge
        val storage = tmp.newFolder("storage").canonicalFile
        val r = File(storage, "MateBridge").also { it.mkdir() }
        File(storage, "DCIM").mkdir()
        File(storage, "DCIM/photo.jpg").writeText("x")
        File(storage, "top.txt").writeText("x")
        Files.createSymbolicLink(File(r, "kamera").toPath(), File(storage, "DCIM").toPath())
        Files.createSymbolicLink(File(r, "up").toPath(), storage.toPath())
        Files.createSymbolicLink(File(r, "rel").toPath(), File("../DCIM").toPath())
        for (segs in listOf(listOf("kamera"), listOf("kamera", "photo.jpg"), listOf("kamera", "new.jpg"), listOf("up", "top.txt"), listOf("rel", "photo.jpg"))) {
            assertNull(segs.toString(), DavPath.resolve(r, segs))
        }
        // A sibling whose name starts like the root is not "inside" it.
        val twin = File(storage, "MateBridge2").also { it.mkdir() }
        Files.createSymbolicLink(File(r, "twin").toPath(), twin.toPath())
        assertNull(DavPath.resolve(r, listOf("twin", "x")))
        assertNotNull(DavPath.resolve(r, listOf("new.txt")))
    }

    @Test fun nfdRequestFindsNfcFileAndNewNamesAreNfc() {
        val r = root()
        val nfc = Normalizer.normalize("Öğrenci ödevi.pdf", Normalizer.Form.NFC)
        val nfd = Normalizer.normalize(nfc, Normalizer.Form.NFD)
        File(r, nfc).writeText("x")
        val found = DavPath.resolve(r, listOf(nfd))!!
        // On the tablet (normalization-sensitive) the stored NFC name is found; APFS (where tests run) may match either.
        assertEquals(nfc, Normalizer.normalize(found.name, Normalizer.Form.NFC))
        assertTrue(found.file.exists())
        val created = DavPath.resolve(r, listOf(Normalizer.normalize("yeni ğ.txt", Normalizer.Form.NFD)))!!
        assertEquals(Normalizer.normalize("yeni ğ.txt", Normalizer.Form.NFC), created.name)
    }
}
