package io.github.yessirks.tuki

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Hands files and text that other apps share with Tuki ("Open with", "Share") to the Dart side.
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pending: Map<String, Any?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tuki/incoming").apply {
            setMethodCallHandler { call, result ->
                if (call.method == "initial") { result.success(pending); pending = null } else result.notImplemented()
            }
        }
        pending = read(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val item = read(intent) ?: return
        channel?.invokeMethod("incoming", item)
    }

    private fun read(intent: Intent?): Map<String, Any?>? {
        if (intent == null) return null
        return try {
            when (intent.action) {
                Intent.ACTION_VIEW -> intent.data?.let { file(it, intent.type) }
                Intent.ACTION_SEND -> {
                    val uri = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                              else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
                    if (uri != null) file(uri, intent.type)
                    else intent.getStringExtra(Intent.EXTRA_TEXT)?.let { mapOf("text" to it, "subject" to intent.getStringExtra(Intent.EXTRA_SUBJECT)) }
                }
                else -> null
            }
        } catch (e: Exception) { mapOf("error" to (e.message ?: "Could not open that")) }
    }

    private fun file(uri: Uri, type: String?): Map<String, Any?> {
        var name = uri.lastPathSegment ?: "file"
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) name = c.getString(0)
        }
        val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: ByteArray(0)
        return mapOf("name" to name, "mime" to (type ?: contentResolver.getType(uri)), "bytes" to bytes)
    }
}
