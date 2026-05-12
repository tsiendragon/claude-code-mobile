package com.example.ccm_mobile

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingImagePickResult: MethodChannel.Result? = null
    private val imagePickRequestCode = 4102

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ccm_mobile/links")
            .setMethodCallHandler { call, result ->
                if (call.method != "openUrl") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }

                val url = call.argument<String>("url")
                if (url.isNullOrBlank()) {
                    result.error("OPEN_URL_INVALID", "URL is required", null)
                    return@setMethodCallHandler
                }

                try {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                    result.success(null)
                } catch (error: Exception) {
                    result.error("OPEN_URL_FAILED", error.message, null)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ccm_mobile/media")
            .setMethodCallHandler { call, result ->
                if (call.method != "pickImage") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (pendingImagePickResult != null) {
                    result.error("PICK_IMAGE_BUSY", "Another image picker is already open", null)
                    return@setMethodCallHandler
                }
                pendingImagePickResult = result
                try {
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "image/*"
                    }
                    startActivityForResult(intent, imagePickRequestCode)
                } catch (error: Exception) {
                    pendingImagePickResult = null
                    result.error("PICK_IMAGE_FAILED", error.message, null)
                }
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != imagePickRequestCode) return
        val result = pendingImagePickResult ?: return
        pendingImagePickResult = null

        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return
        }
        val uri = data?.data
        if (uri == null) {
            result.error("PICK_IMAGE_INVALID", "No image was selected", null)
            return
        }

        try {
            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
            if (bytes == null || bytes.isEmpty()) {
                result.error("PICK_IMAGE_INVALID", "Selected image is empty", null)
                return
            }
            val mime = contentResolver.getType(uri) ?: "image/jpeg"
            result.success(
                mapOf(
                    "name" to displayName(uri),
                    "mime" to mime,
                    "bytes" to bytes
                )
            )
        } catch (error: Exception) {
            result.error("PICK_IMAGE_FAILED", error.message, null)
        }
    }

    private fun displayName(uri: Uri): String {
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst()) {
                val value = cursor.getString(index)
                if (!value.isNullOrBlank()) return value
            }
        }
        return "image"
    }
}
