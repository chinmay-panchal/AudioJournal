import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/intl.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import '../models/recording.dart';
import '../constants.dart';
import 'background_service.dart';
import 'transcription_service.dart';

class RecorderService extends ChangeNotifier {
  static final RecorderService _instance = RecorderService._internal();
  factory RecorderService() => _instance;
  RecorderService._internal();

  bool _isRecording = false;
  Duration _duration = Duration.zero;
  String? _currentRecordingPath;
  List<Recording> _recordings = [];
  TranscriptionLanguage _selectedLanguage = TranscriptionLanguage.auto;

  bool get isRecording => _isRecording;
  Duration get duration => _duration;
  String? get currentRecordingPath => _currentRecordingPath;
  List<Recording> get recordings => _recordings;
  TranscriptionLanguage get selectedLanguage => _selectedLanguage;

  set selectedLanguage(TranscriptionLanguage lang) {
    _selectedLanguage = lang;
    notifyListeners();
  }

  // iOS-specific recording resources
  AudioRecorder? _iosRecorder;
  AudioPlayer? _silentPlayer;
  Stopwatch? _iosStopwatch;
  Timer? _iosTimer;

  Future<void> init() async {
    if (Platform.isAndroid) {
      await BackgroundService.init();
      FlutterForegroundTask.addTaskDataCallback(_onAndroidTaskData);
      await checkActiveAndroidService();
    }
    await loadRecordings();
  }

  void _onAndroidTaskData(Object data) {
    if (data is Map<String, dynamic>) {
      final status = data['status'];
      if (status == 'recording') {
        _isRecording = true;
        _duration = Duration(milliseconds: data['durationMs'] ?? 0);
        notifyListeners();
      } else if (status == 'stopped') {
        _isRecording = false;
        _duration = Duration(milliseconds: data['durationMs'] ?? 0);
        _currentRecordingPath = data['filePath'];
        notifyListeners();
        loadRecordings().then((_) {
          if (_currentRecordingPath != null) {
            _triggerTranscription(_currentRecordingPath!);
          }
        });
      } else if (status == 'error') {
        _isRecording = false;
        notifyListeners();
      }
    }
  }

  Future<void> checkActiveAndroidService() async {
    if (Platform.isAndroid) {
      final isRunning = await FlutterForegroundTask.isRunningService;
      if (isRunning) {
        _isRecording = true;
        final prefs = await SharedPreferences.getInstance();
        _currentRecordingPath = prefs.getString('recording_path');

        final startTimeMs = prefs.getInt('recording_start_time') ?? 0;
        if (startTimeMs > 0) {
          final startTime = DateTime.fromMillisecondsSinceEpoch(startTimeMs);
          _duration = DateTime.now().difference(startTime);
        }
        notifyListeners();
      }
    }
  }

  Future<bool> checkAndRequestPermissions() async {
    if (Platform.isAndroid) {
      final recordStatus = await Permission.microphone.request();
      final notificationStatus = await Permission.notification.request();
      return recordStatus.isGranted && notificationStatus.isGranted;
    } else if (Platform.isIOS) {
      final status = await Permission.microphone.status;
      debugPrint('Mic permission current status: $status');

      final result = await Permission.microphone.request();
      debugPrint('Mic permission after request: $result');

      return result.isGranted;
    }
    return false;
  }

