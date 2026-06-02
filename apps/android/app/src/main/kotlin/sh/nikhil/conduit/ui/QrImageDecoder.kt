package sh.nikhil.conduit.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.net.Uri
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.MultiFormatReader
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.GlobalHistogramBinarizer
import com.google.zxing.common.HybridBinarizer
import sh.nikhil.conduit.Telemetry

/**
 * Decode a QR payload out of an image the user picked from the gallery.
 * Camera-scan can't read a screenshot of a pairing QR (which is the
 * common case when the QR shows up in a chat / on the other device),
 * so [AddServerSheet] also exposes a "Scan QR from image" entry that
 * runs through this decoder.
 *
 * Uses `com.google.zxing:core` (transitive via `zxing-android-embedded`)
 * — no new dependency. The bitmap is downsampled with `inSampleSize` so
 * a 4K screenshot doesn't pin a 60MB ARGB buffer for decode.
 *
 * Robustness notes (the pairing QR is a clean, generator-produced PNG —
 * a 1-bit indexed PNG with a tRNS chunk in `rsc.io/qr`'s case — and stock
 * ZXing decodes it fine on desktop, yet `BitmapFactory` on Android can
 * hand back pixels that ZXing then can't read):
 *  - We re-draw the decoded bitmap onto a fresh, opaque, white-filled
 *    ARGB_8888 canvas before reading pixels. That flattens away the
 *    quirks of low-bit-depth / indexed / alpha-flagged (premultiplied)
 *    PNG decodes into clean straight-alpha RGB — the single most
 *    important step for "clean QR won't scan from gallery".
 *  - We add a white quiet-zone margin so a tightly-cropped screenshot
 *    still satisfies ZXing's 4-module border requirement.
 *  - We try HybridBinarizer (good for camera photos), then
 *    GlobalHistogramBinarizer (better for clean synthetic QR), and an
 *    inverted pass (white-on-black / dark-mode screenshots).
 */
object QrImageDecoder {

    /**
     * Loads [uri] as a (downsampled, normalized) bitmap and returns the
     * first QR payload it can read. Returns null if the URI can't be
     * opened, the file isn't an image, or the image doesn't contain a QR.
     */
    fun decode(context: Context, uri: Uri): String? {
        // Diagnostics threaded through the pipeline so a failure reports
        // *where* it failed to Sentry (this path fails by returning null,
        // not throwing, so it was otherwise invisible). Device-debug for
        // "No QR code found" on Android.
        val diag = linkedMapOf<String, String>()
        diag["uri_scheme"] = uri.scheme ?: "?"
        runCatching { context.contentResolver.getType(uri) }.getOrNull()?.let { diag["mime"] = it }
        return try {
            val bitmap = loadBitmap(context, uri, diag)
            if (bitmap == null) {
                Telemetry.diagnostic("QR-from-image: failed to load bitmap", extras = diag)
                return null
            }
            val payload = try {
                decodeQrFromBitmap(bitmap, diag)
            } finally {
                bitmap.recycle()
            }
            if (payload == null) {
                Telemetry.diagnostic("QR-from-image: no QR decoded from bitmap", extras = diag)
            } else {
                Telemetry.breadcrumb("qr", "QR-from-image: decoded", diag)
            }
            payload
        } catch (t: Throwable) {
            diag["exception"] = t.javaClass.simpleName + ": " + (t.message ?: "")
            Telemetry.capture(t, "QR-from-image: decode threw", extras = diag)
            null
        }
    }

