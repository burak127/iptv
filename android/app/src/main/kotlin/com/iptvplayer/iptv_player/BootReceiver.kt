package com.iptvplayer.iptv_player

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Auto-launches the app when the box boots — but ONLY if the user enabled
 * "Start automatisk ved opstart" in Settings (a grandparent-kiosk option, so it
 * never fires on other installs). The flag lives in Flutter's SharedPreferences
 * under the `flutter.`-prefixed key.
 */
class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val CHANNEL_ID = "boot_autostart"
        // Read by MainActivity.onResume, which cancels this notification as
        // soon as the app is actually on screen (see onReceive's comment).
        const val NOTIFICATION_ID = 1001
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_LOCKED_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }

        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE,
        )
        if (!prefs.getBoolean("flutter.auto_start_on_boot", false)) return

        // Some ROMs (this app also targets Amlogic STB vendor builds) fire
        // BOOT_COMPLETED, LOCKED_BOOT_COMPLETED AND QUICKBOOT_POWERON for the
        // same boot — without a guard that launched the app 2-3 times within
        // seconds of each other. elapsedRealtime() resets to ~0 on every real
        // reboot, so comparing against the last-launch value cheaply tells
        // apart "same boot, duplicate broadcast" (small, non-negative delta)
        // from "a genuinely new boot" (the stored value is now larger than the
        // reset clock, so the delta goes negative).
        val bootState = context.getSharedPreferences("boot_receiver_state", Context.MODE_PRIVATE)
        val elapsed = SystemClock.elapsedRealtime()
        val lastLaunchElapsed = bootState.getLong("last_launch_elapsed_ms", -1L)
        val debounceMs = 15_000L
        val delta = elapsed - lastLaunchElapsed
        if (lastLaunchElapsed >= 0 && delta in 0 until debounceMs) return
        bootState.edit().putLong("last_launch_elapsed_ms", elapsed).apply()

        val launch = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }

        // Android 10+ (API 29+) blocks a BroadcastReceiver from starting an
        // Activity directly UNLESS the app holds a background-activity-launch
        // exemption ("Display over other apps"/SYSTEM_ALERT_WINDOW being the
        // relevant one here). Two hard-won facts shape this code:
        //  1. The block is SILENT -- startActivity() returns normally, no
        //     exception -- so failure can't be caught after the fact.
        //  2. It also can't be reliably predicted: Settings.canDrawOverlays()
        //     returned false on a real box whose appop WAS set to allow, i.e.
        //     the upfront check evaluates differently from the BAL check.
        // So: always ATTEMPT the direct start, and always post the fallback
        // notification too. MainActivity cancels the notification the moment
        // it reaches the foreground -- when the direct start worked (exempt),
        // the notification vanishes before it's even noticeable; when it was
        // silently blocked, the notification stays as a one-click opener.
        try {
            context.startActivity(launch)
        } catch (_: Exception) {
            // Ignored -- the notification below covers this case too.
        }
        try {
            showFullScreenLaunch(context, launch)
        } catch (_: Exception) {
            // Best-effort — a failure here must never crash the boot receiver.
        }
    }

    private fun showFullScreenLaunch(context: Context, launch: Intent) {
        // POST_NOTIFICATIONS is a runtime permission on API 33+ (requested
        // from Settings when the user turns the toggle on — see
        // MainActivity.kt). If it was never granted, there is nothing else
        // to fall back to from a background receiver; skip silently.
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return

        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Automatisk opstart",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Bruges kun til at åbne appen automatisk når boksen tændes."
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }

        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle("Åbner IPTV Player…")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setFullScreenIntent(pendingIntent, true)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .build()

        nm.notify(NOTIFICATION_ID, notification)
    }
}
