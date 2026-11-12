package app.heming.heming

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

class MainActivity : FlutterActivity() {
    companion object {
        private const val ENGINE_ID = "heming-playback"
    }

    // The media service keeps the process alive while playing. Retain the same
    // Dart isolate, sockets and native engine when Android destroys the UI;
    // opening the activity again attaches to that running playback session.
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let { return it }
        return FlutterEngine(applicationContext, flutterShellArgs.toArray()).also {
            cache.put(ENGINE_ID, it)
        }
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false
}
