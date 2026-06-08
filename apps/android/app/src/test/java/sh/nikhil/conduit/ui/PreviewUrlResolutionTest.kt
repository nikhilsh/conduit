package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins [resolvePreviewUrl], the gate behind the Browser tab on both the
 * phone tab strip ([ProjectScreen]) and the tablet right pane
 * ([NeonTabletRightPane]). The Browser tab is shown only when this returns
 * non-null.
 *
 * Parity with iOS `BrowserTab.previewURL`, which guards `!p.url.isEmpty`.
 * The broker emits `preview: {port, url: ""}` while a dev-server port is
 * allocated but nothing is listening yet (e.g. on launch). An empty path
 * must resolve to null so the Browser tab stays hidden until there's a real
 * server — otherwise `"$base/"` resolved non-null and the tab appeared with
 * no server behind it (device bug: "browser tab shows on launch").
 */
class PreviewUrlResolutionTest {

    private val base = "http://10.0.0.5:1977"

    @Test fun emptyPath_hidesTab() = assertNull(resolvePreviewUrl(base, ""))

    @Test fun blankPath_hidesTab() = assertNull(resolvePreviewUrl(base, "   "))

    @Test fun noBase_hidesRelative() = assertNull(resolvePreviewUrl(null, "/preview/x/"))

    @Test fun blankBase_hidesRelative() = assertNull(resolvePreviewUrl("", "/preview/x/"))

    @Test fun relativePath_joinsOntoBase() =
        assertEquals("$base/preview/abc/", resolvePreviewUrl(base, "/preview/abc/"))

    @Test fun relativePathNoSlash_getsSeparator() =
        assertEquals("$base/preview/abc/", resolvePreviewUrl(base, "preview/abc/"))

    @Test fun absoluteUrl_passesThrough() =
        assertEquals("https://example.test/app", resolvePreviewUrl(base, "https://example.test/app"))

    @Test fun absoluteUrl_passesThroughEvenWithoutBase() =
        assertEquals("http://example.test/app", resolvePreviewUrl(null, "http://example.test/app"))
}
