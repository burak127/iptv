package com.iptvplayer.iptv_player

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.SurfaceView
import android.view.View
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.io.File

/**
 * A native ExoPlayer rendering onto a [SurfaceView] — a hardware overlay plane
 * composited by SurfaceFlinger, NOT through Flutter's texture pipeline. This is
 * how native IPTV apps (TiviMate) stay smooth on weak Amlogic boxes: the decoder
 * draws straight to the display, with zero per-frame CPU copy / GPU composite.
 *
 * Controlled from Dart over a per-view MethodChannel `iptv/native_video_<id>`.
 */
@UnstableApi
class NativeVideoView(
    context: Context,
    id: Int,
    creationParams: Map<*, *>?,
    messenger: BinaryMessenger,
) : PlatformView, MethodChannel.MethodCallHandler {

    // A SurfaceView always stretches its decoded frames to exactly fill its
    // own current pixel bounds — there's no "fit" concept inside it, and (a
    // first attempt confirmed) resizing it smaller via an
    // AspectRatioFrameLayout wrapper doesn't reliably show through Flutter's
    // hybrid-composition hosting the way it would in a plain Android view
    // hierarchy. Simplest, most reliable fix: keep this view always filling
    // whatever box Flutter gives it, and have FLUTTER do the actual
    // contain/cover/fill sizing on ITS side (same FittedBox+SizedBox pattern
    // already used for the media_kit path) — that only needs the video's
    // aspect ratio, pushed here via the "videoSize" event below.
    private val surfaceView = SurfaceView(context)
    private val channel = MethodChannel(messenger, "iptv/native_video_$id")
    private var player: ExoPlayer? = null
    private val userAgent: String =
        (creationParams?.get("userAgent") as? String) ?: "VLC/3.0.20 LibVLC/3.0.20"

    // Pushes position/duration to Dart so an on-demand seek bar and resume
    // persistence can work off this player exactly like the media_kit path —
    // ExoPlayer doesn't expose these as a stream, so we poll.
    private val positionHandler = Handler(Looper.getMainLooper())
    private var positionLoopRunning = false
    private val positionRunnable = object : Runnable {
        override fun run() {
            val p = player
            if (p != null) {
                val duration = p.duration
                channel.invokeMethod(
                    "position",
                    mapOf(
                        "position" to p.currentPosition,
                        // C.TIME_UNSET (-9223372036854775807L) until known.
                        "duration" to if (duration > 0) duration else 0L,
                    ),
                )
            }
            if (positionLoopRunning) positionHandler.postDelayed(this, 500)
        }
    }

    init {
        channel.setMethodCallHandler(this)
        buildPlayer(context)
        val startPositionMs = (creationParams?.get("startPositionMs") as? Number)?.toLong() ?: 0L
        (creationParams?.get("url") as? String)?.let { setSource(it, startPositionMs) }
        positionLoopRunning = true
        positionHandler.post(positionRunnable)
    }

    private fun buildPlayer(context: Context) {
        val httpFactory = DefaultHttpDataSource.Factory()
            .setUserAgent(userAgent)
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(15000)
            .setReadTimeoutMs(15000)
        // A bare DefaultHttpDataSource.Factory only understands http(s) — this
        // was fine while this player only ever played live (network) streams,
        // but on-demand can now hand it a downloaded episode's local file://
        // Uri too, which DefaultHttpDataSource can't open at all. Wrapping it
        // in DefaultDataSource.Factory adds automatic scheme routing
        // (file/content/asset fall through to the platform's own DataSource,
        // http/https still go through our tuned httpFactory above).
        val dataSourceFactory = DefaultDataSource.Factory(context, httpFactory)
        val exo = ExoPlayer.Builder(context)
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
            .build()
        exo.setVideoSurfaceView(surfaceView)
        exo.playWhenReady = true
        exo.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                channel.invokeMethod(
                    "state",
                    when (state) {
                        Player.STATE_BUFFERING -> "buffering"
                        Player.STATE_READY -> "ready"
                        Player.STATE_ENDED -> "ended"
                        else -> "idle"
                    },
                )
            }

            override fun onPlayerError(error: PlaybackException) {
                // Media3 groups error codes by category in 1000-wide bands: 2000-2999
                // is the I/O family (network hiccups, timeouts, bad HTTP status) --
                // genuinely worth retrying. Everything else (parsing/decoder-init/DRM/
                // unspecified) is a permanent condition that retrying the identical
                // setSource() will never fix -- without this classification, a
                // malformed stream or missing codec/DRM support was retried forever
                // every 2s with no way to ever tell the user it would never succeed.
                val isTransient = error.errorCode in 2000..2999
                channel.invokeMethod(
                    "error",
                    mapOf("code" to error.errorCodeName, "transient" to isTransient),
                )
            }

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                // pixelWidthHeightRatio folds in non-square pixels so Flutter
                // gets the true DISPLAY aspect ratio, not the raw decoded
                // width/height -- same reasoning as AspectRatioFrameLayout's
                // own setAspectRatio(width * pixelWidthHeightRatio / height).
                if (videoSize.width > 0 && videoSize.height > 0) {
                    channel.invokeMethod(
                        "videoSize",
                        mapOf(
                            "aspectRatio" to
                                videoSize.width * videoSize.pixelWidthHeightRatio / videoSize.height,
                        ),
                    )
                }
            }
        })
        player = exo
    }

    private fun setSource(url: String, startPositionMs: Long = 0L) {
        val p = player ?: return
        // Downloaded on-demand episodes are handed in as a raw absolute
        // filesystem path (no scheme) — Uri.parse() on that yields a
        // schemeless Uri that Media3's DefaultDataSource doesn't reliably
        // resolve as a local file. Network URLs already carry a scheme
        // (http/https) and pass through Uri.parse() unchanged.
        val uri = if (url.startsWith("/")) Uri.fromFile(File(url)) else Uri.parse(url)
        // setMediaItem(item, startPositionMs) applies the start offset atomically
        // as part of loading the item — unlike a separate seekTo() issued after
        // prepare(), there's no window where playback briefly starts from 0
        // before our seek lands (the same class of race the mpv/media_kit
        // `Media.start` fix avoids on the on-demand media_kit path).
        if (startPositionMs > 0L) {
            p.setMediaItem(MediaItem.fromUri(uri), startPositionMs)
        } else {
            p.setMediaItem(MediaItem.fromUri(uri))
        }
        p.prepare()
        p.playWhenReady = true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setSource" -> {
                val startPositionMs = (call.argument<Number>("startPositionMs"))?.toLong() ?: 0L
                (call.argument<String>("url"))?.let { setSource(it, startPositionMs) }
                result.success(null)
            }
            "seekTo" -> {
                val positionMs = (call.argument<Number>("position"))?.toLong()
                if (positionMs != null) player?.seekTo(positionMs)
                result.success(null)
            }
            "play" -> { player?.play(); result.success(null) }
            "pause" -> { player?.pause(); result.success(null) }
            "stop" -> { player?.stop(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    override fun getView(): View = surfaceView

    override fun dispose() {
        positionLoopRunning = false
        positionHandler.removeCallbacks(positionRunnable)
        channel.setMethodCallHandler(null)
        player?.release()
        player = null
    }
}
