package so.bruno.satellite

import android.content.Context
import android.media.AudioManager
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: AudioServiceActivity() {
    private val channelName = "so.bruno.satellite/device_volume"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val stream = AudioManager.STREAM_MUSIC
            val maxVolume = audioManager.getStreamMaxVolume(stream)

            when (call.method) {
                "setMusicVolume" -> {
                    val volume = (call.argument<Double>("volume") ?: 1.0).coerceIn(0.0, 1.0)
                    val index = (volume * maxVolume).toInt().coerceIn(0, maxVolume)
                    audioManager.setStreamVolume(stream, index, 0)
                    result.success(audioManager.getStreamVolume(stream).toDouble() / maxVolume.toDouble())
                }
                "getMusicVolume" -> {
                    result.success(audioManager.getStreamVolume(stream).toDouble() / maxVolume.toDouble())
                }
                else -> result.notImplemented()
            }
        }
    }
}
