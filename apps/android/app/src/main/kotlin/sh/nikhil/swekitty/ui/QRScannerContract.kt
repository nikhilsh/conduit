package sh.nikhil.swekitty.ui

import android.app.Activity
import android.content.Context
import android.content.Intent
import androidx.activity.result.contract.ActivityResultContract
import com.journeyapps.barcodescanner.CaptureActivity
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanIntentResult
import com.journeyapps.barcodescanner.ScanOptions

/**
 * Thin wrapper around zxing-android-embedded's ScanContract that fixes
 * the orientation lock and prompt text. Returns the scanned string or
 * null if cancelled.
 */
class SweKittyScanContract : ActivityResultContract<Unit, String?>() {
    private val inner = ScanContract()

    override fun createIntent(context: Context, input: Unit): Intent {
        val opts = ScanOptions().apply {
            setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            setPrompt("Scan SweKitty pairing QR")
            setBeepEnabled(true)
            setOrientationLocked(false)
            setCaptureActivity(CaptureActivity::class.java)
        }
        return inner.createIntent(context, opts)
    }

    override fun parseResult(resultCode: Int, intent: Intent?): String? {
        val r: ScanIntentResult = inner.parseResult(resultCode, intent)
        return if (resultCode == Activity.RESULT_OK) r.contents else null
    }
}
