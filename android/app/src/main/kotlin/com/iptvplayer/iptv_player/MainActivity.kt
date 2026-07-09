package com.iptvplayer.iptv_player

import android.Manifest
import android.app.NotificationManager
import android.app.PictureInPictureParams
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Rational
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 4201
    }

    private var channel: MethodChannel? = null

    // When true (set while the player screen is open), pressing home enters
    // picture-in-picture instead of pausing.
    private var autoPip = false

    // Held between requestNotificationPermission() and onRequestPermissionsResult
    // — the system permission dialog is asynchronous, so the MethodChannel
    // result can't be completed until the callback fires.
    private var pendingNotificationPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Native ExoPlayer + SurfaceView video path (TiviMate-style hardware
        // overlay) for smooth live playback on weak Amlogic TV boxes.
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "iptv/native_video",
            NativeVideoFactory(flutterEngine.dartExecutor.binaryMessenger),
        )
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "iptv/pip")
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(isPipSupported())
                "isTv" -> result.success(
                    packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
                )
                "setAutoPip" -> {
                    autoPip = call.arguments as? Boolean ?: false
                    result.success(null)
                }
                "enterPip" -> result.success(enterPip())
                "setHomeReplacement" -> {
                    result.success(setHomeReplacement(call.arguments as? Boolean ?: false))
                }
                "hasNotificationPermission" -> result.success(hasNotificationPermission())
                "requestNotificationPermission" -> requestNotificationPermission(result)
                "canUseFullScreenIntent" -> result.success(canUseFullScreenIntent())
                "openFullScreenIntentSettings" -> {
                    openFullScreenIntentSettings()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isPipSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun enterPip(): Boolean {
        if (!isPipSupported()) return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val params = PictureInPictureParams.Builder()
                    .setAspectRatio(Rational(16, 9))
                    .build()
                enterPictureInPictureMode(params)
            } else {
                false
            }
        } catch (e: Exception) {
            false
        }
    }

    // Flips the disabled-by-default HomeAlias component on/off — the app is
    // only ever offered as a HOME replacement when the user explicitly opts in
    // from Settings (see AndroidManifest.xml's comment on the alias for why a
    // static, always-on intent-filter was unsafe on phones). Returns whether
    // the change was applied.
    private fun setHomeReplacement(enable: Boolean): Boolean {
        // Refuse to disable our alias when NO other launcher is enabled —
        // that combination leaves the box without any home screen at all
        // (black screen on boot/HOME). Happened for real on a Strong HY4600
        // running in kiosk mode (stock launcher disabled): flipping this
        // toggle off bricked the home screen until adb re-enabled the stock
        // launcher. The Settings UI surfaces the refusal as a message.
        if (!enable && !hasOtherEnabledHome()) return false
        return try {
            packageManager.setComponentEnabledSetting(
                ComponentName(this, "com.iptvplayer.iptv_player.HomeAlias"),
                if (enable) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP,
            )
            true
        } catch (_: Exception) {
            // Best-effort; never crash Settings over this.
            false
        }
    }

    private fun hasOtherEnabledHome(): Boolean {
        return try {
            val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
            packageManager.queryIntentActivities(home, 0).any { info ->
                val ai = info.activityInfo ?: return@any false
                // FallbackHome (com.android.tv.settings) is a boot-time shim,
                // not a real launcher — landing there IS the black screen.
                ai.packageName != packageName && !ai.name.contains("FallbackHome")
            }
        } catch (_: Exception) {
            // Fail open: a query error must not permanently lock the toggle.
            true
        }
    }

    // ---------------- boot-autostart notification permission ----------------
    // POST_NOTIFICATIONS is a runtime permission on API 33+ — BootReceiver's
    // full-screen-intent fallback (see its own doc comment) can't show
    // anything without it, and a background receiver can't request runtime
    // permissions itself, so Settings asks for it here, in the foreground,
    // when the user turns "Start automatisk" on.
    private fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (hasNotificationPermission()) {
            result.success(true)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        pendingNotificationPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST_CODE,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingNotificationPermissionResult?.success(granted)
            pendingNotificationPermissionResult = null
        }
    }

    // Android 14 added a SEPARATE gate on top of POST_NOTIFICATIONS
    // specifically for full-screen-intent notifications — apps that aren't
    // recognized as calling/alarm apps may need the user to flip this on
    // manually. Exposed so Settings can show a hint + a direct link only
    // when it's actually needed (true/not applicable on every earlier
    // Android version).
    private fun canUseFullScreenIntent(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return true
        val nm = getSystemService(NotificationManager::class.java)
        return nm?.canUseFullScreenIntent() ?: true
    }

    private fun openFullScreenIntentSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) return
        try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
                    data = Uri.parse("package:$packageName")
                },
            )
        } catch (_: Exception) {
            // Best-effort — some OEM builds may not ship this settings screen.
        }
    }

    override fun onResume() {
        super.onResume()
        // BootReceiver always posts its "Åbner IPTV Player…" notification
        // alongside its direct-start attempt (the OS blocks background starts
        // SILENTLY, so the receiver can't know which path worked) — reaching
        // the foreground is the success signal, so clear it here. No-op when
        // no such notification exists (normal launches).
        try {
            getSystemService(NotificationManager::class.java)
                ?.cancel(BootReceiver.NOTIFICATION_ID)
        } catch (_: Exception) {
            // Never let notification cleanup interfere with resume.
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (autoPip) enterPip()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        channel?.invokeMethod("pipChanged", isInPictureInPictureMode)
    }
}
