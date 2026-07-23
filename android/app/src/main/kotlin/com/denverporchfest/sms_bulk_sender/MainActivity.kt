package com.denverporchfest.sms_bulk_sender

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.OpenableColumns
import android.telephony.SmsManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingPickerResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickCsv" -> pickCsv(result)
                "requestSmsPermission" -> requestSmsPermission(result)
                "sendSms" -> {
                    val phoneNumber = call.argument<String>("phoneNumber")
                    val message = call.argument<String>("message")
                    sendSms(phoneNumber, message, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun pickCsv(result: MethodChannel.Result) {
        if (pendingPickerResult != null) {
            result.error("picker_pending", "A file picker is already open.", null)
            return
        }
        pendingPickerResult = result
        val intent =
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "text/*"
                putExtra(
                    Intent.EXTRA_MIME_TYPES,
                    arrayOf("text/csv", "text/comma-separated-values", "text/plain"),
                )
            }
        startActivityForResult(intent, CSV_PICKER_REQUEST)
    }

    @Deprecated("Uses the activity result callback supported by FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != CSV_PICKER_REQUEST) return

        val result = pendingPickerResult
        pendingPickerResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result?.success(null)
            return
        }

        try {
            val uri = data.data!!
            val name =
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                    ?.use { cursor ->
                        val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (index >= 0 && cursor.moveToFirst()) cursor.getString(index) else null
                    } ?: "messages.csv"
            val bytes =
                contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    ?: throw IllegalArgumentException("Could not read the selected file.")
            result?.success(mapOf("name" to name, "bytes" to bytes))
        } catch (error: Exception) {
            result?.error("file_read_failed", error.message ?: "Could not read the CSV.", null)
        }
    }

    private fun requestSmsPermission(result: MethodChannel.Result) {
        if (
            ContextCompat.checkSelfPermission(this, Manifest.permission.SEND_SMS) ==
                PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            result.error("permission_pending", "An SMS permission request is already open.", null)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.SEND_SMS),
            SMS_PERMISSION_REQUEST,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == SMS_PERMISSION_REQUEST) {
            val granted =
                grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }

    @Suppress("DEPRECATION")
    private fun sendSms(
        phoneNumber: String?,
        message: String?,
        result: MethodChannel.Result,
    ) {
        if (phoneNumber.isNullOrBlank() || message.isNullOrBlank()) {
            result.error("invalid_message", "Phone number and message are required.", null)
            return
        }
        if (
            ContextCompat.checkSelfPermission(this, Manifest.permission.SEND_SMS) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            result.error("permission_denied", "SMS permission is not granted.", null)
            return
        }

        try {
            val smsManager = SmsManager.getDefault()
            val parts = smsManager.divideMessage(message)
            if (parts.size == 1) {
                smsManager.sendTextMessage(phoneNumber, null, message, null, null)
            } else {
                smsManager.sendMultipartTextMessage(phoneNumber, null, parts, null, null)
            }
            result.success(null)
        } catch (error: Exception) {
            result.error("send_failed", error.message ?: "Android could not send the SMS.", null)
        }
    }

    companion object {
        private const val CHANNEL = "sms_bulk_sender/sms"
        private const val SMS_PERMISSION_REQUEST = 4701
        private const val CSV_PICKER_REQUEST = 4702
    }
}
