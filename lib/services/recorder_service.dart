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
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';

enum ProcessingState { idle, processing, tooShort, serverError }

class RecorderService extends ChangeNotifier {
  static final RecorderService _instance = RecorderService._internal();
  factory RecorderService() => _instance;
  RecorderService._internal();

  bool _isRecording = false;
  Duration _duration = Duration.zero;
  String? _currentRecordingPath;
  List<Recording> _recordings = [];
  TranscriptionLanguage _selectedLanguage = TranscriptionLanguage.auto;
  ProcessingState _processingState = ProcessingState.idle;
  String? _lastErrorMessage;

  bool get isRecording => _isRecording;
  Duration get duration => _duration;
  String? get currentRecordingPath => _currentRecordingPath;
  List<Recording> get recordings => _recordings;
  TranscriptionLanguage get selectedLanguage => _selectedLanguage;
  String? get lastErrorMessage => _lastErrorMessage;
  ProcessingState get processingState => _processingState;

  void clearError() {
    _lastErrorMessage = null;
    _processingState = ProcessingState.idle;
    notifyListeners();
  }

  set selectedLanguage(TranscriptionLanguage lang) {
    _selectedLanguage = lang;
    notifyListeners();
  }

  // iOS-specific recording resources
  AudioRecorder? _iosRecorder;
  AudioPlayer? _silentPlayer;
  Stopwatch? _iosStopwatch;
  Timer? _iosTimer;

  // ── Live-chunking state ─────────────────────────────────────────────
  Timer? _chunkRollTimer;                    // iOS: fires every 30 min
  Completer<void>? _chunkRollCompleter;      // guards concurrent roll + stop
  int _chunkIndex = 0;                       // intermediate chunks rolled
  bool _hasLiveChunking = false;             // true once first chunk is rolled
  Future<String?>? _lastTranscriptIdFuture;  // sequential-upload gate
  final List<String> _liveChunkTranscripts = []; // per-chunk texts (in order)

  Future<void> init() async {
    if (Platform.isAndroid) {
      await BackgroundService.init();
      FlutterForegroundTask.addTaskDataCallback(_onAndroidTaskData);
      await checkActiveAndroidService();
    }
    await loadRecordings();
    // Any recording still marked 'pending' after startup was interrupted by a
    // crash or force-quit. Reset it to 'failed' so the user can tap Retry.
    await _resetStalePendingRecordings();
    // Any recording still in 'idle' state was saved by the background service
    // while the app was closed and never started processing. Mark it failed
    // (Draft) so the user can retry. This must only run at startup — NOT on
    // every loadRecordings() call, or new recordings get wrongly Draft-ed.
    await _resetIdleRecordings();
  }

