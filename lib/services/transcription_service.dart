import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart' as dio;
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'api_service.dart';

enum TranscriptStatus { idle, pending, done, failed }

class TranscriptionSidecar {
  final TranscriptStatus status;
  final String? transcript;
  final String? summary;
  final String? title;
  final String? language;
  final int? durationMs;

  const TranscriptionSidecar({
    required this.status,
    this.transcript,
    this.summary,
    this.title,
    this.language,
    this.durationMs,
  });

  static const idle = TranscriptionSidecar(status: TranscriptStatus.idle);

  factory TranscriptionSidecar.fromJson(Map<String, dynamic> json) {
    final statusStr = json['status'] as String? ?? 'idle';
    final status = switch (statusStr) {
      'done' => TranscriptStatus.done,
      'pending' => TranscriptStatus.pending,
      'failed' => TranscriptStatus.failed,
      _ => TranscriptStatus.idle,
    };
    return TranscriptionSidecar(
      status: status,
      transcript: json['transcript'] as String?,
      summary: json['summary'] as String?,
      title: json['title'] as String?,
      language: json['language'] as String?,
      durationMs: json['durationMs'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
    'status': switch (status) {
      TranscriptStatus.done => 'done',
      TranscriptStatus.pending => 'pending',
      TranscriptStatus.failed => 'failed',
      TranscriptStatus.idle => 'idle',
    },
    'transcript': transcript,
    'summary': summary,
    'title': title,
    'language': language,
    'durationMs': durationMs,
  };

  TranscriptionSidecar copyWith({
    TranscriptStatus? status,
    String? transcript,
    String? summary,
    String? title,
    String? language,
    int? durationMs,
  }) {
    return TranscriptionSidecar(
      status: status ?? this.status,
      transcript: transcript ?? this.transcript,
      summary: summary ?? this.summary,
      title: title ?? this.title,
      language: language ?? this.language,
      durationMs: durationMs ?? this.durationMs,
    );
  }
}

class TranscriptionService {
  TranscriptionService._();

  /// Converts [audioPath] to WAV format using FFmpeg if it is not already a WAV file.
  /// Returns the path to the WAV file.
  static Future<String> ensureWavFormat(String audioPath) async {
    if (audioPath.toLowerCase().endsWith('.wav')) {
      return audioPath;
    }

    final dotIndex = audioPath.lastIndexOf('.');
    final outputPath = dotIndex != -1
        ? '${audioPath.substring(0, dotIndex)}.wav'
        : '$audioPath.wav';

    final outputFile = File(outputPath);
    if (await outputFile.exists() && await outputFile.length() > 0) {
      debugPrint('[TranscriptionService] Converted WAV file already exists: $outputPath');
      return outputPath;
    }

    final completer = Completer<String>();
    final arguments = [
      '-y',
      '-i',
      audioPath,
      '-ar',
      '16000',
      '-ac',
      '1',
      outputPath,
    ];

    try {
      await FFmpegKit.executeWithArgumentsAsync(arguments, (session) async {
        final returnCode = await session.getReturnCode();
        if (ReturnCode.isSuccess(returnCode)) {
          debugPrint('[TranscriptionService] Converted $audioPath to WAV: $outputPath');
          completer.complete(outputPath);
        } else {
          final failCode = returnCode?.getValue();
          debugPrint('[TranscriptionService] FFmpeg WAV conversion failed code: $failCode');
          completer.complete(audioPath);
        }
      });
    } catch (e) {
      debugPrint('[TranscriptionService] FFmpeg WAV conversion exception: $e');
      completer.complete(audioPath);
    }

    return completer.future;
  }

  // ─── Sidecar helpers ──────────────────────────────────────────────────────

  static String sidecarPath(String audioPath) {
    final dotIndex = audioPath.lastIndexOf('.');
    if (dotIndex == -1) return '$audioPath.json';
    return '${audioPath.substring(0, dotIndex)}.json';
  }

  static Future<TranscriptionSidecar> loadSidecar(String audioPath) async {
    try {
      final file = File(sidecarPath(audioPath));
      if (!await file.exists()) return TranscriptionSidecar.idle;
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return TranscriptionSidecar.fromJson(json);
    } catch (e) {
      debugPrint('[TranscriptionService] loadSidecar error: $e');
      return TranscriptionSidecar.idle;
    }
  }

  static Future<void> saveSidecar(
    String audioPath,
    TranscriptionSidecar sidecar,
  ) async {
    try {
      final file = File(sidecarPath(audioPath));
      await file.writeAsString(jsonEncode(sidecar.toJson()));
    } catch (e) {
      debugPrint('[TranscriptionService] saveSidecar error: $e');
    }
  }

  static Future<void> deleteSidecar(String audioPath) async {
    try {
      final file = File(sidecarPath(audioPath));
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[TranscriptionService] deleteSidecar error: $e');
    }
  }

  // ─── Main entry point ─────────────────────────────────────────────────────

  static Future<TranscriptionResult> transcribeFile(
    String audioPath, {
    String? languageCode,
    bool isImported = false,
    int retries = 3,
  }) async {
    for (int attempt = 0; attempt < retries; attempt++) {
      try {
        return await _doTranscribe(
          audioPath,
          languageCode: languageCode,
          isImported: isImported,
        );
      } catch (e) {
        if (attempt == retries - 1) rethrow;

        final errorStr = e.toString();
        // Do not retry on backend save/connection errors; fail immediately.
        if (errorStr.contains('Error saving transcription') ||
            errorStr.contains('Failed to save transcription') ||
            errorStr.contains('Error from transcription backend')) {
          rethrow;
        }

        final waitSeconds = 40 * (attempt + 1);
        debugPrint(
          '[TranscriptionService] Retrying in ${waitSeconds}s (attempt ${attempt + 1}/$retries)...',
        );
        await Future.delayed(Duration(seconds: waitSeconds));
      }
    }
    throw Exception('All retries exhausted');
  }

  // ─── One-shot backend transcription ───────────────────────────────────────
  //
  // For both recorded and imported audio files, we:
  //   1. Ensure the file is in WAV format.
  //   2. POST it directly to /transcribe/simple with generate_summary=true.
  //   3. Parse the response for transcript text and summary.
  //
  // No frontend Gemini calls. No chunking. One request → one response.

  static Future<TranscriptionResult> _doTranscribe(
    String audioPath, {
    String? languageCode,
    bool isImported = false,
  }) async {
    final file = File(audioPath);
    if (!await file.exists()) {
      throw Exception('Audio file not found: $audioPath');
    }

    final totalSizeInMB = file.lengthSync() / (1024 * 1024);
    debugPrint(
      '[TranscriptionService] File size: ${totalSizeInMB.toStringAsFixed(1)}MB'
      ' | isImported=$isImported',
    );

    // Ensure WAV format (recorder already outputs WAV; this is a safety net for imports).
    final wavPath = await ensureWavFormat(audioPath);
    final filename = wavPath.split('/').last;

    debugPrint(
      '[TranscriptionService] Sending to backend in one shot: $filename',
    );

    try {
      final wavFileSizeMB = File(wavPath).lengthSync() / (1024 * 1024);

      debugPrint(
        '📤 [TranscriptionService] Calling /transcribe/simple\n'
        '   file     : $filename\n'
        '   size     : ${wavFileSizeMB.toStringAsFixed(2)} MB\n'
        '   imported : $isImported\n'
        '   params   : { generate_summary: true }',
      );

      final formData = dio.FormData.fromMap({
        'audio_filename': filename,
        'audio': await dio.MultipartFile.fromFile(
          wavPath,
          filename: filename,
        ),
      });

      final saveResp = await ApiService().post(
        '/transcribe/simple',
        queryParameters: {'generate_summary': true},
        data: formData,
      );

      debugPrint(
        '📥 [TranscriptionService] /transcribe/simple response\n'
        '   status : ${saveResp.statusCode}\n'
        '   body   : ${saveResp.data}',
      );

      if (saveResp.statusCode != 200 && saveResp.statusCode != 201) {
        throw Exception(
          'Failed to save transcription (Status: ${saveResp.statusCode}).',
        );
      }

      final body = saveResp.data;

      String transcript = '';
      String summaryText = '';
      String title = 'Recording';

      if (body is Map<String, dynamic>) {
        // 1. Try parsing segments array (speaker diarization format)
        final segmentsList = body['segments'] ?? body['full_transcript_data'];
        if (segmentsList is List && segmentsList.isNotEmpty) {
          final buffer = StringBuffer();
          for (final item in segmentsList) {
            if (item is Map<String, dynamic>) {
              final speaker = item['speaker']?.toString() ?? 'SPEAKER';
              final text = item['text']?.toString() ?? '';
              if (text.isNotEmpty) {
                if (buffer.isNotEmpty) buffer.write('\n\n');
                buffer.write('$speaker: $text');
              }
            }
          }
          transcript = buffer.toString();
        }

        // 2. Fallback to flat string if segments weren't provided
        if (transcript.isEmpty) {
          transcript =
              _asString(body['transcript_text']) ??
              _asString(body['transcript']) ??
              '';
        }

        // 3. Extract title (check extracted_title or summary map)
        final extractedTitle = _asString(body['extracted_title']);
        if (extractedTitle != null && extractedTitle.isNotEmpty) {
          title = extractedTitle;
        }

        final summaryField = body['summary'];
        if (summaryField is Map<String, dynamic>) {
          summaryText =
              _asString(summaryField['summary_text']) ??
              _asString(summaryField['summary']) ??
              '';
          final parsedTitle = _asString(summaryField['title']);
          if (parsedTitle != null && parsedTitle.isNotEmpty) {
            title = parsedTitle;
          }
        } else {
          summaryText = _asString(summaryField) ?? '';
        }
      }

      debugPrint(
        '✅ [TranscriptionService] Parsed result\n'
        '   title      : $title\n'
        '   transcript : ${transcript.length} chars\n'
        '   summary    : ${summaryText.length} chars',
      );

      if (transcript.isEmpty) {
        transcript = '[No transcription generated]';
      }

      return TranscriptionResult(
        transcript: transcript,
        summary: summaryText,
        title: title,
        language: languageCode ?? '',
      );
    } catch (e) {
      debugPrint('❌ [TranscriptionService] Backend transcription error: $e');
      throw Exception('Error from transcription backend: $e');
    }
  }

  // ─── Response parsing helper ──────────────────────────────────────────────

  /// Safely extracts a String from a JSON value that *should* be a string
  /// but might come back as something else (null, a nested map, a list,
  /// a number) depending on backend response shape. Never throws.
  static String? _asString(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    if (value is Map<String, dynamic>) {
      // Common nested shapes: {"text": "..."} or {"value": "..."}
      final nested = value['text'] ?? value['value'] ?? value['content'];
      if (nested is String) return nested;
      debugPrint(
        '[TranscriptionService] Unexpected map shape for string field: $value',
      );
      return null;
    }
    if (value is List) {
      // e.g. a list of segments/strings — join whatever text we can find.
      return value
          .map(
            (e) => e is String
                ? e
                : (e is Map ? (e['text']?.toString() ?? '') : e.toString()),
          )
          .where((s) => s.isNotEmpty)
          .join(' ');
    }
    // Fallback: numbers, bools, etc.
    return value.toString();
  }
}

class TranscriptionResult {
  final String transcript;
  final String summary;
  final String title;
  final String language;

  const TranscriptionResult({
    required this.transcript,
    required this.summary,
    this.title = '',
    required this.language,
  });
}
