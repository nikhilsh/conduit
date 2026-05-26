package sh.nikhil.swekitty.ui

import android.content.Context
import android.net.Uri
import android.webkit.MimeTypeMap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AttachFile
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

/**
 * Kinds of attachment the composer's "+" sheet offers. Pure-data enum
 * so unit tests can pin the option list without spinning up Compose.
 * Mirror of iOS `AttachKind` in `ComposerAttachSheet.swift`.
 *
 * Two kinds drive the picker split: [Image] launches the system photo
 * picker (PhotoPicker / `PickVisualMedia`), [File] launches
 * `OpenDocument` (PDFs + arbitrary files). The chosen kind also labels
 * the outgoing message reference line, so the agent knows whether to
 * treat the path as an image or a generic file.
 */
enum class AttachKind {
    Image,
    File;

    val title: String get() = when (this) {
        Image -> "Attach image"
        File -> "Attach file"
    }

    val subtitle: String get() = when (this) {
        Image -> "Pick a photo (JPG/PNG/WebP) — uploaded to the session."
        File -> "Pick a PDF or any file — uploaded to the session."
    }

    /** Lowercase token used in the outgoing message reference line. */
    val referenceToken: String get() = when (this) {
        Image -> "image"
        File -> "file"
    }
}

/**
 * Pure-data outcome of the picker step. Carries the raw bytes so the
 * send path can ship them over the 0x01 binary WS upload frame (core
 * `send_file`); the broker lands them at
 * `uploads/<sessionID>/<filename>`. Equatable (data class) so tests can
 * assert state transitions. Mirrors iOS `ComposerAttachment`.
 */
data class ComposerAttachment(
    val id: String = UUID.randomUUID().toString(),
    val kind: AttachKind,
    val filename: String,
    val mimeType: String,
    val bytes: ByteArray,
) {
    /** Byte length — surfaced in the chip + used for the size guard. */
    val sizeBytes: Int get() = bytes.size

    // data class equality on a ByteArray field compares references, so
    // pin structural equality explicitly. Keeps test assertions and
    // de-dupe logic honest.
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is ComposerAttachment) return false
        return id == other.id &&
            kind == other.kind &&
            filename == other.filename &&
            mimeType == other.mimeType &&
            bytes.contentEquals(other.bytes)
    }

    override fun hashCode(): Int {
        var result = id.hashCode()
        result = 31 * result + kind.hashCode()
        result = 31 * result + filename.hashCode()
        result = 31 * result + mimeType.hashCode()
        result = 31 * result + bytes.contentHashCode()
        return result
    }
}

/**
 * Format the single-line reference the agent acts on once the bytes are
 * uploaded. The broker writes uploads to `uploads/<sessionID>/<filename>`
 * relative to the session workspace, and the agent runs in that
 * workspace — so referencing the relative path lets Claude read the
 * image/PDF/file directly by path.
 *
 * Shape (cross-surface; iOS mirrors this):
 *
 *     [attached <kind>: <filename> — uploads/<sessionID>/<filename>]
 *
 * Pulled out + internal so it's unit-testable without a composition or
 * any Android framework.
 */
internal fun attachmentReferenceLine(
    kind: AttachKind,
    filename: String,
    sessionId: String,
): String = "[attached ${kind.referenceToken}: $filename — uploads/$sessionId/$filename]"

/**
 * Best-effort MIME inference from a content:// URI. Falls back to
 * application/octet-stream when both the ContentResolver and the file
 * extension map come up empty. Pulled out so tests can pin the
 * fallback (no Robolectric / Android framework needed).
 */
internal object ComposerMime {
    fun fromExtension(extension: String?): String {
        if (extension.isNullOrBlank()) return "application/octet-stream"
        val map = MimeTypeMap.getSingleton()
        return map.getMimeTypeFromExtension(extension.lowercase()) ?: "application/octet-stream"
    }

    /** Pure helper used by tests — no Android framework required. */
    fun fromExtensionOrDefault(extension: String?, fromMap: (String) -> String?): String {
        if (extension.isNullOrBlank()) return "application/octet-stream"
        return fromMap(extension.lowercase()) ?: "application/octet-stream"
    }
}

/**
 * Size policy for composer attachments. Uploading multi-MB blobs over
 * the WS control channel stalls the session, so we cap at a sane limit
 * and let the UI warn/skip. Pure object so the threshold is testable.
 */
