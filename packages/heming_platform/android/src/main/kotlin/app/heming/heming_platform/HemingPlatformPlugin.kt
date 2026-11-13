package app.heming.heming_platform

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.*
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class HemingPlatformPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private var mediaScanner: HemingMediaScanner? = null
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private lateinit var audio: AudioManager
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var attached = false
    private var active = false
    private var playbackGeneration = 0
    private var focus: AudioFocusRequest? = null
    private var focusGeneration = 0
    private var focusChange = AudioManager.AUDIOFOCUS_GAIN
    private var focusEventGeneration = 0
    private var previewFocus: AudioFocusRequest? = null
    private var previewFocusGeneration = 0
    private var previewFocusEventGeneration = 0
    private var previewFocusChange = AudioManager.AUDIOFOCUS_GAIN
    private var outputGeneration = 0
    private var outputBefore: Set<AudioPlaybackConfiguration>? = null
    private var outputBeforeExternal: Set<AudioPlaybackConfiguration>? = null
    private var outputPreviousOwn: AudioPlaybackConfiguration? = null
    private var outputPrepared = false
    private var outputLearning = false
    private var outputFocusGeneration = 0
    private var outputFocusEventGeneration = 0
    private var ownOutput: AudioPlaybackConfiguration? = null
    private var externalPlaybackObserved = false
    private var playbackMonitoring = false
    private var focusRecovery: Runnable? = null
    private var automaticRecoveryBlocked = false
    private var recoveryVerificationActive = false
    private var restorePending = false
    private var multicast: WifiManager.MulticastLock? = null
    private var outputIds = emptySet<Int>()
    @Volatile private var cancelled = AtomicBoolean(false)

    private fun emit(name: String) {
        main.post { if (attached) channel.invokeMethod("onInterruption", name) }
    }
    private fun emitFocus(name: String) {
        val generation = focusGeneration
        val event = focusEventGeneration
        val playback = playbackGeneration
        main.post {
            if (attached && active && focus != null && generation == focusGeneration &&
                event == focusEventGeneration && playback == playbackGeneration) {
                channel.invokeMethod("onInterruption", name)
            }
        }
    }
    private fun emitStopRequest() {
        val playback = playbackGeneration
        main.post {
            if (attached && active && playback == playbackGeneration) {
                channel.invokeMethod("onInterruption", "stopRequested")
            }
        }
    }
    private fun emitPreviewFocus(name: String) {
        val generation = previewFocusGeneration
        val event = previewFocusEventGeneration
        main.post {
            if (attached && !active && focus == null && previewFocus != null &&
                generation == previewFocusGeneration && event == previewFocusEventGeneration) {
                channel.invokeMethod("onInterruption", name)
            }
        }
    }
    private fun onPreviewFocusChanged(change: Int, generation: Int) {
        if (!attached || active || focus != null || previewFocus == null ||
            generation != previewFocusGeneration) return
        ++previewFocusEventGeneration
        previewFocusChange = change
        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> emitPreviewFocus("previewFocusGained")
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> emitPreviewFocus("previewFocusDucked")
            AudioManager.AUDIOFOCUS_LOSS, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT ->
                emitPreviewFocus("previewFocusLost")
        }
    }
    private fun requestPreviewFocus(): Boolean {
        // Preview is only a foreground activity feature. Never borrow the
        // group's FGS/focus lease or its permanent-loss recovery mechanism.
        if (!attached || active || focus != null) return false
        if (previewFocus != null && previewFocusChange == AudioManager.AUDIOFOCUS_GAIN) return true
        releasePreviewFocus()
        val generation = ++previewFocusGeneration
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setAcceptsDelayedFocusGain(false)
            // Ensure a callback lets the preview controller lower its native
            // output instead of combining OS ducking with our own gain.
            .setWillPauseWhenDucked(true)
            .setOnAudioFocusChangeListener({ change -> onPreviewFocusChanged(change, generation) }, main)
            .build()
        previewFocus = request
        val granted = try {
            audio.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } catch (_: RuntimeException) { false }
        if (!granted) {
            releasePreviewFocus()
        } else {
            previewFocusChange = AudioManager.AUDIOFOCUS_GAIN
            ++previewFocusEventGeneration
            emitPreviewFocus("previewFocusGained")
        }
        return granted
    }
    private fun releasePreviewFocus() {
        ++previewFocusGeneration
        ++previewFocusEventGeneration
        val previous = previewFocus
        previewFocus = null
        previewFocusChange = AudioManager.AUDIOFOCUS_GAIN
        previous?.let { audio.abandonAudioFocusRequest(it) }
    }
    private fun onFocusChanged(change: Int, generation: Int) {
        if (!attached || !active || generation != focusGeneration || focus == null) return
        if (change == AudioManager.AUDIOFOCUS_GAIN && automaticRecoveryBlocked) return
        if (change == AudioManager.AUDIOFOCUS_GAIN && recoveryVerificationActive) return
        cancelFocusRecovery()
        restorePending = false
        ++focusEventGeneration
        focusChange = change
        externalPlaybackObserved = false
        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> emitFocus("audioFocusGained")
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> emitFocus("audioFocusDucked")
            AudioManager.AUDIOFOCUS_LOSS, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> emitFocus("audioFocusLost")
        }
        if (change == AudioManager.AUDIOFOCUS_LOSS) observePlayback()
    }
    private val playbackCallback = object : AudioManager.AudioPlaybackCallback() {
        override fun onPlaybackConfigChanged(configs: MutableList<AudioPlaybackConfiguration>?) {
            observePlayback(configs?.toSet())
        }
    }

    private fun playbackSnapshot(): Set<AudioPlaybackConfiguration>? = try {
        if (playbackMonitoring) audio.activePlaybackConfigurations.toSet() else null
    } catch (_: Exception) { null }

    private fun cancelFocusRecovery() {
        focusRecovery?.let { main.removeCallbacks(it) }
        focusRecovery = null
        recoveryVerificationActive = false
    }

    private fun currentPlayers(snapshot: Set<AudioPlaybackConfiguration>): Set<AudioPlaybackConfiguration> =
        outputPreviousOwn?.let { snapshot - it } ?: snapshot

    private fun observePlayback(snapshot: Set<AudioPlaybackConfiguration>? = playbackSnapshot()) {
        if (!active || focus == null || !outputPrepared || outputLearning || automaticRecoveryBlocked ||
            recoveryVerificationActive || focusChange != AudioManager.AUDIOFOCUS_LOSS) return
        val own = ownOutput
        // Newer Android versions omit a volume-shaper-muted player from public
        // active configurations. Keep the identity learned before focus loss;
        // absence from this list does not mean our native stream has stopped.
        if (snapshot == null || audio.mode != AudioManager.MODE_NORMAL) {
            cancelFocusRecovery()
            return
        }
        val visible = currentPlayers(snapshot)
        val external = if (own == null) visible else visible - own
        if (external.isNotEmpty()) {
            // Without an identified own player, a visible configuration might
            // still be our native stream. Preserve earlier positive evidence,
            // but never manufacture evidence of another app from that list.
            if (own != null) externalPlaybackObserved = true
            cancelFocusRecovery()
            return
        }
        // A permanent LOSS is not followed by GAIN on every device. Only try
        // once after actually seeing another player start and then become idle;
        // never race a player which acquired focus but is still loading audio.
        if (!externalPlaybackObserved || focusRecovery != null) return
        val generation = focusGeneration
        val output = outputGeneration
        val pending = Runnable {
            focusRecovery = null
            if (!attached || !active || generation != focusGeneration || output != outputGeneration ||
                focusChange != AudioManager.AUDIOFOCUS_LOSS || audio.mode != AudioManager.MODE_NORMAL) return@Runnable
            val latest = playbackSnapshot()?.let { currentPlayers(it) } ?: return@Runnable
            if (ownOutput != own || (if (own == null) latest else latest - own).isNotEmpty()) return@Runnable
            externalPlaybackObserved = false
            val request = focus ?: return@Runnable
            // There is no public atomic "request only if idle" API. The fresh
            // snapshot and quiet period make this conservative; no retry loop
            // is used if Android refuses the request.
            recoveryVerificationActive = true
            val granted = try {
                audio.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            } catch (_: RuntimeException) { false }
            if (granted) {
                focusChange = AudioManager.AUDIOFOCUS_GAIN
                ++focusEventGeneration
                restorePending = true
                verifyRecoveredOutput(own, generation, output)
            } else {
                recoveryVerificationActive = false
            }
        }
        focusRecovery = pending
        main.postDelayed(pending, 700)
    }

    private fun blockAutomaticRecovery() {
        cancelFocusRecovery()
        restorePending = false
        automaticRecoveryBlocked = true
        focusChange = AudioManager.AUDIOFOCUS_LOSS
        ++focusEventGeneration
        focus?.let { audio.abandonAudioFocusRequest(it) }
        emitFocus("audioFocusLost")
    }

    private fun finishPendingRestore() {
        if (!restorePending || focusChange != AudioManager.AUDIOFOCUS_GAIN || !active) return
        val current = playbackSnapshot()?.let { currentPlayers(it) }
        val own = ownOutput
        if (current == null || (if (own == null) current else current - own).isNotEmpty()) {
            // A late snapshot change must not strand us with focus held while
            // verification blocks every future GAIN and no timer remains.
            blockAutomaticRecovery()
            return
        }
        restorePending = false
        recoveryVerificationActive = false
        emitFocus("audioFocusGained")
    }

    private fun verifyRecoveredOutput(previousOwn: AudioPlaybackConfiguration?, generation: Int, output: Int) {
        var candidate: AudioPlaybackConfiguration? = null
        var stableSamples = 0
        var attempts = 0
        val eventGeneration = focusEventGeneration
        fun sample() {
            focusRecovery = null
            if (!attached || !active || generation != focusGeneration || output != outputGeneration ||
                eventGeneration != focusEventGeneration || !restorePending ||
                focusChange != AudioManager.AUDIOFOCUS_GAIN) return
            val current = playbackSnapshot()?.let { currentPlayers(it) }
            if (current == null || audio.mode != AudioManager.MODE_NORMAL ||
                (previousOwn != null && (current - previousOwn).isNotEmpty()) ||
                (previousOwn == null && current.size > 1)) {
                blockAutomaticRecovery()
                return
            }
            val next = if (previousOwn != null) previousOwn else current.singleOrNull()
            if (next == candidate) stableSamples++ else { candidate = next; stableSamples = 1 }
            attempts++
            if (stableSamples >= 3) {
                // A system-muted native player may only reappear after focus
                // returns. With no previous identity, only one stable player
                // following an empty snapshot is inferred as our native output.
                // Public anonymized APIs cannot make that attribution atomic;
                // multiple players or another focus event abort the inference.
                ownOutput = next
                finishPendingRestore()
            } else if (attempts >= 6) {
                blockAutomaticRecovery()
            } else {
                val pending = Runnable { sample() }
                focusRecovery = pending
                main.postDelayed(pending, 100)
            }
        }
        sample()
    }

    private fun beginOutputPreparation(): Int {
        cancelFocusRecovery()
        ++outputGeneration
        val previousOwn = ownOutput
        outputPreviousOwn = previousOwn
        ownOutput = null
        outputPrepared = false
        outputLearning = true
        outputFocusGeneration = focusGeneration
        outputFocusEventGeneration = focusEventGeneration
        outputBefore = if (active && (focusChange == AudioManager.AUDIOFOCUS_GAIN ||
            focusChange == AudioManager.AUDIOFOCUS_LOSS)) playbackSnapshot() else null
        outputBeforeExternal = outputBefore?.let { if (previousOwn == null) it else it - previousOwn }
        if (focusChange == AudioManager.AUDIOFOCUS_LOSS && previousOwn != null &&
            outputBeforeExternal?.isNotEmpty() == true) {
            externalPlaybackObserved = true
        }
        return outputGeneration
    }

    private fun endOutputPreparation(token: Int, success: Boolean, result: MethodChannel.Result) {
        val before = outputBefore
        if (token == outputGeneration) outputPrepared = success && active
        if (token != outputGeneration || !success || before == null || !active ||
            outputFocusGeneration != focusGeneration || outputFocusEventGeneration != focusEventGeneration ||
            (focusChange != AudioManager.AUDIOFOCUS_GAIN && focusChange != AudioManager.AUDIOFOCUS_LOSS)) {
            if (token == outputGeneration) {
                outputBefore = null
                outputLearning = false
                observePlayback()
            }
            result.success(null)
            return
        }
        val generation = focusGeneration
        val eventGeneration = focusEventGeneration
        val initialFocus = focusChange
        val externalBefore = outputBeforeExternal.orEmpty()
        val previousOwn = outputPreviousOwn
        var candidate: AudioPlaybackConfiguration? = null
        var stableSamples = 0
        var attempts = 0
        fun sample() {
            if (!attached || !active || token != outputGeneration || generation != focusGeneration ||
                eventGeneration != focusEventGeneration ||
                focusChange != initialFocus) {
                if (token == outputGeneration) { outputLearning = false; observePlayback() }
                result.success(null)
                return
            }
            val current = playbackSnapshot()
            val added = current?.minus(before)
            val next = added?.singleOrNull()
            // AudioService may publish the retired stream's release after the
            // native close returned. It was already identified as ours and
            // must not be mistaken for an external player during this window.
            val remaining = current?.let {
                val withoutNext = if (next == null) it else it - next
                if (previousOwn == null) withoutNext else withoutNext - previousOwn
            }
            val externalStable = initialFocus == AudioManager.AUDIOFOCUS_GAIN ||
                (remaining != null && remaining == externalBefore)
            if (!externalStable) {
                ownOutput = null
                outputBefore = null
                outputLearning = false
                observePlayback(current)
                result.success(null)
                return
            }
            if (next != null && next == candidate) stableSamples++
            else { candidate = next; stableSamples = if (next == null) 0 else 1 }
            attempts++
            if (stableSamples >= 3) {
                // Public configurations are anonymized. Equality preserves the
                // player identity, but ambiguous changes are never guessed.
                ownOutput = candidate
                outputBefore = null
                outputLearning = false
                finishPendingRestore()
                observePlayback(current)
                result.success(null)
            } else if (attempts >= 6 || (added?.size ?: 0) > 1) {
                ownOutput = null
                outputBefore = null
                outputLearning = false
                finishPendingRestore()
                observePlayback(current)
                result.success(null)
            } else main.postDelayed({ sample() }, 100)
        }
        sample()
    }

    private fun requestInitialFocus(): Boolean {
        releasePreviewFocus()
        if (focus != null) return true
        val generation = ++focusGeneration
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setAcceptsDelayedFocusGain(false).setWillPauseWhenDucked(false)
            .setOnAudioFocusChangeListener({ change -> onFocusChanged(change, generation) }, main).build()
        focus = request
        val granted = audio.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        if (!granted) {
            focus = null
            ++focusGeneration
            audio.abandonAudioFocusRequest(request)
        } else {
            focusChange = AudioManager.AUDIOFOCUS_GAIN
            ++focusEventGeneration
            emitFocus("audioFocusGained")
        }
        return granted
    }
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, intent: Intent?) {
            when (intent?.action) {
                AudioManager.ACTION_AUDIO_BECOMING_NOISY -> emit("outputChanged")
            }
        }
    }
    private val devices = object : AudioDeviceCallback() {
        private fun check() {
            val next = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map { it.id }.toSet()
            if (next != outputIds) {
                outputIds = next
                emit("outputChanged")
            }
        }
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) = check()
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) = check()
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        mediaScanner = HemingMediaScanner(context, binding.binaryMessenger)
        audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        channel = MethodChannel(binding.binaryMessenger, "heming_platform")
        channel.setMethodCallHandler(this)
        attached = true
        val wifi = context.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicast = wifi.createMulticastLock("heming-discovery").apply {
            setReferenceCounted(false); acquire()
        }
        val filter = IntentFilter().apply {
            addAction(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        }
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else @Suppress("DEPRECATION") context.registerReceiver(receiver, filter)
        outputIds = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map { it.id }.toSet()
        audio.registerAudioDeviceCallback(devices, main)
        try {
            audio.registerAudioPlaybackCallback(playbackCallback, main)
            playbackMonitoring = true
        } catch (_: Exception) {
            // Playback remains available; explicit restore and normal GAIN
            // callbacks still work when an OEM does not expose monitoring.
        }
        HemingPlaybackService.stopRequestListener = { emitStopRequest() }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) { mediaScanner?.attachActivity(binding) }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { mediaScanner?.attachActivity(binding) }
    override fun onDetachedFromActivityForConfigChanges() { mediaScanner?.detachActivity(true) }
    override fun onDetachedFromActivity() { mediaScanner?.detachActivity(false) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> result.success(null)
            "updateMediaPlayback" -> {
                val arguments = call.arguments as? Map<*, *>
                if (arguments == null) {
                    result.error("media_status", "播放状态参数无效", null)
                } else {
                    try {
                        HemingPlaybackService.updatePlayback(arguments)
                        result.success(null)
                    } catch (error: Exception) {
                        // A system media surface must not interrupt audio.
                        result.error("media_status", error.message ?: "无法更新播放状态", null)
                    }
                }
            }
            "acquireAudioFocus" -> {
                // A new track within the same playback task must not steal
                // focus back from another app that the user is listening to.
                result.success(requestInitialFocus())
            }
            "acquirePreviewAudioFocus" -> result.success(requestPreviewFocus())
            "releasePreviewAudioFocus" -> { releasePreviewFocus(); result.success(null) }
            "resumeLocalAudioFocus" -> {
                if (!active) { result.success(false); return }
                // This path is an explicit user action, unlike idle detection.
                cancelFocusRecovery()
                restorePending = false
                automaticRecoveryBlocked = false
                ++focusGeneration
                focus?.let { audio.abandonAudioFocusRequest(it) }
                focus = null
                result.success(requestInitialFocus())
            }
            "beginNativeOutputPreparation" -> result.success(beginOutputPreparation())
            "endNativeOutputPreparation" -> endOutputPreparation(
                call.argument<Number>("token")?.toInt() ?: outputGeneration,
                call.argument<Boolean>("success") == true, result)
            "releaseAudioFocus" -> { releaseFocus(); stopPlaybackService(); result.success(null) }
            "setPlaybackActive" -> {
                val requested = call.argument<Boolean>("active") == true
                if (!requested) {
                    stopPlaybackService()
                    result.success(null)
                } else {
                    releasePreviewFocus()
                    if (!active) { active = true; ++playbackGeneration }
                    val generation = playbackGeneration
                    HemingPlaybackService.start(context) { error ->
                        if (generation != playbackGeneration || !attached || !active) {
                            result.error("playback_service", "播放已结束", null)
                        } else if (error == null) result.success(null)
                        else {
                            active = false
                            ++playbackGeneration
                            val message = if (Build.VERSION.SDK_INT >= 31 &&
                                error is android.app.ForegroundServiceStartNotAllowedException) {
                                "系统暂不允许从后台开始播放，请返回和鸣后重试"
                            } else error.message ?: "播放已结束"
                            result.error("playback_service", message, null)
                        }
                    }
                }
            }
            "cancelMediaExtraction" -> { cancelled.set(true); result.success(null) }
            "inspectMedia", "extractAudio" -> {
                val token = AtomicBoolean(false)
                if (call.method == "extractAudio") cancelled = token
                worker.execute {
                    try {
                        val value = if (call.method == "inspectMedia") inspect(requireNotNull(call.argument<String>("path")))
                        else { extract(requireNotNull(call.argument<String>("input")),
                            requireNotNull(call.argument<String>("output")), token); null }
                        main.post { if (attached) result.success(value) }
                    } catch (error: Exception) {
                        main.post { if (attached) result.error("media_error", error.message ?: "无法读取音轨", null) }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun audioTrack(extractor: MediaExtractor): Pair<Int, MediaFormat> {
        for (i in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(i)
            if (format.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) return Pair(i, format)
        }
        throw IllegalArgumentException("文件中没有可读取的音轨")
    }
    private fun inspect(path: String): Map<String, Any> {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            val (_, format) = audioTrack(extractor)
            return mapOf("codec" to (format.getString(MediaFormat.KEY_MIME) ?: "unknown"),
                "sampleRate" to format.getInteger(MediaFormat.KEY_SAMPLE_RATE),
                "channels" to format.getInteger(MediaFormat.KEY_CHANNEL_COUNT),
                "bitsPerSample" to 0,
                "durationSeconds" to (if (format.containsKey(MediaFormat.KEY_DURATION))
                    format.getLong(MediaFormat.KEY_DURATION) / 1_000_000.0 else 0.0))
        } finally { extractor.release() }
    }
    private fun extract(input: String, output: String, cancel: AtomicBoolean) {
        require(File(input).canonicalPath != File(output).canonicalPath) { "转换不得覆盖源文件" }
        val extractor = MediaExtractor()
        var decoder: MediaCodec? = null
        var started = false
        try {
            extractor.setDataSource(input)
            val (track, format) = audioTrack(extractor)
            extractor.selectTrack(track)
            decoder = MediaCodec.createDecoderByType(requireNotNull(format.getString(MediaFormat.KEY_MIME)))
            decoder.configure(format, null, null, 0)
            decoder.start(); started = true
            RandomAccessFile(output, "rw").use { file ->
                file.setLength(0); file.write(ByteArray(44))
                var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                var encoding = AudioFormat.ENCODING_PCM_16BIT
                var bytes = 0L
                var inputEnded = false
                var outputEnded = false
                var lastProgress = System.nanoTime()
                val info = MediaCodec.BufferInfo()
                while (!outputEnded) {
                    check(!cancel.get()) { "转换已取消" }
                    check(System.nanoTime() - lastProgress < 30_000_000_000L) { "系统解码器超时" }
                    if (!inputEnded) {
                        val index = decoder.dequeueInputBuffer(10_000)
                        if (index >= 0) {
                            val buffer = requireNotNull(decoder.getInputBuffer(index))
                            val count = extractor.readSampleData(buffer, 0)
                            if (count < 0) {
                                decoder.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputEnded = true
                            } else {
                                decoder.queueInputBuffer(index, 0, count, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }
                    val index = decoder.dequeueOutputBuffer(info, 10_000)
                    if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        val changed = decoder.outputFormat
                        val rate = changed.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        val count = changed.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        check(bytes == 0L || (rate == sampleRate && count == channels)) { "音轨中途改变格式" }
                        sampleRate = rate; channels = count
                        encoding = if (changed.containsKey(MediaFormat.KEY_PCM_ENCODING)) changed.getInteger(MediaFormat.KEY_PCM_ENCODING)
                            else AudioFormat.ENCODING_PCM_16BIT
                        check(encoding == AudioFormat.ENCODING_PCM_16BIT || encoding == AudioFormat.ENCODING_PCM_FLOAT) {
                            "系统解码器未返回受支持的 PCM" }
                    } else if (index >= 0) {
                        try {
                            if (info.size > 0 && (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                                val buffer = requireNotNull(decoder.getOutputBuffer(index))
                                buffer.position(info.offset); buffer.limit(info.offset + info.size)
                                val pcm = if (encoding == AudioFormat.ENCODING_PCM_FLOAT) {
                                    buffer.order(ByteOrder.LITTLE_ENDIAN)
                                    val data = ByteBuffer.allocate(info.size / 2).order(ByteOrder.LITTLE_ENDIAN)
                                    while (buffer.remaining() >= 4) data.putShort((buffer.float.coerceIn(-1f, 1f) * 32767).toInt().toShort())
                                    data.array()
                                } else ByteArray(info.size).also { buffer.get(it) }
                                check(bytes + pcm.size < 0xffffffffL - 44) { "音轨超过临时 WAV 的 4GB 限制" }
                                file.write(pcm); bytes += pcm.size
                                lastProgress = System.nanoTime()
                            }
                            outputEnded = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                        } finally { decoder.releaseOutputBuffer(index, false) }
                    }
                }
                check(bytes > 0) { "音轨没有可解码的数据" }
                val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
                header.put("RIFF".toByteArray()).putInt((bytes + 36).toInt()).put("WAVEfmt ".toByteArray())
                    .putInt(16).putShort(1).putShort(channels.toShort()).putInt(sampleRate)
                    .putInt(sampleRate * channels * 2).putShort((channels * 2).toShort()).putShort(16)
                    .put("data".toByteArray()).putInt(bytes.toInt())
                file.seek(0); file.write(header.array())
            }
        } catch (error: Exception) { File(output).delete(); throw error }
        finally { if (started) try { decoder?.stop() } catch (_: Exception) {}; decoder?.release(); extractor.release() }
    }
    private fun releaseFocus() {
        cancelFocusRecovery()
        ++focusGeneration
        ++outputGeneration
        outputBefore = null
        outputBeforeExternal = null
        outputPreviousOwn = null
        outputPrepared = false
        outputLearning = false
        ownOutput = null
        externalPlaybackObserved = false
        automaticRecoveryBlocked = false
        restorePending = false
        val previous = focus
        focus = null
        focusChange = AudioManager.AUDIOFOCUS_GAIN
        previous?.let { audio.abandonAudioFocusRequest(it) }
    }
    private fun stopPlaybackService() {
        active = false
        ++playbackGeneration
        HemingPlaybackService.stop(context)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        mediaScanner?.dispose(); mediaScanner = null
        attached = false; cancelled.set(true); worker.shutdownNow(); releaseFocus()
        releasePreviewFocus()
        stopPlaybackService()
        HemingPlaybackService.stopRequestListener = null
        multicast?.let { if (it.isHeld) it.release() }; multicast = null
        audio.unregisterAudioDeviceCallback(devices); context.unregisterReceiver(receiver)
        if (playbackMonitoring) audio.unregisterAudioPlaybackCallback(playbackCallback)
        playbackMonitoring = false
        channel.setMethodCallHandler(null)
    }
}

