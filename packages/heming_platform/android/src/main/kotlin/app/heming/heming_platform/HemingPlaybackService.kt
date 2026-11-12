package app.heming.heming_platform

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock

/** A display-only snapshot. It never creates a player or changes its timeline. */
private data class MediaPlaybackInfo(
    val taskId: String?,
    val title: String,
    val phase: String,
    val durationMs: Long,
    val positionMs: Long,
    val deviceCount: Int,
    val isMaster: Boolean,
    val outputSuppressed: Boolean,
) {
    val phaseText: String get() = when (phase) {
        "playing" -> "正在播放"
        "scheduled" -> "即将同步播放"
        else -> "正在准备"
    }
    val roleText: String get() = if (isMaster) "本机主控" else "跟随主控"
    val statusText: String get() = "$phaseText · $deviceCount 台设备"
    val detailText: String get() = if (outputSuppressed) "$roleText · 本机暂时让声" else roleText
    val progressText: String get() = "${formatTime(positionMs)} / ${formatTime(durationMs)}"

    // Progress changes update PlaybackState, not the track's metadata bitmap/text.
    val metadataKey: List<Any?> get() = listOf(taskId, title, phase, durationMs,
        deviceCount, isMaster, outputSuppressed)

    companion object {
        val preparing = MediaPlaybackInfo(null, "和鸣 · 同步播放", "preparing", 0, 0, 1, false, false)

        fun from(arguments: Map<*, *>): MediaPlaybackInfo? {
            if (arguments["active"] != true) return null
            val duration = (arguments["durationMs"] as? Number)?.toLong()?.coerceAtLeast(0) ?: 0
            val phase = (arguments["phase"] as? String)?.takeIf {
                it == "playing" || it == "scheduled" || it == "preparing"
            } ?: "preparing"
            val position = if (phase == "playing") {
                ((arguments["positionMs"] as? Number)?.toLong() ?: 0).coerceIn(0, duration)
            } else 0
            return MediaPlaybackInfo(
                arguments["taskId"] as? String,
                (arguments["title"] as? String)?.trim()?.takeIf { it.isNotEmpty() }
                    ?.take(512) ?: "和鸣 · 同步播放",
                phase, duration, position,
                ((arguments["deviceCount"] as? Number)?.toInt() ?: 1).coerceIn(1, 6),
                arguments["isMaster"] == true,
                arguments["outputSuppressed"] == true,
            )
        }

        private fun formatTime(milliseconds: Long): String {
            val seconds = milliseconds / 1000
            val minutes = seconds / 60
            return "${minutes.toString().padStart(2, '0')}:${(seconds % 60).toString().padStart(2, '0')}"
        }
    }
}

/** Hosts the platform lifetime of the existing native/Dart playback engine.
 *
 * This service deliberately does not create a second player or restart a killed
 * playback task. The application owns the cached Flutter engine; this service
 * owns its visible media notification and playback-only power/network locks.
 */
class HemingPlaybackService : Service() {
    private var mediaSession: MediaSession? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var foreground = false
    private var serviceEpoch = -1L
    private var metadataKey: List<Any?>? = null
    private var notificationChannelReady = false

    private fun createMediaSession(epoch: Long) {
        mediaSession?.run { isActive = false; release() }
        metadataKey = null
        val session = MediaSession(this, "heming-playback")
        mediaSession = session
        session.apply {
            setCallback(object : MediaSession.Callback() {
                override fun onStop() = requestStop(epoch)
                // Hardware pause is an explicit stop, never a paused old task.
                override fun onPause() = requestStop(epoch)
                override fun onCustomAction(action: String, extras: Bundle?) {
                    if (action == "$ACTION_STOP:$epoch") requestStop(epoch)
                }
            })
            launchPendingIntent()?.let { setSessionActivity(it) }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            val requestedEpoch = intent.getLongExtra(EXTRA_EPOCH, -1L)
            if (wanted && requestedEpoch == activationEpoch && serviceEpoch == requestedEpoch &&
                readyInstance === this) {
                requestStop(requestedEpoch)
            } else if (readyInstance !== this) {
                // A stale notification may instantiate a service after the old
                // session ended. Do not leave that orphan's MediaSession alive.
                stopSelf(startId)
            }
            return START_NOT_STICKY
        }
        val epoch = intent?.getLongExtra(EXTRA_EPOCH, -1L) ?: -1L
        if (!wanted || epoch != activationEpoch) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        try {
            if (mediaSession == null || serviceEpoch != epoch) createMediaSession(epoch)
            serviceEpoch = epoch
            val info = currentPlayback() ?: MediaPlaybackInfo.preparing
            updateMediaSession(info)
            val notification = createNotification(info)
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            foreground = true
            acquireLocks()
            readyInstance = this
            completeStarts(epoch, null)
        } catch (error: Exception) {
            stopSelf(startId)
            failStart(epoch, error)
        }
        return START_NOT_STICKY
    }

