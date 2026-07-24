package com.denverporchfest.sms_bulk_sender

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.telephony.SmsManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicInteger

class MainActivity : FlutterActivity() {
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingPickerResult: MethodChannel.Result? = null
    private var statusEventSink: EventChannel.EventSink? = null
    private var statusReceiverRegistered = false
    private val handler = Handler(Looper.getMainLooper())
    private val pendingIntentCode = AtomicInteger(10_000)
    private val pendingMessages = mutableMapOf<String, PendingMessage>()

    private data class PendingMessage(
        val result: MethodChannel.Result,
        val partCount: Int,
        val sentParts: MutableSet<Int> = mutableSetOf(),
        val deliveredParts: MutableSet<Int> = mutableSetOf(),
        var submissionCompleted: Boolean = false,
    )

    private val statusReceiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val messageId = intent?.getStringExtra(EXTRA_MESSAGE_ID) ?: return
                val partIndex = intent.getIntExtra(EXTRA_PART_INDEX, -1)
                when (intent.action) {
                    ACTION_SMS_SENT -> handleSentResult(messageId, partIndex, resultCode)
                    ACTION_SMS_DELIVERED ->
                        handleDeliveryResult(messageId, partIndex, resultCode)
                }
            }
        }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        registerStatusReceiver()
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            STATUS_CHANNEL,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    statusEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    statusEventSink = null
                }
            },
        )
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
                    val messageId = call.argument<String>("messageId")
                    sendSms(phoneNumber, message, messageId, result)
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
        messageId: String?,
        result: MethodChannel.Result,
    ) {
        if (phoneNumber.isNullOrBlank() || message.isNullOrBlank() || messageId.isNullOrBlank()) {
            result.error(
                "invalid_message",
                "Phone number, message, and message ID are required.",
                null,
            )
            return
        }
        if (
            ContextCompat.checkSelfPermission(this, Manifest.permission.SEND_SMS) !=
                PackageManager.PERMISSION_GRANTED
        ) {
            result.error("permission_denied", "SMS permission is not granted.", null)
            return
        }
        if (pendingMessages.containsKey(messageId)) {
            result.error("duplicate_message_id", "Message ID is already in use.", null)
            return
        }

        try {
            val smsManager = SmsManager.getDefault()
            val parts = smsManager.divideMessage(message)
            val pending = PendingMessage(result = result, partCount = parts.size)
            pendingMessages[messageId] = pending
            val sentIntents =
                ArrayList<PendingIntent>(
                    parts.indices.map { partIndex ->
                        statusPendingIntent(ACTION_SMS_SENT, messageId, partIndex)
                    },
                )
            val deliveryIntents =
                ArrayList<PendingIntent>(
                    parts.indices.map { partIndex ->
                        statusPendingIntent(ACTION_SMS_DELIVERED, messageId, partIndex)
                    },
                )
            if (parts.size == 1) {
                smsManager.sendTextMessage(
                    phoneNumber,
                    null,
                    message,
                    sentIntents.single(),
                    deliveryIntents.single(),
                )
            } else {
                smsManager.sendMultipartTextMessage(
                    phoneNumber,
                    null,
                    parts,
                    sentIntents,
                    deliveryIntents,
                )
            }
            handler.postDelayed(
                {
                    val current = pendingMessages[messageId]
                    if (current != null && !current.submissionCompleted) {
                        pendingMessages.remove(messageId)
                        current.submissionCompleted = true
                        current.result.error(
                            "send_timeout",
                            "Android did not confirm carrier submission within 60 seconds.",
                            mapOf("messageId" to messageId),
                        )
                    }
                },
                SUBMISSION_TIMEOUT_MS,
            )
        } catch (error: Exception) {
            pendingMessages.remove(messageId)
            result.error("send_failed", error.message ?: "Android could not send the SMS.", null)
        }
    }

    private fun registerStatusReceiver() {
        if (statusReceiverRegistered) return
        val filter =
            IntentFilter().apply {
                addAction(ACTION_SMS_SENT)
                addAction(ACTION_SMS_DELIVERED)
            }
        ContextCompat.registerReceiver(
            this,
            statusReceiver,
            filter,
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        statusReceiverRegistered = true
    }

    private fun statusPendingIntent(
        action: String,
        messageId: String,
        partIndex: Int,
    ): PendingIntent {
        val intent =
            Intent(action).apply {
                setPackage(packageName)
                putExtra(EXTRA_MESSAGE_ID, messageId)
                putExtra(EXTRA_PART_INDEX, partIndex)
            }
        return PendingIntent.getBroadcast(
            this,
            pendingIntentCode.incrementAndGet(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun handleSentResult(
        messageId: String,
        partIndex: Int,
        resultCode: Int,
    ) {
        val pending = pendingMessages[messageId] ?: return
        if (pending.submissionCompleted) return
        if (resultCode != Activity.RESULT_OK) {
            pending.submissionCompleted = true
            pendingMessages.remove(messageId)
            pending.result.error(
                "carrier_rejected",
                sentErrorMessage(resultCode),
                mapOf(
                    "messageId" to messageId,
                    "part" to partIndex + 1,
                    "resultCode" to resultCode,
                ),
            )
            return
        }

        pending.sentParts.add(partIndex)
        if (pending.sentParts.size == pending.partCount) {
            pending.submissionCompleted = true
            pending.result.success(
                mapOf(
                    "messageId" to messageId,
                    "status" to "carrierAccepted",
                    "parts" to pending.partCount,
                ),
            )
            if (pending.deliveredParts.size == pending.partCount) {
                pendingMessages.remove(messageId)
            } else {
                handler.postDelayed(
                    {
                        val current = pendingMessages.remove(messageId)
                        if (current != null && current.deliveredParts.size < current.partCount) {
                            emitStatus(
                                messageId,
                                "deliveryUnconfirmed",
                                "No delivery report was returned within 10 minutes.",
                            )
                        }
                    },
                    DELIVERY_TIMEOUT_MS,
                )
            }
        }
    }

    private fun handleDeliveryResult(
        messageId: String,
        partIndex: Int,
        resultCode: Int,
    ) {
        val pending = pendingMessages[messageId] ?: return
        if (resultCode != Activity.RESULT_OK) {
            pendingMessages.remove(messageId)
            val detail =
                "The carrier returned a failed delivery report for part ${partIndex + 1}."
            if (pending.submissionCompleted) {
                emitStatus(messageId, "deliveryFailed", detail)
            } else {
                pending.submissionCompleted = true
                pending.result.error(
                    "delivery_failed",
                    detail,
                    mapOf("messageId" to messageId, "part" to partIndex + 1),
                )
            }
            return
        }

        pending.deliveredParts.add(partIndex)
        if (pending.deliveredParts.size == pending.partCount) {
            emitStatus(messageId, "delivered", null)
            if (pending.submissionCompleted) {
                pendingMessages.remove(messageId)
            }
        }
    }

    private fun emitStatus(
        messageId: String,
        status: String,
        detail: String?,
    ) {
        statusEventSink?.success(
            mapOf(
                "messageId" to messageId,
                "status" to status,
                "detail" to detail,
            ),
        )
    }

    private fun sentErrorMessage(resultCode: Int): String =
        when (resultCode) {
            SmsManager.RESULT_ERROR_GENERIC_FAILURE ->
                "The carrier or modem reported a generic send failure."
            SmsManager.RESULT_ERROR_NO_SERVICE -> "No mobile network service is available."
            SmsManager.RESULT_ERROR_NULL_PDU -> "Android could not create the SMS payload."
            SmsManager.RESULT_ERROR_RADIO_OFF -> "The phone radio is turned off."
            SmsManager.RESULT_ERROR_LIMIT_EXCEEDED ->
                "Android or the carrier rejected the SMS because a sending limit was exceeded."
            SmsManager.RESULT_ERROR_FDN_CHECK_FAILURE ->
                "Fixed Dialing Number restrictions blocked this destination."
            SmsManager.RESULT_ERROR_SHORT_CODE_NOT_ALLOWED ->
                "The destination short code is not allowed."
            SmsManager.RESULT_ERROR_SHORT_CODE_NEVER_ALLOWED ->
                "The destination short code is permanently blocked."
            else -> "Android or the carrier rejected the SMS (code $resultCode)."
        }

    override fun onDestroy() {
        if (statusReceiverRegistered) {
            unregisterReceiver(statusReceiver)
            statusReceiverRegistered = false
        }
        pendingMessages.values
            .filterNot { it.submissionCompleted }
            .forEach {
                it.submissionCompleted = true
                it.result.error("app_closed", "The app closed before send confirmation.", null)
            }
        pendingMessages.clear()
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "sms_bulk_sender/sms"
        private const val STATUS_CHANNEL = "sms_bulk_sender/sms_status"
        private const val SMS_PERMISSION_REQUEST = 4701
        private const val CSV_PICKER_REQUEST = 4702
        private const val ACTION_SMS_SENT =
            "com.denverporchfest.sms_bulk_sender.SMS_SENT"
        private const val ACTION_SMS_DELIVERED =
            "com.denverporchfest.sms_bulk_sender.SMS_DELIVERED"
        private const val EXTRA_MESSAGE_ID = "messageId"
        private const val EXTRA_PART_INDEX = "partIndex"
        private const val SUBMISSION_TIMEOUT_MS = 60_000L
        private const val DELIVERY_TIMEOUT_MS = 10 * 60_000L
    }
}
