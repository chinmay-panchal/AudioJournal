import 'dart:async';
import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
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