  void _onAndroidTaskData(Object data) {
    if (data is Map<String, dynamic>) {
      final status = data['status'];
      if (status == 'recording') {
        _isRecording = true;
        _duration = Duration(milliseconds: data['durationMs'] ?? 0);
        notifyListeners();
      } else if (status == 'chunk_ready') {
        // A 30-min chunk has been silently rolled by the background service.
        // Transcribe it immediately; POST to backend waits for the previous
        // chunk's transcript_id via the Completer chain.
        final chunkPath = data['chunkPath'] as String?;
        if (chunkPath != null) {
          _hasLiveChunking = true;
          final slotIndex = _liveChunkTranscripts.length;
          _liveChunkTranscripts.add('');
          final previousFuture = _lastTranscriptIdFuture;
          final completer = Completer<String?>();
          _lastTranscriptIdFuture = completer.future;
          _processLiveChunk(
            chunkPath: chunkPath,
            previousTranscriptIdFuture: previousFuture,
            isLastChunk: false,
            completer: completer,
            slotIndex: slotIndex,
          );
        }
      } else if (status == 'stopped') {
        _isRecording = false;
        final finalDurationMs = data['durationMs'] as int? ?? 0;
        _currentRecordingPath = data['filePath'];
        _duration = Duration.zero; // ← reset timer display to 00:00:00
        notifyListeners();
        loadRecordings().then((_) {
          if (_currentRecordingPath != null) {
            if (_hasLiveChunking) {
              // Live-chunked: treat the final segment as the last chunk.
              _hasLiveChunking = false;
              final slotIndex = _liveChunkTranscripts.length;
              _liveChunkTranscripts.add('');
              final previousFuture = _lastTranscriptIdFuture;
              final completer = Completer<String?>();
              _lastTranscriptIdFuture = null;
              _processLiveChunk(
                chunkPath: _currentRecordingPath!,
                previousTranscriptIdFuture: previousFuture,
                isLastChunk: true,
                completer: completer,
                slotIndex: slotIndex,
                originalRecordingPath: _currentRecordingPath!,
                totalDurationMs: finalDurationMs,
              );
            } else {
              TranscriptionService.loadSidecar(_currentRecordingPath!).then((
                sidecar,
              ) {
                if (sidecar.status == TranscriptStatus.idle) {
                  _triggerTranscription(_currentRecordingPath!);
                }
              });
            }
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

      if (status.isPermanentlyDenied || status.isDenied) {
        await openAppSettings();
        return false;
      }

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
      // Reset live-chunking state for this Android session.
      _chunkIndex = 0;
      _hasLiveChunking = false;
      _lastTranscriptIdFuture = null;
      _liveChunkTranscripts.clear();
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
        sampleRate: 16000, // exactly what Whisper needs
        numChannels: 1, // mono
        autoGain: true,
        echoCancel: true,
        noiseSuppress: true,
      );

      await _iosRecorder!.start(config, path: tempFilePath);
      _iosStopwatch = Stopwatch()..start();

      // Reset and arm live-chunking state for this iOS session.
      _chunkIndex = 0;
      _hasLiveChunking = false;
      _lastTranscriptIdFuture = null;
      _liveChunkTranscripts.clear();
      // Schedule a silent chunk roll every 30 minutes.
      _chunkRollTimer = Timer.periodic(const Duration(minutes: 30), (_) {
        _rollChunkIOS();
      });

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
      // Cancel the chunk-roll timer synchronously first so no new roll can
      // start after this point.
      _chunkRollTimer?.cancel();
      _chunkRollTimer = null;

      _iosTimer?.cancel();
      _iosTimer = null;
      _iosStopwatch?.stop();
      final elapsedMs = _iosStopwatch?.elapsedMilliseconds ?? 0;
      _iosStopwatch = null;

      // Wait for any in-progress chunk roll to finish before touching the recorder.
      if (_chunkRollCompleter != null) {
        await _chunkRollCompleter!.future.catchError((_) {});
      }

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
      _duration = Duration.zero; // ← reset timer display to 00:00:00
      notifyListeners();
      await loadRecordings();

      if (finalPath != null) {
        if (_hasLiveChunking) {
          // Live-chunked recording: process the final segment and request summary.
          _hasLiveChunking = false;
          final slotIndex = _liveChunkTranscripts.length;
          _liveChunkTranscripts.add('');
          final previousFuture = _lastTranscriptIdFuture;
          final completer = Completer<String?>();
          _lastTranscriptIdFuture = null;
          _processLiveChunk(
            chunkPath: finalPath,
            previousTranscriptIdFuture: previousFuture,
            isLastChunk: true,
            completer: completer,
            slotIndex: slotIndex,
            originalRecordingPath: finalPath,
            totalDurationMs: elapsedMs,
          );
        } else {
          // Standard path: recording < 30 min, use existing pipeline.
          _triggerTranscription(finalPath);
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // iOS Live-chunking helpers
  // ---------------------------------------------------------------------------

  /// Rolls the current iOS recording segment into a temp chunk file and
  /// immediately restarts the recorder at the same path — all without changing
  /// [_isRecording] or the UI timer. Called by the 30-min [_chunkRollTimer].
  Future<void> _rollChunkIOS() async {
    if (_iosRecorder == null || _currentRecordingPath == null) return;

    _chunkRollCompleter = Completer<void>();
    _hasLiveChunking = true;

    // Reserve a slot so transcript order is maintained even if Gemini calls
    // for different chunks resolve out of order.
    final slotIndex = _liveChunkTranscripts.length;
    _liveChunkTranscripts.add('');

    try {
      // ── 1. Stop current segment (silent — no UI state change) ─────────
      String? completedPath;
      try {
        completedPath = await _iosRecorder!.stop();
      } catch (e) {
        debugPrint('[RecorderService] _rollChunkIOS: stop error: $e');
      }

      // ── 2. Copy completed segment to a temp chunk file ───────────────
      String? chunkPath;
      if (completedPath != null && File(completedPath).existsSync()) {
        try {
          final tmpDir = await getTemporaryDirectory();
          final ext = completedPath.split('.').last;
          chunkPath =
              '${tmpDir.path}/live_chunk_${_chunkIndex}_'
              '${DateTime.now().millisecondsSinceEpoch}.$ext';
          await File(completedPath).copy(chunkPath);
          _chunkIndex++;
          debugPrint('[RecorderService] Rolled chunk \${_chunkIndex - 1} → $chunkPath');
        } catch (e) {
          debugPrint('[RecorderService] _rollChunkIOS: copy error: $e');
        }
      }

      // ── 3. Restart recorder immediately at same path (overwrites) ─────
      try {
        const config = RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
        );
        await _iosRecorder!.start(config, path: _currentRecordingPath!);
        debugPrint('[RecorderService] Recorder restarted at $_currentRecordingPath');
      } catch (e) {
        debugPrint('[RecorderService] _rollChunkIOS: restart error: $e');
      }

      // ── 4. Kick off background transcription for this chunk ──────────
      if (chunkPath != null) {
        final previousFuture = _lastTranscriptIdFuture;
        final completer = Completer<String?>();
        _lastTranscriptIdFuture = completer.future;
        _processLiveChunk(
          chunkPath: chunkPath,
          previousTranscriptIdFuture: previousFuture,
          isLastChunk: false,
          completer: completer,
          slotIndex: slotIndex,
        );
      }
    } finally {
      _chunkRollCompleter!.complete();
      _chunkRollCompleter = null;
    }
  }

  /// Processes a single live chunk through the full pipeline:
  ///
  ///   [silence removal] → [Gemini transcription]  (both start immediately)
  ///                               ↓
  ///                    [await previous transcript_id]  (waits only if needed)
  ///                               ↓
  ///                    [POST /transcribe/simple]  (sequential per chunk)
  ///
  /// [completer] is resolved with the returned transcript_id so the next
  /// chunk can await it before its own POST — preventing out-of-order appends.
  void _processLiveChunk({
    required String chunkPath,
    required Future<String?>? previousTranscriptIdFuture,
    required bool isLastChunk,
    required Completer<String?> completer,
    required int slotIndex,
    String? originalRecordingPath, // sidecar target — only for the last chunk
    int? totalDurationMs,
  }) {
    final languageCode = _selectedLanguage.apiCode;

    if (isLastChunk && originalRecordingPath != null) {
      _setTranscriptStatus(originalRecordingPath, TranscriptStatus.pending);
    }

    () async {
      try {
        // ── Phase 1: Silence removal (starts immediately) ────────────────
        final cleanPath = await removeSilence(chunkPath);

        // ── Phase 2: Gemini transcription (does NOT wait for transcript_id) ──
        String transcriptText = '';
        try {
          transcriptText = await TranscriptionService.transcribeChunkWithGemini(
            cleanPath,
            languageCode: languageCode,
          );
          _liveChunkTranscripts[slotIndex] = transcriptText;
          debugPrint(
            '[RecorderService] Chunk $slotIndex transcribed: '
            '${transcriptText.length} chars',
          );
        } finally {
          // Clean up silence-removed file (keep original if paths differ)
          if (cleanPath != chunkPath) {
            try { File(cleanPath).deleteSync(); } catch (_) {}
          }
        }

        // ── Phase 3: Await previous chunk's transcript_id ───────────────
        // Gemini is already done; this wait is typically zero or very short.
        String? transcriptId;
        if (previousTranscriptIdFuture != null) {
          try {
            transcriptId = await previousTranscriptIdFuture;
          } catch (e) {
            debugPrint(
              '[RecorderService] Previous chunk upload failed, '
              'continuing without transcript_id: $e',
            );
          }
        }

        // ── Phase 4: POST to backend ───────────────────────────────
        final filename = chunkPath.split('/').last;
        final result = await TranscriptionService.uploadChunkToBackend(
          transcriptText: transcriptText,
          audioFilename: filename,
          transcriptId: transcriptId,
          isLastChunk: isLastChunk,
        );
        debugPrint(
          '[RecorderService] Chunk $slotIndex uploaded → id: ${result.transcriptId}',
        );
        completer.complete(result.transcriptId);

        // ── Phase 5: Apply result to UI (last chunk only) ──────────────
        if (isLastChunk && originalRecordingPath != null) {
          final fullTranscript = _liveChunkTranscripts.join('\n\n').trim();
          final rec = _findByPath(originalRecordingPath);
          final sidecar = TranscriptionSidecar(
            status: TranscriptStatus.done,
            transcript: fullTranscript,
            summary: result.summaryText ?? '',
            title: result.summaryTitle,
            language: languageCode,
            durationMs: totalDurationMs ?? rec?.duration.inMilliseconds,
          );
          await TranscriptionService.saveSidecar(originalRecordingPath, sidecar);
          _applyTranscriptSidecar(originalRecordingPath, sidecar);

          // Auto-rename from AI title
          if (result.summaryTitle != null && result.summaryTitle!.isNotEmpty) {
            final renameTarget = result.summaryTitle!
                .replaceAll(RegExp(r'[^\w\s]'), '')
                .trim()
                .replaceAll(RegExp(r'\s+'), '_');
            if (renameTarget.isNotEmpty) {
              final r = _findByPath(originalRecordingPath);
              if (r != null) renameRecording(r, renameTarget);
            }
          }
          _liveChunkTranscripts.clear();
        }

        // Clean up temp chunk file (never delete the final recording file)
        if (chunkPath != originalRecordingPath) {
          try {
            final f = File(chunkPath);
            if (await f.exists()) await f.delete();
          } catch (e) {
            debugPrint('[RecorderService] Error deleting chunk temp file: $e');
          }
        }
      } catch (e) {
        debugPrint(
          '[RecorderService] _processLiveChunk error (slot $slotIndex): $e',
        );
        if (!completer.isCompleted) completer.completeError(e);

        if (isLastChunk && originalRecordingPath != null) {
          final rec = _findByPath(originalRecordingPath);
          final sidecar = TranscriptionSidecar(
            status: TranscriptStatus.failed,
            language: languageCode,
            durationMs: totalDurationMs ?? rec?.duration.inMilliseconds,
          );
          await TranscriptionService.saveSidecar(originalRecordingPath, sidecar);
          _applyTranscriptSidecar(originalRecordingPath, sidecar);
          _liveChunkTranscripts.clear();
        }
      }
    }();
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

      // Probe the actual duration using just_audio
      int durationMs = 0;
      try {
        final probe = AudioPlayer();
        final duration = await probe.setFilePath(sourcePath);
        durationMs = duration?.inMilliseconds ?? 0;
        await probe.dispose();
      } catch (_) {
        durationMs = 0;
      }

      final recordingsDir = await _recordingsDirectory;
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final ext = sourcePath.split('.').last.toLowerCase();

      final destPath =
          '${recordingsDir.path}/REC_${timestamp}_${durationMs}.$ext';

      final sourceFile = File(sourcePath);
      await sourceFile.copy(destPath);

      await loadRecordings();
      _triggerTranscription(destPath, isImported: true);
      return true;
    } catch (e) {
      debugPrint('[RecorderService] importFile error: $e');
      return false;
    }
  } // ---------------------------------------------------------------------------
  // Transcription orchestration
  // ---------------------------------------------------------------------------

  /// Runs FFmpeg to remove silence and very low volume periods from the audio file.
  Future<String> removeSilence(String inputPath) async {
    final completer = Completer<String>();

    final dotIndex = inputPath.lastIndexOf('.');
    final outputPath = dotIndex != -1
        ? '${inputPath.substring(0, dotIndex)}_clean${inputPath.substring(dotIndex)}'
        : '${inputPath}_clean';

    final arguments = [
      '-y',
      '-i',
      inputPath,
      '-af',
      'afftdn=nf=-25,silenceremove=start_periods=1:start_duration=0.3:start_threshold=-35dB:stop_periods=-1:stop_duration=0.5:stop_threshold=-35dB',
      outputPath,
    ];

    try {
      await FFmpegKit.executeWithArgumentsAsync(arguments, (session) async {
        final returnCode = await session.getReturnCode();
        if (ReturnCode.isSuccess(returnCode)) {
          final inputSize = File(inputPath).existsSync()
              ? File(inputPath).lengthSync()
              : 0;
          final outputSize = File(outputPath).existsSync()
              ? File(outputPath).lengthSync()
              : 0;
          if (inputSize > 0) {
            final reduction = ((1 - outputSize / inputSize) * 100)
                .toStringAsFixed(1);
            debugPrint(
              '[RecorderService] Silence removed: ${(inputSize / 1024).toStringAsFixed(1)}KB → ${(outputSize / 1024).toStringAsFixed(1)}KB ($reduction% reduced)',
            );
          }
          completer.complete(outputPath);
        } else {
          final failCode = returnCode?.getValue();
          debugPrint(
            '[RecorderService] FFmpeg failed with return code: $failCode',
          );
          completer.complete(inputPath);
        }
      });
    } catch (e) {
      debugPrint('[RecorderService] FFmpeg execution exception: $e');
      completer.complete(inputPath);
    }

    return completer.future;
  }

  /// Starts a transcription job for [audioPath].
  ///
  /// Updates the in-memory recording and persists sidecar at each stage:
  /// idle → pending → done | failed.
  void _triggerTranscription(String audioPath, {bool isImported = false}) {
    if (!File(audioPath).existsSync()) {
      debugPrint('[RecorderService] File missing at start of transcription. Likely deleted for being too short.');
      _lastErrorMessage = 'tooShort';
      _processingState = ProcessingState.tooShort;
      notifyListeners();
      return;
    }

    _setTranscriptStatus(audioPath, TranscriptStatus.pending);
    _processingState = ProcessingState.processing;
    notifyListeners();

    final languageCode = _selectedLanguage.apiCode;

    removeSilence(audioPath).then((cleanAudioPath) async {
      final cleanFile = File(cleanAudioPath);
      if (!cleanFile.existsSync()) {
        debugPrint(
          '[RecorderService] Clean file missing, skipping transcription.',
        );
        _lastErrorMessage = null;
        _processingState = ProcessingState.serverError;
        _setTranscriptStatus(audioPath, TranscriptStatus.failed);
        notifyListeners();
        if (cleanAudioPath != audioPath) {
          try { cleanFile.deleteSync(); } catch (_) {}
        }
        return;
      }

      int cleanDurationMs = 0;
      try {
        final probe = AudioPlayer();
        final dur = await probe.setFilePath(cleanAudioPath);
        cleanDurationMs = dur?.inMilliseconds ?? 0;
        await probe.dispose();
      } catch (e) {
        debugPrint('[RecorderService] Error probing clean file duration: $e');
      }

      if (cleanDurationMs < 10000) {
        debugPrint(
          '[RecorderService] Cleaned file too short (${cleanDurationMs}ms), skipping transcription and deleting.',
        );
        if (cleanAudioPath != audioPath && cleanFile.existsSync()) {
          cleanFile.deleteSync();
        }
        
        final rec = _findByPath(audioPath);
        if (rec != null) {
          // It's invalid/too short, so just delete it entirely.
          await deleteRecording(rec);
        }

        // Signal UI: recording was too short — no backend call will be made.
        _lastErrorMessage = 'tooShort';
        _processingState = ProcessingState.tooShort;
        notifyListeners();
        return;
      }

      TranscriptionService.transcribeFile(
            cleanAudioPath,
            languageCode: languageCode,
            isImported: isImported,
          )
          .then((result) {
            final rec = _findByPath(audioPath);
            final sidecar = TranscriptionSidecar(
              status: TranscriptStatus.done,
              transcript: result.transcript,
              summary: result.summary,
              title: result.title.isNotEmpty ? result.title : null,
              language: result.language.isNotEmpty
                  ? result.language
                  : languageCode,
              durationMs: rec?.duration.inMilliseconds,
            );
            TranscriptionService.saveSidecar(audioPath, sidecar);
            _applyTranscriptSidecar(audioPath, sidecar);

            String? renameTarget;
            if (result.title.isNotEmpty) {
              renameTarget = result.title
                  .replaceAll(RegExp(r'[^\w\s]'), '')
                  .trim()
                  .replaceAll(RegExp(r'\s+'), '_');
            } else if (result.summary.isNotEmpty) {
              renameTarget = result.summary
                  .replaceAll(RegExp(r'[^\w\s]'), '')
                  .trim()
                  .split(RegExp(r'\s+'))
                  .where((w) => w.isNotEmpty)
                  .take(6)
                  .join('_');
            }
            if (renameTarget != null && renameTarget.isNotEmpty) {
              final rec = _findByPath(audioPath);
              if (rec != null) renameRecording(rec, renameTarget);
            }
            // Transcription done — delete local audio file (now synced to backend)
            try {
              final localFile = File(audioPath);
              if (localFile.existsSync()) {
                localFile.deleteSync();
                debugPrint('[RecorderService] Deleted local audio after sync: $audioPath');
              }
            } catch (e) {
              debugPrint('[RecorderService] Could not delete local audio: $e');
            }
            // Move back to idle so UI can refresh
            _processingState = ProcessingState.idle;
            notifyListeners();
          })
          .catchError((Object err) {
            debugPrint('[RecorderService] Transcription failed: $err');
            final errStr = err.toString();
            final isServerError = errStr.contains('Connection refused') ||
                errStr.contains('SocketException') ||
                errStr.contains('Error saving transcription') ||
                errStr.contains('connection error');
            final rec = _findByPath(audioPath);
            final sidecar = TranscriptionSidecar(
              status: TranscriptStatus.failed,
              language: languageCode,
              durationMs: rec?.duration.inMilliseconds,
            );
            TranscriptionService.saveSidecar(audioPath, sidecar);
            _applyTranscriptSidecar(audioPath, sidecar);
            if (isServerError) {
              _lastErrorMessage = 'serverError';
              _processingState = ProcessingState.serverError;
            } else {
              _processingState = ProcessingState.idle;
            }
            notifyListeners();
          })
          .whenComplete(() {
            if (cleanAudioPath != audioPath) {
              try {
                final cleanFile = File(cleanAudioPath);
                if (cleanFile.existsSync()) {
                  cleanFile.deleteSync();
                }
              } catch (e) {
                debugPrint(
                  '[RecorderService] Error deleting temporary clean file: $e',
                );
              }
            }
          });
    });
  }

  Future<void> renameRecording(Recording recording, String newName) async {
    try {
      final file = File(recording.path);
      final dir = file.parent.path;
      final ext = recording.path.split('.').last;
      final newPath = '$dir/$newName.$ext';

      // Rename audio file
      await file.rename(newPath);

      // Move sidecar too
      final oldSidecar = File(TranscriptionService.sidecarPath(recording.path));
      if (await oldSidecar.exists()) {
        await oldSidecar.rename(TranscriptionService.sidecarPath(newPath));
      }

      await loadRecordings();
    } catch (e) {
      debugPrint('[RecorderService] renameRecording error: $e');
    }
  }

  /// Public method to retry a failed transcription.
  ///
  /// Resets processingState to processing and re-triggers the full pipeline.
  void retryTranscription(Recording recording) {
    _lastErrorMessage = null;
    _processingState = ProcessingState.processing;
    notifyListeners();
    _triggerTranscription(recording.path, isImported: true);
  }

  /// Called once on startup. Resets any recording stuck in [TranscriptStatus.idle]
  /// — which means the background service saved the file but the app was closed
  /// before transcription ever started. Marking them [failed] puts them in Drafts.
  Future<void> _resetIdleRecordings() async {
    bool changed = false;
    for (final rec in _recordings) {
      if (rec.transcriptStatus == TranscriptStatus.idle) {
        debugPrint(
          '[RecorderService] Startup: idle recording detected: ${rec.path} — marking failed (Draft)',
        );
        final sidecar = TranscriptionSidecar(
          status: TranscriptStatus.failed,
          durationMs: rec.duration == Duration.zero
              ? null
              : rec.duration.inMilliseconds,
        );
        await TranscriptionService.saveSidecar(rec.path, sidecar);
        rec.applyTranscript(sidecar);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// Called once on startup. Resets any recording stuck in [TranscriptStatus.pending]
  /// — which means the app was killed or crashed before transcription finished.
  /// Marking them [failed] makes the Retry button visible in the UI.
  Future<void> _resetStalePendingRecordings() async {
    bool changed = false;
    for (final rec in _recordings) {
      if (rec.transcriptStatus == TranscriptStatus.pending) {
        debugPrint(
          '[RecorderService] Stale pending detected: ${rec.path} — marking failed',
        );
        final sidecar = TranscriptionSidecar(
          status: TranscriptStatus.failed,
          durationMs: rec.duration == Duration.zero
              ? null
              : rec.duration.inMilliseconds,
        );
        await TranscriptionService.saveSidecar(rec.path, sidecar);
        rec.applyTranscript(sidecar);
        changed = true;
      }
    }
    if (changed) notifyListeners();
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
        TranscriptionSidecar(
          status: status,
          durationMs: rec?.duration.inMilliseconds,
        ),
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
            var sidecar = await TranscriptionService.loadSidecar(file.path);
            rec.applyTranscript(sidecar);

            // If the sidecar has the duration stored, use it.
            if (sidecar.durationMs != null) {
              rec.duration = Duration(milliseconds: sidecar.durationMs!);
            } else if (rec.duration == Duration.zero) {
              // Otherwise, if the duration is zero (e.g. renamed file), probe it once.
              try {
                final probe = AudioPlayer();
                final duration = await probe.setFilePath(file.path);
                if (duration != null) {
                  rec.duration = duration;
                  // Save duration to sidecar so we don't have to probe it again next time
                  sidecar = sidecar.copyWith(
                    durationMs: duration.inMilliseconds,
                  );
                  await TranscriptionService.saveSidecar(file.path, sidecar);
                }
                await probe.dispose();
              } catch (e) {
                debugPrint(
                  '[RecorderService] Probe duration error for ${file.path}: $e',
                );
              }
            }

            // Delete the file immediately if it is too short (< 10 seconds).
            // This prevents invalid recordings from cluttering Drafts or the Library.
            if (rec.duration.inMilliseconds > 0 && rec.duration.inMilliseconds < 10000) {
              debugPrint('[RecorderService] loadRecordings: Found invalid short recording (${rec.duration.inMilliseconds}ms), deleting: ${file.path}');
              try {
                if (file.existsSync()) file.deleteSync();
                await TranscriptionService.deleteSidecar(file.path);
              } catch (_) {}
              continue; // Skip adding this to the list
            }

            // Note: idle → failed (Draft) promotion is intentionally NOT done
            // here. It only happens once at startup via _resetIdleRecordings()
            // to avoid marking brand-new recordings as Draft before transcription
            // has a chance to start.

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
    await session.configure(
      const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.none, // defaultToSpeaker false
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
      ),
    );
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
    _chunkRollTimer?.cancel();
    _iosTimer?.cancel();
    _silentPlayer?.dispose();
    _iosRecorder?.dispose();
    super.dispose();
  }
}