internal object ComposerAttachmentLimits {
    /** Hard ceiling — anything larger is rejected with a warning. */
    const val MAX_BYTES: Int = 20 * 1024 * 1024

    fun isWithinLimit(sizeBytes: Int): Boolean = sizeBytes in 1..MAX_BYTES
}

/**
 * Modal sheet driven from ChatPage's "+" button. Offers two options
 * (image, file) then dismisses. Picker work is delegated to the
 * platform `PickVisualMedia` / `OpenDocument` contracts so we never
 * touch the user's original file and never request broad storage
 * permission. Picked bytes are read off the main thread and handed
 * back via [onAttach]; the send path uploads them via core `send_file`.
 *
 * Oversized picks are dropped via [onError] (the sheet stays open so
 * the user can retry with a smaller file).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ComposerAttachSheet(
    onAttach: (ComposerAttachment) -> Unit,
    onDismiss: () -> Unit,
    onError: (String) -> Unit = {},
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    fun handlePick(uri: Uri, kind: AttachKind) {
        scope.launch {
            val attachment = withContext(Dispatchers.IO) {
                readAttachment(context, uri, kind)
            }
            when {
                attachment == null ->
                    onError("Couldn't read that file. Try again.")
                !ComposerAttachmentLimits.isWithinLimit(attachment.sizeBytes) -> {
                    val mb = ComposerAttachmentLimits.MAX_BYTES / (1024 * 1024)
                    onError("\"${attachment.filename}\" is too large (limit ${mb}MB).")
                }
                else -> {
                    onAttach(attachment)
                    onDismiss()
                }
            }
        }
    }

    val imagePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri != null) handlePick(uri, AttachKind.Image)
    }

    val filePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri != null) handlePick(uri, AttachKind.File)
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                "Attach",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
            )

            AttachKind.values().forEach { kind ->
                AttachRow(
                    icon = when (kind) {
                        AttachKind.Image -> Icons.Outlined.Image
                        AttachKind.File -> Icons.Outlined.AttachFile
                    },
                    title = kind.title,
                    subtitle = kind.subtitle,
                    onClick = {
                        when (kind) {
                            AttachKind.Image -> imagePicker.launch(
                                PickVisualMediaRequest(
                                    ActivityResultContracts.PickVisualMedia.ImageOnly,
                                ),
                            )
                            // PDFs + arbitrary files. `application/pdf`
                            // is named explicitly so the picker surfaces
                            // it prominently; `*/*` keeps everything else
                            // reachable.
                            AttachKind.File -> filePicker.launch(
                                arrayOf("application/pdf", "*/*"),
                            )
                        }
                    },
                )
            }

            Spacer(Modifier.height(8.dp))
        }
    }
}

@Composable
private fun AttachRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onClick)
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                icon,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(28.dp),
            )
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    title,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Icon(
                Icons.Outlined.ChevronRight,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/**
 * Resolve a picked content:// URI into a [ComposerAttachment]. Reads
 * the bytes, looks up the display name + MIME via the ContentResolver.
 * Returns null on read failure — callers keep the sheet open so the
 * user can retry. MUST be called off the main thread (blocking I/O).
 */
private fun readAttachment(context: Context, uri: Uri, kind: AttachKind): ComposerAttachment? {
    val resolver = context.contentResolver
    val mime = resolver.getType(uri) ?: run {
        val ext = MimeTypeMap.getFileExtensionFromUrl(uri.toString())
        ComposerMime.fromExtension(ext)
    }
    val filename = queryDisplayName(context, uri) ?: uri.lastPathSegment ?: "attachment"
    val bytes = runCatching {
        resolver.openInputStream(uri)?.use { it.readBytes() }
    }.getOrNull() ?: return null
    return ComposerAttachment(
        kind = kind,
        filename = filename,
        mimeType = mime,
        bytes = bytes,
    )
}

private fun queryDisplayName(context: Context, uri: Uri): String? {
    val cursor = context.contentResolver.query(
        uri,
        arrayOf(android.provider.OpenableColumns.DISPLAY_NAME),
        null,
        null,
        null,
    ) ?: return null
    cursor.use {
        if (it.moveToFirst()) {
            val idx = it.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (idx >= 0) return it.getString(idx)
        }
    }
    return null
}
