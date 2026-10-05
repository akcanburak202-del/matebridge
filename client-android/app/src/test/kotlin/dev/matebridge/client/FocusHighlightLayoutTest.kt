package dev.matebridge.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * T-246: the default focus highlight must stay off on every full-screen focusable view in the main layout. Outside
 * touch mode Android draws it over the focused video SurfaceView, which lifts the stream's black level (~6% white).
 */
class FocusHighlightLayoutTest {
    private val androidNs = "http://schemas.android.com/apk/res/android"

    private fun layout(): File =
        listOf(File("src/main/res/layout/activity_main.xml"), File("app/src/main/res/layout/activity_main.xml"))
            .firstOrNull { it.isFile } ?: error("activity_main.xml not found from ${File(".").absolutePath}")

    private fun elementsById(): Map<String, Element> {
        val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        val doc = factory.newDocumentBuilder().parse(layout())
        val all = doc.getElementsByTagName("*")
        return (0 until all.length).map { all.item(it) as Element }
            .filter { it.hasAttributeNS(androidNs, "id") }
            .associateBy { it.getAttributeNS(androidNs, "id").substringAfter('/') }
    }

    @Test fun fullScreenFocusableViewsDisableDefaultFocusHighlight() {
        val byId = elementsById()
        for (id in listOf("root", "video", "panel")) {
            val el = byId[id]
            assertNotNull("view @id/$id missing from activity_main.xml", el)
            el!!
            assertEquals("@id/$id must set defaultFocusHighlightEnabled=false", "false", el.getAttributeNS(androidNs, "defaultFocusHighlightEnabled"))
        }
    }

    @Test fun videoIsStillTheSurfaceView() {
        assertEquals("SurfaceView", elementsById().getValue("video").tagName)
    }
}
