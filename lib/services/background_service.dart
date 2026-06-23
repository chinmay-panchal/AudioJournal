import 'dart:async';
import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(AudioRecordingTaskHandler());
}

class AudioRecordingTaskHandler extends TaskHandler {
  AudioRecorder? _audioRecorder;
  Stopwatch? _stopwatch;
  String? _filePath;
  bool _isRecording = false;
  int _lastChunkRolledIndex = 0; // how many 30-min boundaries already rolled
  int _chunkFileIndex = 0;       // monotonic counter for chunk file names

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final prefs = await SharedPreferences.getInstance();
    _filePath = prefs.getString('recording_path');
    
    if (_filePath == null) {
      FlutterForegroundTask.stopService();
      return;
    }

    _audioRecorder = AudioRecorder();
    _stopwatch = Stopwatch();

    try {
      const config = RecordConfig(
        encoder: AudioEncoder.wav,  // changed from aacLc
        sampleRate: 16000,          // changed from 44100
        numChannels: 1,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
      );

      await _audioRecorder!.start(config, path: _filePath!);
      _stopwatch!.start();
      _isRecording = true;

      // Initial update to notification
      FlutterForegroundTask.updateService(
        notificationTitle: 'Recording in progress...',
        notificationText: '00:00:00',
      );
      
      FlutterForegroundTask.sendDataToMain({
        'status': 'recording',
        'durationMs': 0,
      });
    } catch (e) {
      FlutterForegroundTask.sendDataToMain({
        'status': 'error',
        'error': e.toString(),
      });
      FlutterForegroundTask.stopService();
    }
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    if (_isRecording && _stopwatch != null) {
      final elapsedMs = _stopwatch!.elapsedMilliseconds;
      final duration = Duration(milliseconds: elapsedMs);

      // ── Detect 30-minute chunk boundary ──────────────────────────────────
      const chunkIntervalMs = 30 * 60 * 1000;
      final chunksDue = elapsedMs ~/ chunkIntervalMs;
      if (chunksDue > _lastChunkRolledIndex) {
        // Update index synchronously (before any await) so that if onRepeatEvent
        // fires again before the roll finishes, we don't double-roll.
        _lastChunkRolledIndex = chunksDue;
        unawaited(_rollChunkAndRestart());
      }

      final hours = duration.inHours.toString().padLeft(2, '0');
      final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
      final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
      final timeStr = '$hours:$minutes:$seconds';

      FlutterForegroundTask.updateService(
        notificationTitle: 'Recording in progress...',
        notificationText: timeStr,
      );

      FlutterForegroundTask.sendDataToMain({
        'status': 'recording',
        'durationMs': elapsedMs,
      });
    }
  }

  /// Silently rolls a 30-min chunk on Android:
  /// stops the recorder → copies bytes to temp file → signals main isolate
  /// → restarts immediately at the same path. The UI never sees a stop.
  Future<void> _rollChunkAndRestart() async {
    if (!_isRecording || _audioRecorder == null || _filePath == null) return;
    try {
      // 1. Stop current segment
      final completedPath = await _audioRecorder!.stop();

      // 2. Copy segment bytes to a temp chunk file
      String? chunkPath;
      if (completedPath != null && File(completedPath).existsSync()) {
        final tmpDir = await getTemporaryDirectory();
        final ext = completedPath.split('.').last;
        chunkPath =
            '${tmpDir.path}/android_live_chunk_${_chunkFileIndex}_'
            '${DateTime.now().millisecondsSinceEpoch}.$ext';
        await File(completedPath).copy(chunkPath);
        _chunkFileIndex++;
      }

      // 3. Signal main isolate — it will transcribe + upload this chunk
      if (chunkPath != null) {
        FlutterForegroundTask.sendDataToMain({
          'status': 'chunk_ready',
          'chunkPath': chunkPath,
        });
      }

      // 4. Restart recorder immediately at same path (overwrites previous segment)
      const config = RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
      );
      await _audioRecorder!.start(config, path: _filePath!);
    } catch (e) {
      FlutterForegroundTask.sendDataToMain({
        'status': 'chunk_roll_error',
        'error': e.toString(),
      });
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _stopRecording();
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map<String, dynamic> && data['action'] == 'stop') {
      FlutterForegroundTask.stopService();
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'btn_stop') {
      FlutterForegroundTask.stopService();
    }
  }

  Future<void> _stopRecording() async {
    if (_isRecording) {
      _isRecording = false;
      _stopwatch?.stop();
      
      try {
        final path = await _audioRecorder?.stop();
        final elapsedMs = _stopwatch?.elapsedMilliseconds ?? 0;
        
        if (path != null && File(path).existsSync()) {
          final file = File(path);
          if (path.contains('_TEMP')) {
            final newPath = path.replaceFirst('_TEMP', '_$elapsedMs');
            await file.rename(newPath);
            
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('recording_path', newPath);

            FlutterForegroundTask.sendDataToMain({
              'status': 'stopped',
              'filePath': newPath,
              'durationMs': elapsedMs,
            });
          } else {
            FlutterForegroundTask.sendDataToMain({
              'status': 'stopped',
              'filePath': path,
              'durationMs': elapsedMs,
            });
          }
        } else {
          FlutterForegroundTask.sendDataToMain({
            'status': 'stopped',
            'filePath': path,
            'durationMs': elapsedMs,
          });
        }
      } catch (e) {
        FlutterForegroundTask.sendDataToMain({
          'status': 'error',
          'error': e.toString(),
        });
      } finally {
        _audioRecorder?.dispose();
        _audioRecorder = null;
      }
    }
  }
}

class BackgroundService {
  static Future<void> init() async {
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'voice_recorder_channel',
        channelName: 'Voice Recorder Service',
        channelDescription: 'Keeps audio recording active in the background.',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(1000),
        autoRunOnBoot: false,
        allowWakeLock: true,
      ),
    );
  }

  static Future<bool> start(String tempPath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('recording_path', tempPath);

    final result = await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'Recording in progress...',
      notificationText: '00:00:00',
      callback: startCallback,
      notificationButtons: [
        const NotificationButton(id: 'btn_stop', text: 'Stop'),
      ],
      serviceTypes: [
        ForegroundServiceTypes.microphone,
      ],
    );
    return result is ServiceRequestSuccess;
  }

  static Future<bool> stop() async {
    FlutterForegroundTask.sendDataToTask({'action': 'stop'});
    final result = await FlutterForegroundTask.stopService();
    return result is ServiceRequestSuccess;
  }
}
