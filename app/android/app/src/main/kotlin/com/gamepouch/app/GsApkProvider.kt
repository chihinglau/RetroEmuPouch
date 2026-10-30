package com.retroemupouch.app

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File

/**
 * Minimal, dependency-free content provider for handing a downloaded OTA APK
 * to the system package installer. Only files inside `filesDir/updates` are
 * served (canonical-path check blocks traversal), read-only.
 */
class GsApkProvider : ContentProvider() {

    private fun resolveFile(uri: Uri): File? {
        val ctx = context ?: return null
        val path = uri.getQueryParameter("path") ?: return null
        val root = File(ctx.filesDir, "updates").canonicalPath
        val f = File(path)
        val canonical = f.canonicalPath
        if (!canonical.startsWith(root + File.separator) && canonical != root) {
            return null
        }
        return if (f.isFile) f else null
    }

    override fun onCreate(): Boolean = true

    override fun getType(uri: Uri): String = "application/vnd.android.package-archive"

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        if (mode != "r") return null
        val f = resolveFile(uri) ?: return null
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? {
        val f = resolveFile(uri) ?: return null
        val cols = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val cursor = MatrixCursor(cols)
        cursor.addRow(arrayOf<Any?>(f.name, f.length()))
        return cursor
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0
}
