import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:dio/dio.dart' as dio;
import '../constants.dart';
import 'api_service.dart';
import 'audio_chunker.dart';

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

  static final _model = GenerativeModel(
    model: 'gemini-3.1-flash-lite', // current free-tier model
    apiKey: kGeminiApiKey,
  );

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
        final waitSeconds = 40 * (attempt + 1);
        debugPrint(
          '[TranscriptionService] Rate limited, retrying in ${waitSeconds}s (attempt ${attempt + 1}/$retries)...',
        );
        await Future.delayed(Duration(seconds: waitSeconds));
      }
    }
    throw Exception('All retries exhausted');
  }

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
      '[TranscriptionService] Total file size: ${totalSizeInMB.toStringAsFixed(1)}MB',
    );

    // ── Imported file: transcription only, single save + summary in one call ─
    if (isImported) {
      debugPrint(
        '[TranscriptionService] Imported file — sending whole audio to Gemini...',
      );
      final audioBytes = await file.readAsBytes();
      final ext = audioPath.split('.').last.toLowerCase();
      final mimeType = _mimeType(ext);

      const prompt =
          'You are an audio transcription assistant. Transcribe the following audio file and return only the plain transcribed text with no JSON, no timestamps, and no speaker labels.';

      final response = await _model.generateContent([
        Content.multi([DataPart(mimeType, audioBytes), TextPart(prompt)]),
      ]);

      final transcriptText = (response.text ?? '').trim();
      debugPrint(
        '[TranscriptionService] Imported file transcript: $transcriptText',
      );

      final finalTranscript = transcriptText.isEmpty
          ? '[No transcription generated]'
          : transcriptText;
      final filename = audioPath.split('/').last;

      // Single chunk + final chunk at once: save and generate summary in the same call.
      debugPrint(
        '[TranscriptionService] [Imported] Saving transcript + requesting summary...',
      );
      try {
        final formData = dio.FormData.fromMap({
          'transcript_text': finalTranscript,
          'audio_filename': filename,
        });
        final saveResp = await ApiService().post(
          '/transcribe/simple',
          queryParameters: {'generate_summary': true},
          data: formData,
        );
        debugPrint(
          '[TranscriptionService] [Imported] DB Save status: ${saveResp.statusCode}',
        );

        if (saveResp.statusCode != 200 && saveResp.statusCode != 201) {
          return TranscriptionResult(
            transcript: finalTranscript,
            summary:
                'Failed to save transcription (Status: ${saveResp.statusCode}). Summary generation aborted.',
            title: 'Recording',
            language: languageCode ?? '',
          );
        }

        final body = saveResp.data;
        debugPrint('[TranscriptionService] [Imported] Response body: $body');
        String summaryText = '';
        String title = 'Recording';
        if (body is Map<String, dynamic>) {
          // Backend nests summary as: { summary: { title: "...", summary: "..." } }
          final summaryField = body['summary'];
          if (summaryField is Map<String, dynamic>) {
            summaryText = _asString(summaryField['summary']) ?? '';
            final parsedTitle = _asString(summaryField['title']);
            if (parsedTitle != null && parsedTitle.isNotEmpty) {
              title = parsedTitle;
            }
          } else {
            summaryText = _asString(summaryField) ?? '';
          }
        }

        return TranscriptionResult(
          transcript: finalTranscript,
          summary: summaryText,
          title: title,
          language: languageCode ?? '',
        );
      } catch (e) {
        debugPrint('[TranscriptionService] [Imported] DB Save error: $e');
        return TranscriptionResult(
          transcript: finalTranscript,
          summary:
              'Error saving transcription: $e. Summary generation aborted.',
          title: 'Recording',
          language: languageCode ?? '',
        );
      }
    }

    // ── Recorded file: chunk → transcribe → save (summary on last chunk) ─────
    // Chunk the audio if necessary
    final chunkPaths = await AudioChunker.split(audioPath);
    final wasChunked = chunkPaths.length > 1;

    final List<String> allTranscripts = [];
    String? transcriptId;
    String summaryText = '';
    String title = 'Recording';

    try {
      for (int i = 0; i < chunkPaths.length; i++) {
        final chunkPath = chunkPaths[i];
        final chunkFile = File(chunkPath);
        final isLastChunk = i == chunkPaths.length - 1;
        debugPrint(
          '[TranscriptionService] Processing chunk ${i + 1}/${chunkPaths.length}...',
        );

        final audioBytes = await chunkFile.readAsBytes();
        final ext = chunkPath.split('.').last.toLowerCase();
        final mimeType = _mimeType(ext);

        final prompt =
            '''You are an audio transcription assistant. Transcribe the following audio file.
Return the transcription as a JSON object matching exactly this schema:
{
  "segments": [
    {"start": 0.0, "end": 2.5, "text": "actual transcribed text here"}
  ]
}

Note: Since this is a transcription task, please provide the actual transcribed text
and reasonable timestamps for each segment in total seconds. Do NOT include speaker information.
CRITICAL: The "start" and "end" timestamps MUST be valid floating point values in total seconds
(e.g., 60.5 for 1 minute and 0.5 seconds). DO NOT use formatted strings or multiple decimals like 1.0.66.''';

        // 1. Generate Transcription with Gemini
        final response = await _model.generateContent([
          Content.multi([DataPart(mimeType, audioBytes), TextPart(prompt)]),
        ]);

        final rawGemini = response.text ?? '';
        debugPrint(
          '[TranscriptionService] Gemini chunk ${i + 1} raw response: $rawGemini',
        );

        String transcriptText = '';
        try {
          String jsonStr = rawGemini;
          if (jsonStr.contains('```json')) {
            jsonStr = jsonStr.split('```json')[1].split('```')[0].trim();
          } else if (jsonStr.contains('```')) {
            jsonStr = jsonStr.split('```')[1].trim();
          } else {
            // Attempt to find the outermost JSON object or array
            final firstBracket = jsonStr.indexOf(RegExp(r'[\{\[]'));
            final lastBracket = jsonStr.lastIndexOf(RegExp(r'[\}\]]'));
            if (firstBracket != -1 &&
                lastBracket != -1 &&
                lastBracket > firstBracket) {
              jsonStr = jsonStr.substring(firstBracket, lastBracket + 1);
            }
          }

          final jsonObj = jsonDecode(jsonStr);

          if (jsonObj is Map<String, dynamic>) {
            if (jsonObj.containsKey('segments')) {
              final segments = jsonObj['segments'] as List<dynamic>;
              transcriptText = segments
                  .map((s) => s['text']?.toString() ?? '')
                  .join(' ');
            } else if (jsonObj.containsKey('text')) {
              transcriptText = jsonObj['text'] as String;
            } else {
              transcriptText = rawGemini;
            }
          } else if (jsonObj is List<dynamic>) {
            // In case Gemini still returns a raw list of segments
            transcriptText = jsonObj
                .map((s) => s['text']?.toString() ?? '')
                .join(' ');
          }
        } catch (e) {
          debugPrint(
            '[TranscriptionService] Failed to parse Gemini JSON for chunk ${i + 1}: $e',
          );
          transcriptText = rawGemini;
        }

        transcriptText = transcriptText.trim();
        if (transcriptText.isEmpty) {
          debugPrint(
            '[TranscriptionService] No transcription generated for chunk ${i + 1}.',
          );
          transcriptText = '[No transcription generated for chunk ${i + 1}]';
        }

        allTranscripts.add(transcriptText);

        final filename = chunkPath.split('/').last;

        // 2. Save transcript chunk to backend database.
        //    - First chunk: no transcript_id yet, backend creates one and returns it.
        //    - Middle chunks: pass transcript_id so backend appends.
        //    - Last chunk: pass transcript_id + generate_summary=true to get the summary back.
        debugPrint(
          '[TranscriptionService] Saving transcript chunk ${i + 1} to DB...',
        );
        try {
          final formData = dio.FormData.fromMap({
            'transcript_text': transcriptText,
            'audio_filename': filename,
          });

          final queryParameters = <String, dynamic>{
            if (transcriptId != null) 'transcript_id': transcriptId,
            if (isLastChunk) 'generate_summary': true,
          };

          final saveResp = await ApiService().post(
            '/transcribe/simple',
            queryParameters: queryParameters,
            data: formData,
          );
          debugPrint(
            '[TranscriptionService] DB Save chunk ${i + 1} status: ${saveResp.statusCode}',
          );

          if (saveResp.statusCode != 200 && saveResp.statusCode != 201) {
            debugPrint(
              '[TranscriptionService] Save API failed for chunk ${i + 1}. Skipping further steps.',
            );
            return TranscriptionResult(
              transcript: allTranscripts.join('\n\n').trim(),
              summary:
                  'Failed to save transcription (Status: ${saveResp.statusCode}). Summary generation aborted.',
              title: 'Recording',
              language: languageCode ?? '',
            );
          }

          final body = saveResp.data;
          debugPrint(
            '[TranscriptionService] Chunk ${i + 1} response body: $body',
          );
          if (body is Map<String, dynamic>) {
            // Capture transcript_id from the first response so later chunks can append to it.
            transcriptId ??= _asString(body['transcript_id']) ?? transcriptId;

            if (isLastChunk) {
              // Backend nests summary as: { summary: { title: "...", summary: "..." } }
              final summaryField = body['summary'];
              if (summaryField is Map<String, dynamic>) {
                summaryText = _asString(summaryField['summary']) ?? '';
                final parsedTitle = _asString(summaryField['title']);
                if (parsedTitle != null && parsedTitle.isNotEmpty) {
                  title = parsedTitle;
                }
              } else {
                summaryText = _asString(summaryField) ?? '';
              }
            }
          }
        } catch (e) {
          debugPrint('[TranscriptionService] DB Save chunk ${i + 1} error: $e');
          return TranscriptionResult(
            transcript: allTranscripts.join('\n\n').trim(),
            summary:
                'Error saving transcription: $e. Summary generation aborted.',
            title: 'Recording',
            language: languageCode ?? '',
          );
        }
      }

      final fullTranscript = allTranscripts.join('\n\n').trim();

      if (fullTranscript.isEmpty ||
          allTranscripts.every((t) => t.startsWith('[No transcription'))) {
        return TranscriptionResult(
          transcript: fullTranscript,
          summary: 'No valid transcription found. Summary generation skipped.',
          title: 'Recording',
          language: languageCode ?? '',
        );
      }

      // Summary now arrives inline with the last chunk's /transcribe/simple response,
      // so there's no separate /summary/preview call needed here anymore.
      return TranscriptionResult(
        transcript: fullTranscript,
        summary: summaryText,
        title: title,
        language: languageCode ?? '',
      );
    } finally {
      if (wasChunked) {
        await AudioChunker.deleteChunks(chunkPaths, audioPath);
      }
    }
  }

  // ─── MIME type helper ─────────────────────────────────────────────────────

  static String _mimeType(String ext) {
    return switch (ext) {
      'mp3' => 'audio/mp3',
      'wav' => 'audio/wav',
      'aac' => 'audio/aac',
      'ogg' => 'audio/ogg',
      'flac' => 'audio/flac',
      _ => 'audio/m4a', // default for m4a, aac, mp4 audio
    };
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
