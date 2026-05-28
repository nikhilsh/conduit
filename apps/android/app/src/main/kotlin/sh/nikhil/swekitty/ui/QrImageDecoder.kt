package sh.nikhil.swekitty.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer

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
 */
object QrImageDecoder {

    /**
     * Loads [uri] as a (downsampled) bitmap and returns the first QR
     * payload it can read. Returns null if the URI can't be opened, the
     * file isn't an image, or the image doesn't contain a QR.
     */
    fun decode(context: Context, uri: Uri): String? {
        val bitmap = loadBitmap(context, uri) ?: return null
        return try {
            decodeQrFromBitmap(bitmap)
        } finally {
            bitmap.recycle()
        }
    }

    private fun loadBitmap(context: Context, uri: Uri): Bitmap? {
        val resolver = context.contentResolver
        // Cheap dimensions pass so we can pick a sane inSampleSize and
        // avoid OOM on a high-res phone screenshot.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            ?: return null
        val sample = sampleSizeFor(bounds.outWidth, bounds.outHeight, target = 1600)
        val opts = BitmapFactory.Options().apply {
            inSampleSize = sample
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, opts) }
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

    private fun decodeQrFromBitmap(bitmap: Bitmap): String? {
        val width = bitmap.width
        val height = bitmap.height
        if (width <= 0 || height <= 0) return null
        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
        val source = RGBLuminanceSource(width, height, pixels)
        val binary = BinaryBitmap(HybridBinarizer(source))
        val reader = MultiFormatReader().apply {
            setHints(
                mapOf(
                    DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                    DecodeHintType.TRY_HARDER to true,
                )
            )
        }
        return runCatching { reader.decode(binary).text }.getOrNull()
    }
}