    private fun loadBitmap(context: Context, uri: Uri, diag: MutableMap<String, String>): Bitmap? {
        val resolver = context.contentResolver
        // Cheap dimensions pass so we can pick a sane inSampleSize and
        // avoid OOM on a high-res phone screenshot.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        val boundsStream = resolver.openInputStream(uri)
        if (boundsStream == null) {
            diag["stage"] = "open-stream-null"
            return null
        }
        boundsStream.use { BitmapFactory.decodeStream(it, null, bounds) }
        diag["src_w"] = bounds.outWidth.toString()
        diag["src_h"] = bounds.outHeight.toString()
        bounds.outMimeType?.let { diag["src_mime"] = it }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
            diag["stage"] = "bounds-invalid"
            return null
        }
        val sample = sampleSizeFor(bounds.outWidth, bounds.outHeight, target = 1600)
        diag["sample"] = sample.toString()
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val decoded = resolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, opts)
        }
        if (decoded == null) {
            diag["stage"] = "decode-null"
            return null
        }
        diag["dec_w"] = decoded.width.toString()
        diag["dec_h"] = decoded.height.toString()
        diag["dec_config"] = decoded.config?.name ?: "?"
        diag["dec_hasAlpha"] = decoded.hasAlpha().toString()
        return try {
            normalize(decoded).also {
                diag["norm_w"] = it.width.toString()
                diag["norm_h"] = it.height.toString()
            }
        } finally {
            // `normalize` copies into a new bitmap; the raw decode is dead.
            decoded.recycle()
        }
    }

    /**
     * Flatten [src] onto an opaque white ARGB_8888 canvas (plus a white
     * quiet-zone margin). This is what makes a 1-bit / indexed /
     * alpha-flagged PNG decode reliably: whatever odd config
     * `BitmapFactory` produced, the canvas draw composites it down to
     * clean opaque RGB that `getPixels` reads correctly, and transparent
     * pixels resolve to white (background) rather than premultiplied black.
     */
    private fun normalize(src: Bitmap): Bitmap {
        // ~6% margin per side, capped, so the quiet zone is comfortably
        // >= 4 modules even for a tightly-cropped QR.
        val margin = (minOf(src.width, src.height) * 0.06f).toInt().coerceIn(8, 64)
        val out = Bitmap.createBitmap(
            src.width + margin * 2,
            src.height + margin * 2,
            Bitmap.Config.ARGB_8888,
        )
        val canvas = Canvas(out)
        canvas.drawColor(Color.WHITE)
        canvas.drawBitmap(src, margin.toFloat(), margin.toFloat(), null)
        return out
    }

    private fun sampleSizeFor(width: Int, height: Int, target: Int): Int {
        if (width <= 0 || height <= 0) return 1
        var sample = 1
        var w = width
        var h = height
        while (w / 2 >= target && h / 2 >= target) {
            w /= 2
            h /= 2
            sample *= 2
        }
        return sample
    }

    private fun decodeQrFromBitmap(bitmap: Bitmap, diag: MutableMap<String, String>): String? {
        val width = bitmap.width
        val height = bitmap.height
        if (width <= 0 || height <= 0) {
            diag["stage"] = "norm-invalid"
            return null
        }
        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
        val source = RGBLuminanceSource(width, height, pixels)
        // Hybrid first (lenient on uneven lighting / camera shots), then a
        // global-threshold pass (better on clean synthetic QR), then the
        // inverted source for white-on-black / dark-mode screenshots. Record
        // which pass won (or that all failed) for diagnostics.
        readWith(HybridBinarizer(source))?.let { diag["decoded_by"] = "hybrid"; return it }
        readWith(GlobalHistogramBinarizer(source))?.let { diag["decoded_by"] = "global"; return it }
        invertedOrNull(source)?.let { inv ->
            readWith(HybridBinarizer(inv))?.let { diag["decoded_by"] = "hybrid-inv"; return it }
            readWith(GlobalHistogramBinarizer(inv))?.let { diag["decoded_by"] = "global-inv"; return it }
        }
        diag["stage"] = "no-qr-all-binarizers"
        return null
    }

    private fun invertedOrNull(source: LuminanceSource): LuminanceSource? =
        runCatching { source.invert() }.getOrNull()

    private fun readWith(binarizer: com.google.zxing.Binarizer): String? {
        val reader = MultiFormatReader().apply {
            setHints(
                mapOf(
                    DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                    DecodeHintType.TRY_HARDER to true,
                )
            )
        }
        return runCatching { reader.decode(BinaryBitmap(binarizer)).text }.getOrNull()
    }
}
