package com.congodeveloperclub.opencongopay.sms

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import com.congodeveloperclub.opencongopay.MainActivity
import com.congodeveloperclub.opencongopay.R

/** A deliberately generic prompt; no sender, SMS content, amount, or reference leaves the encrypted vault. */
internal object OperatorSmsReviewNotification {
    private const val CHANNEL_ID = "operator_sms_review"
    private const val NOTIFICATION_ID = 4401

    fun show(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return

        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Payment review", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    description = "Generic prompts to review securely captured payment notifications."
                },
            )
        }
        val intent = Intent(context, MainActivity::class.java).apply {
            action = "openpaycongo.operator_sms_review"
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = PendingIntent.getActivity(
            context,
            NOTIFICATION_ID,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            Notification.Builder(context)
        }
        manager.notify(
            NOTIFICATION_ID,
            builder
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle("Payment review needed")
                .setContentText("Open OpenPayCongo to review a securely captured notification.")
                .setContentIntent(pending)
                .setAutoCancel(true)
                .setCategory(Notification.CATEGORY_STATUS)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .build(),
        )
    }
}
