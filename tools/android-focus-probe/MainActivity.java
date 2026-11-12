package app.heming.focusprobe;

import android.app.Activity;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.widget.TextView;

/** A separate, silent test player for real audio-focus and playback callbacks. */
public final class MainActivity extends Activity {
    private static final String TAG = "HemingFocusProbe";
    private final Handler main = new Handler(Looper.getMainLooper());
    private AudioManager audio;
    private AudioFocusRequest request;
    private volatile boolean running;
    private boolean started;
    private boolean focusHeld;
    private String focusMode;
    private int seconds;
    private TextView status;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        audio = (AudioManager) getSystemService(AUDIO_SERVICE);
        focusMode = getIntent().getStringExtra("focus");
        if (focusMode == null) focusMode = "gain";
        seconds = getIntent().getIntExtra("seconds", 8);
        status = new TextView(this);
        status.setTextSize(20);
        status.setPadding(32, 96, 32, 32);
        status.setText("Heming audio-focus test\n\nMode: " + focusMode
                + "\nDuration: " + seconds + " seconds\n\nAll PCM samples are zero."
                + "\nNo recording, network or storage access.");
        setContentView(status);
        if (seconds < 1 || seconds > 300
                || !("gain".equals(focusMode) || "transient".equals(focusMode)
                || "duck".equals(focusMode))) {
            Log.e(TAG, "INVALID_ARGUMENTS focus=" + focusMode + " seconds=" + seconds);
            finish();
        }
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        // A target-35+ app must be the foreground app or an eligible foreground
        // service before requesting focus. This fixture only uses its Activity.
        if (focused && !started && !isFinishing()) {
            started = true;
            main.post(this::startProbe);
        }
    }

    private void startProbe() {
        if (isFinishing() || isDestroyed()) return;
        int gain = AudioManager.AUDIOFOCUS_GAIN;
        if ("transient".equals(focusMode)) gain = AudioManager.AUDIOFOCUS_GAIN_TRANSIENT;
        if ("duck".equals(focusMode)) gain = AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK;
        AudioAttributes attributes = new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build();
        request = new AudioFocusRequest.Builder(gain)
                .setAudioAttributes(attributes)
                .setOnAudioFocusChangeListener(change -> {
                    Log.i(TAG, "FOCUS_CHANGE value=" + change);
                    if (change == AudioManager.AUDIOFOCUS_LOSS
                            || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                        // A premature loss makes unexpected focus stealing
                        // visible instead of this fixture fighting it back.
                        running = false;
                    }
                }, main).build();
        int result = audio.requestAudioFocus(request);
        Log.i(TAG, "FOCUS_REQUEST mode=" + focusMode + " result=" + result);
        if (result != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            finish();
            return;
        }
        focusHeld = true;
        running = true;
        new Thread(() -> playSilence(attributes), "HemingFocusProbe-silence").start();
    }

    private void playSilence(AudioAttributes attributes) {
        AudioTrack track = null;
        long frames = 0;
        long began = SystemClock.elapsedRealtime();
        try {
            int minimum = AudioTrack.getMinBufferSize(48000,
                    AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT);
            if (minimum <= 0) throw new IllegalStateException("Unsupported PCM: " + minimum);
            track = new AudioTrack.Builder()
                    .setAudioAttributes(attributes)
                    .setAudioFormat(new AudioFormat.Builder().setSampleRate(48000)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .setBufferSizeInBytes(Math.max(minimum, 8192)).build();
            if (track.getState() != AudioTrack.STATE_INITIALIZED)
                throw new IllegalStateException("AudioTrack was not initialized");
            // Keep the track volume nonzero: newer Android versions can exclude
            // a volume-muted player from public playback configurations. The
            // sample array itself contains only zeroes, so there is no sound.
            track.setVolume(1.0f);
            short[] zeros = new short[960 * 2];
            track.play();
            began = SystemClock.elapsedRealtime();
            long deadline = began + seconds * 1000L;
            Log.i(TAG, "PLAY_START mode=" + focusMode + " seconds=" + seconds
                    + " session=" + track.getAudioSessionId());
            while (running && SystemClock.elapsedRealtime() < deadline) {
                int written = track.write(zeros, 0, zeros.length, AudioTrack.WRITE_BLOCKING);
                if (written < 0) throw new IllegalStateException("AudioTrack write: " + written);
                frames += written / 2;
            }
            Log.i(TAG, "PLAY_END elapsedMs=" + (SystemClock.elapsedRealtime() - began)
                    + " framesWritten=" + frames + " completed=" + running);
        } catch (RuntimeException failure) {
            Log.e(TAG, "PROBE_ERROR", failure);
        } finally {
            running = false;
            if (track != null) {
                try { track.stop(); } catch (IllegalStateException ignored) { }
                track.release();
            }
            main.post(() -> {
                releaseFocus();
                Log.i(TAG, "FINISHED");
                if (!isFinishing()) finish();
            });
        }
    }

    private void releaseFocus() {
        if (focusHeld && request != null) {
            int result = audio.abandonAudioFocusRequest(request);
            focusHeld = false;
            Log.i(TAG, "FOCUS_ABANDON result=" + result);
        }
    }

    @Override public void onDestroy() {
        running = false;
        releaseFocus();
        super.onDestroy();
    }
}