    private fun currentPlayback(): MediaPlaybackInfo? =
        if (playbackInfoEpoch == serviceEpoch) playbackInfo else null

    private fun launchPendingIntent(): PendingIntent? {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        return PendingIntent.getActivity(this, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun updateMediaSession(info: MediaPlaybackInfo?) {
        val session = mediaSession ?: return
        if (info == null) {
            session.setPlaybackState(PlaybackState.Builder()
                .setState(PlaybackState.STATE_STOPPED, 0, 0f, SystemClock.elapsedRealtime()).build())
            session.setMetadata(null)
            session.isActive = false
            metadataKey = null
            return
        }
        if (metadataKey != info.metadataKey) {
            session.setMetadata(MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_MEDIA_ID, info.taskId)
                .putString(MediaMetadata.METADATA_KEY_TITLE, info.title)
                .putString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE, info.title)
                .putString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE, info.statusText)
                .putString(MediaMetadata.METADATA_KEY_DISPLAY_DESCRIPTION, info.detailText)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, info.durationMs)
                .build())
            metadataKey = info.metadataKey
        }
        val state = when (info.phase) {
            "playing" -> PlaybackState.STATE_PLAYING
            "scheduled" -> PlaybackState.STATE_CONNECTING
            else -> PlaybackState.STATE_BUFFERING
        }
        session.setPlaybackState(PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_STOP)
            // Android 13+ does not map ACTION_STOP into its system button slots.
            .addCustomAction("$ACTION_STOP:$serviceEpoch", "停止", R.drawable.ic_heming_stop)
            .setState(state, info.positionMs, if (info.phase == "playing") 1f else 0f,
                SystemClock.elapsedRealtime())
            .build())
        session.isActive = true
    }

    private fun refreshPlayback() {
        // Metadata updates never start or resurrect a foreground service. An old
        // instance also cannot replace a newer activation's notification.
        if (!foreground || !wanted || serviceEpoch != activationEpoch || readyInstance !== this) return
        val info = currentPlayback()
        updateMediaSession(info)
        // Service shutdown is owned by the existing playback lifetime, not by
        // this display-only channel. Clear content during its short stop window.
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID,
            createNotification(info))
    }

    private fun createNotification(info: MediaPlaybackInfo?): Notification {
        if (!notificationChannelReady) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel(
                CHANNEL_ID, "音乐播放", NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "播放期间保持后台音频和设备连接"
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
            })
            notificationChannelReady = true
        }
        val immutable = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val stopIntent = PendingIntent.getService(this, (serviceEpoch and 0x7fffffffL).toInt(),
            Intent(this, HemingPlaybackService::class.java).setAction(ACTION_STOP)
                .putExtra(EXTRA_EPOCH, serviceEpoch), immutable)
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_heming_playback)
            .setContentTitle(info?.title ?: "和鸣")
            .setContentText(info?.let { "${it.progressText} · ${it.detailText}" } ?: "播放已结束")
            .setSubText(info?.statusText ?: "待命")
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(
                android.graphics.drawable.Icon.createWithResource(this, R.drawable.ic_heming_stop),
                "停止", stopIntent).build())
            .setStyle(Notification.MediaStyle()
                .setMediaSession(mediaSession!!.sessionToken)
                .setShowActionsInCompactView(0))
        launchPendingIntent()?.let { notification.setContentIntent(it) }
        return notification.build()
    }

    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        if (wakeLock == null) {
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "heming:playback")
                .apply { setReferenceCounted(false) }
        }
        if (wakeLock?.isHeld != true) wakeLock?.acquire()
        if (wifiLock == null) {
            wifiLock = (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
                .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "heming:playback")
                .apply { setReferenceCounted(false) }
        }
        if (wifiLock?.isHeld != true) wifiLock?.acquire()
    }

    private fun requestStop(expectedEpoch: Long) {
        if (!wanted || expectedEpoch != serviceEpoch || serviceEpoch != activationEpoch ||
            readyInstance !== this) return
        val listener = stopRequestListener
        if (listener != null) listener()
        else stop(applicationContext)
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        mediaSession?.run { isActive = false; release() }
        mediaSession = null
        if (foreground) stopForeground(STOP_FOREGROUND_REMOVE)
        foreground = false
        if (readyInstance === this) readyInstance = null
        if (wanted && serviceEpoch == activationEpoch) {
            wanted = false
            ++activationEpoch
            if (playbackInfoEpoch == serviceEpoch) playbackInfo = null
            stopRequestListener?.invoke()
            completeStarts(serviceEpoch, IllegalStateException("后台播放服务已停止"))
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val CHANNEL_ID = "heming_playback"
        private const val NOTIFICATION_ID = 19786
        private const val ACTION_STOP = "app.heming.heming_platform.STOP_PLAYBACK"
        private const val EXTRA_EPOCH = "playback_epoch"
        private val main = Handler(Looper.getMainLooper())
        private var wanted = false
        private var activationEpoch = 0L
        private var readyInstance: HemingPlaybackService? = null
        private var playbackInfo: MediaPlaybackInfo? = null
        private var playbackInfoEpoch = -1L
        private data class PendingStart(val epoch: Long, val completion: (Exception?) -> Unit)
        private val pending = mutableMapOf<Int, PendingStart>()
        private var nextRequest = 0
        var stopRequestListener: (() -> Unit)? = null

        fun updatePlayback(arguments: Map<*, *>) {
            check(Looper.myLooper() == Looper.getMainLooper())
            playbackInfo = MediaPlaybackInfo.from(arguments)
            // Dart sends its first preparing snapshot before requesting the
            // service. Bind that snapshot to the upcoming activation, so an old
            // service's delayed destruction cannot erase the new track.
            playbackInfoEpoch = if (wanted) activationEpoch else activationEpoch + 1
            readyInstance?.refreshPlayback()
        }

        /** Completes only after startForeground, before Dart requests focus. */
        fun start(context: Context, completion: (Exception?) -> Unit) {
            check(Looper.myLooper() == Looper.getMainLooper())
            if (wanted && readyInstance?.serviceEpoch == activationEpoch) {
                completion(null)
                return
            }
            val alreadyStarting = wanted && pending.values.any { it.epoch == activationEpoch }
            if (!wanted) { wanted = true; ++activationEpoch }
            val epoch = activationEpoch
            val request = ++nextRequest
            pending[request] = PendingStart(epoch, completion)
            try {
                if (!alreadyStarting) {
                    context.startForegroundService(Intent(context, HemingPlaybackService::class.java)
                        .putExtra(EXTRA_EPOCH, epoch))
                }
                main.postDelayed({
                    val timedOut = pending.remove(request)
                    timedOut?.completion?.invoke(IllegalStateException("启动后台播放服务超时"))
                    if (timedOut != null && wanted && epoch == activationEpoch &&
                        pending.values.none { it.epoch == epoch } && readyInstance?.serviceEpoch != epoch) {
                        stop(context)
                    }
                }, 5000)
            } catch (error: Exception) {
                failStart(epoch, error)
            }
        }

        private fun completeStarts(epoch: Long, error: Exception?) {
            val callbacks = pending.filterValues { it.epoch == epoch }
            callbacks.keys.forEach { pending.remove(it) }
            callbacks.values.forEach { it.completion(error) }
        }

        private fun failStart(epoch: Long, error: Exception) {
            if (wanted && activationEpoch == epoch) { wanted = false; ++activationEpoch }
            if (playbackInfoEpoch == epoch) playbackInfo = null
            completeStarts(epoch, error)
        }

        fun stop(context: Context) {
            check(Looper.myLooper() == Looper.getMainLooper())
            val epoch = activationEpoch
            // releaseAudioFocus and setPlaybackActive(false) can both stop the
            // same lifetime. A redundant stop must not invalidate a preparing
            // snapshot already reserved for the next activation.
            if (wanted) ++activationEpoch
            wanted = false
            if (playbackInfoEpoch <= epoch) playbackInfo = null
            // Deactivate immediately; onDestroy may be delayed behind a new
            // start, which must receive a fresh MediaSession and callbacks.
            readyInstance?.takeIf { it.serviceEpoch == epoch }?.updateMediaSession(null)
            context.stopService(Intent(context, HemingPlaybackService::class.java))
            completeStarts(epoch, IllegalStateException("播放已结束"))
        }
    }
}