  Future<Directory> get _recordingsDirectory async {
    final docDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${docDir.path}/recordings');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> startRecording() async {
    final hasPerm = await checkAndRequestPermissions();
    if (!hasPerm) {
      throw Exception('Microphone and/or notification permissions not granted');
    }

    if (_isRecording) return;

    final recordingsDir = await _recordingsDirectory;
    final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    // final tempFilePath = '${recordingsDir.path}/REC_${timestamp}_TEMP.m4a';
final tempFilePath = '${recordingsDir.path}/REC_${timestamp}_TEMP.wav';

    if (Platform.isAndroid) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        'recording_start_time',
        DateTime.now().millisecondsSinceEpoch,
      );
      _isRecording = true;
      _duration = Duration.zero;
      _currentRecordingPath = tempFilePath;
      notifyListeners();
      await BackgroundService.start(tempFilePath);
    } else if (Platform.isIOS) {
      _isRecording = true;
      _duration = Duration.zero;
      _currentRecordingPath = tempFilePath;
      notifyListeners();

      await _configureAudioSessionForIos();
      await _startSilentAudioIos();

      _iosRecorder = AudioRecorder();
// const config = RecordConfig(
//   encoder: AudioEncoder.aacLc,
//   sampleRate: 16000,  // was 44100
//   numChannels: 1,     // mono
//   bitRate: 32000,     // 32kbps — enough for speech
//   autoGain: true,
//   echoCancel: true,
//   noiseSuppress: true,
// );

const config = RecordConfig(
  encoder: AudioEncoder.wav, // record as WAV directly
  sampleRate: 16000,         // exactly what Whisper needs
  numChannels: 1,            // mono
  autoGain: true,
  echoCancel: true,
  noiseSuppress: true,
);


      await _iosRecorder!.start(config, path: tempFilePath);
      _iosStopwatch = Stopwatch()..start();

      _iosTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
        if (_iosStopwatch != null) {
          _duration = _iosStopwatch!.elapsed;
          notifyListeners();
        }
      });
    }
  }

  Future<void> stopRecording() async {
    if (!_isRecording) return;

    if (Platform.isAndroid) {
      await BackgroundService.stop();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('recording_start_time');
      // Android path: transcription is triggered inside _onAndroidTaskData
      // after the file is fully written and loadRecordings() completes.
    } else if (Platform.isIOS) {
      _iosTimer?.cancel();
      _iosTimer = null;
      _iosStopwatch?.stop();
      final elapsedMs = _iosStopwatch?.elapsedMilliseconds ?? 0;
      _iosStopwatch = null;

      await _stopSilentAudioIos();

      String? finalPath;
      try {
        final path = await _iosRecorder?.stop();
        if (path != null && File(path).existsSync()) {
          final file = File(path);
          if (path.contains('_TEMP')) {
            final newPath = path.replaceFirst('_TEMP', '_$elapsedMs');
            await file.rename(newPath);
            _currentRecordingPath = newPath;
            finalPath = newPath;
          } else {
            _currentRecordingPath = path;
            finalPath = path;
          }
        }
      } catch (e) {
        debugPrint('Error stopping iOS recorder: $e');
      } finally {
        await _iosRecorder?.dispose();
        _iosRecorder = null;
      }

      _isRecording = false;
      notifyListeners();
      await loadRecordings();

      if (finalPath != null) {
        _triggerTranscription(finalPath);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // File import
  // ---------------------------------------------------------------------------

  /// Opens the OS file picker, copies the chosen audio file to the recordings
  /// directory, adds it to the list, and triggers transcription.
  ///
  /// Returns `true` if a file was successfully imported, `false` if the user
  /// cancelled or an error occurred.
  Future<bool> importFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['m4a', 'mp3', 'wav', 'aac', 'mp4'],
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return false;

      final picked = result.files.first;
      final sourcePath = picked.path;
      if (sourcePath == null) return false;

      final recordingsDir = await _recordingsDirectory;
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final ext = sourcePath.split('.').last.toLowerCase();

      // Use 0 as duration placeholder — we can't know the duration without
      // probing, and the file will be renamed consistently with other recordings.
      final destPath = '${recordingsDir.path}/REC_${timestamp}_0.$ext';

      final sourceFile = File(sourcePath);
      await sourceFile.copy(destPath);

      await loadRecordings();
      _triggerTranscription(destPath);
      return true;
    } catch (e) {
      debugPrint('[RecorderService] importFile error: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Transcription orchestration
  // ---------------------------------------------------------------------------

  /// Starts a transcription job for [audioPath].
  ///
  /// Updates the in-memory recording and persists sidecar at each stage:
  /// idle → pending → done | failed.
  void _triggerTranscription(String audioPath) {
    _setTranscriptStatus(audioPath, TranscriptStatus.pending);

    final languageCode = _selectedLanguage.apiCode;

    TranscriptionService.transcribeFile(
      audioPath,
      languageCode: languageCode,
    ).then((text) {
      final sidecar = TranscriptionSidecar(
        status: TranscriptStatus.done,
        transcript: text,
        language: languageCode,
      );
      TranscriptionService.saveSidecar(audioPath, sidecar);
      _applyTranscriptSidecar(audioPath, sidecar);
    }).catchError((Object err) {
      debugPrint('[RecorderService] Transcription failed: $err');
      final sidecar = TranscriptionSidecar(
        status: TranscriptStatus.failed,
        language: languageCode,
      );
      TranscriptionService.saveSidecar(audioPath, sidecar);
      _applyTranscriptSidecar(audioPath, sidecar);
    });
  }

  /// Public method to retry a failed transcription.
  void retryTranscription(Recording recording) {
    _triggerTranscription(recording.path);
  }

  /// Sets the transcript status on the matching in-memory recording and notifies.
  void _setTranscriptStatus(String audioPath, TranscriptStatus status) {
    final rec = _findByPath(audioPath);
    if (rec != null) {
      rec.transcriptStatus = status;
      if (status == TranscriptStatus.pending) {
        rec.transcript = null;
      }
      notifyListeners();
    }

    // Persist pending/failed immediately so it survives a cold restart.
    if (status == TranscriptStatus.pending) {
      TranscriptionService.saveSidecar(
        audioPath,
        TranscriptionSidecar(status: status),
      );
    }
  }

  /// Applies a completed [TranscriptionSidecar] to the matching in-memory recording.
  void _applyTranscriptSidecar(String audioPath, TranscriptionSidecar sidecar) {
    final rec = _findByPath(audioPath);
    if (rec != null) {
      rec.applyTranscript(sidecar);
      notifyListeners();
    }
  }

  Recording? _findByPath(String path) {
    try {
      return _recordings.firstWhere((r) => r.path == path);
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Recordings list management
  // ---------------------------------------------------------------------------

  Future<void> loadRecordings() async {
    try {
      final recordingsDir = await _recordingsDirectory;
      final List<FileSystemEntity> files = recordingsDir.listSync();

      final List<Recording> fetched = [];
      for (var file in files) {
        // Skip JSON sidecar files — only load audio files.
        if (file is File &&
            !file.path.endsWith('.json') &&
            _isAudioFile(file.path)) {
          final rec = Recording.fromFile(file);
          if (rec != null) {
            // Load transcript sidecar
            final sidecar = await TranscriptionService.loadSidecar(file.path);
            rec.applyTranscript(sidecar);
            fetched.add(rec);
          }
        }
      }

      fetched.sort((a, b) => b.date.compareTo(a.date));
      _recordings = fetched;
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading recordings: $e');
    }
  }

  bool _isAudioFile(String path) {
    const audioExtensions = ['m4a', 'mp3', 'wav', 'aac', 'mp4'];
    final ext = path.split('.').last.toLowerCase();
    return audioExtensions.contains(ext);
  }

  Future<void> deleteRecording(Recording recording) async {
    try {
      final file = File(recording.path);
      if (await file.exists()) {
        await file.delete();
      }
      // Also delete JSON sidecar
      await TranscriptionService.deleteSidecar(recording.path);
      await loadRecordings();
    } catch (e) {
      debugPrint('Error deleting recording: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // iOS-specific Audio Session config
  // ---------------------------------------------------------------------------

  Future<void> _configureAudioSessionForIos() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.none, // defaultToSpeaker false
      avAudioSessionMode: AVAudioSessionMode.defaultMode,
      avAudioSessionRouteSharingPolicy:
          AVAudioSessionRouteSharingPolicy.defaultPolicy,
      avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
    ));
  }

  // iOS-specific silent audio keepalive
  Future<String> _createSilentWavFile() async {
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/silence.wav');
    if (await file.exists()) {
      return file.path;
    }

    final header = BytesBuilder();
    header.add(utf8.encode('RIFF'));
    final subChunk2Size = 16000; // 8000 samples * 2 bytes/sample
    final chunkSize = 36 + subChunk2Size;

    final b = ByteData(4);
    b.setUint32(0, chunkSize, Endian.little);
    header.add(b.buffer.asUint8List());

    header.add(utf8.encode('WAVE'));
    header.add(utf8.encode('fmt '));
    header.add([16, 0, 0, 0]);
    header.add([1, 0]); // MonoPCM
    header.add([1, 0]); // Mono

    final rateData = ByteData(4);
    rateData.setUint32(0, 8000, Endian.little);
    header.add(rateData.buffer.asUint8List());

    final byteRateData = ByteData(4);
    byteRateData.setUint32(0, 16000, Endian.little);
    header.add(byteRateData.buffer.asUint8List());

    header.add([2, 0]);
    header.add([16, 0]);

    header.add(utf8.encode('data'));

    final sizeData = ByteData(4);
    sizeData.setUint32(0, subChunk2Size, Endian.little);
    header.add(sizeData.buffer.asUint8List());

    final silentBytes = Uint8List(subChunk2Size);
    header.add(silentBytes);

    await file.writeAsBytes(header.toBytes());
    return file.path;
  }

  Future<void> _startSilentAudioIos() async {
    _silentPlayer = AudioPlayer();
    try {
      final wavPath = await _createSilentWavFile();
      await _silentPlayer!.setFilePath(wavPath);
      await _silentPlayer!.setLoopMode(LoopMode.one);
      await _silentPlayer!.setVolume(0.0);
      unawaited(_silentPlayer!.play());
    } catch (e) {
      debugPrint('Error starting silent audio: $e');
    }
  }

  Future<void> _stopSilentAudioIos() async {
    try {
      await _silentPlayer?.stop();
      await _silentPlayer?.dispose();
      _silentPlayer = null;
    } catch (e) {
      debugPrint('Error stopping silent audio: $e');
    }
  }

  @override
  void dispose() {
    _iosTimer?.cancel();
    _silentPlayer?.dispose();
    _iosRecorder?.dispose();
    super.dispose();
  }
}
