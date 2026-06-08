import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:whisper_flutter_new/whisper_flutter_new.dart';
import '../constants.dart';
import 'package:audio_decoder/audio_decoder.dart';

enum TranscriptStatus { idle, pending, done, failed }

class TranscriptionSidecar {
  final TranscriptStatus status;
  final String? transcript;
  final String? language;

  const TranscriptionSidecar({
    required this.status,
    this.transcript,
    this.language,
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
      language: json['language'] as String?,
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
    'language': language,
  };
}

class TranscriptionService {
  TranscriptionService._();

  // static const String _modelAssetPath = 'assets/models/ggml-base.bin';
  static const String _modelAssetPath = 'assets/models/ggml-tiny.bin';

  static String? _modelDir; // cached after first copy

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

  // ─── Model setup ──────────────────────────────────────────────────────────

  /// Copies model from assets → library dir once, returns the dir path.
  static Future<String> _ensureModelReady() async {
    if (_modelDir != null) return _modelDir!;

    final Directory libDir = Platform.isAndroid
        ? await getApplicationSupportDirectory()
        : await getLibraryDirectory();

    // final modelFile = File('${libDir.path}/ggml-base.bin');
    final modelFile = File('${libDir.path}/ggml-tiny.bin');

    if (!await modelFile.exists()) {
      debugPrint('[TranscriptionService] Copying model from assets...');
      final byteData = await rootBundle.load(_modelAssetPath);
      await modelFile.writeAsBytes(byteData.buffer.asUint8List());
      debugPrint('[TranscriptionService] Model ready at ${modelFile.path}');
    } else {
      debugPrint('[TranscriptionService] Model already exists, skipping copy.');
    }

    _modelDir = libDir.path;
    return _modelDir!;
  }

  // ─── Main entry point ─────────────────────────────────────────────────────

static Future<String> transcribeFile(
  String audioPath, {
  String? languageCode,
}) async {
  final file = File(audioPath);
  if (!await file.exists()) {
    throw Exception('Audio file not found: $audioPath');
  }

  // Always re-encode to ensure correct 16kHz mono 16-bit PCM
  final wavPath = await _ensureWav(audioPath);

  final sizeInMB = File(wavPath).lengthSync() / (1024 * 1024);
  debugPrint('[TranscriptionService] File size: ${sizeInMB.toStringAsFixed(1)}MB');
  debugPrint('[TranscriptionService] Starting on-device transcription...');

  return _transcribeOnDevice(wavPath, languageCode: languageCode);
}



static Future<String> _ensureWav(String audioPath) async {
  final supportDir = await getApplicationSupportDirectory();
  final whisperInput = '${supportDir.path}/whisper_input.wav';

  final ext = audioPath.split('.').last.toLowerCase();

  if (ext == 'wav') {
    // Re-encode to ensure correct 16kHz mono 16-bit PCM format
    await AudioDecoder.convertToWav(
      audioPath,
      whisperInput,
      sampleRate: 16000,
      channels: 1,
    );
  } else {
    await AudioDecoder.convertToWav(
      audioPath,
      whisperInput,
      sampleRate: 16000,
      channels: 1,
    );
  }

  debugPrint('[TranscriptionService] WAV ready at: $whisperInput');
  return whisperInput;
}

  // ─── On-device Whisper ────────────────────────────────────────────────────

static Future<String> _transcribeOnDevice(
  String audioPath, {
  String? languageCode,
}) async {

    // Check file duration
  final fileSizeBytes = File(audioPath).lengthSync();
  // At 16kHz mono 16-bit: bytes / (16000 * 2) = seconds
  final estimatedSeconds = fileSizeBytes / (16000 * 2);
  debugPrint('[TranscriptionService] Estimated duration: ${estimatedSeconds.toStringAsFixed(1)}s');
  debugPrint('[TranscriptionService] Chunks needed: ${(estimatedSeconds / 30).ceil()}');



  final modelDir = await _ensureModelReady();

  final whisper = Whisper(
    model: WhisperModel.tiny,   // ← match your .bin file name
    modelDir: modelDir,         // ← it looks for ggml-tiny.bin here
  );

  final response = await whisper.transcribe(
    transcribeRequest: TranscribeRequest(
      audio: audioPath,
      isTranslate: false,
      language: languageCode ?? 'auto',
    ),
  );

  final text = response.text?.trim() ?? '';
  debugPrint('[TranscriptionService] Whisper done: $text');
  return text;
}

}

// Groq

// import 'dart:convert';
// import 'dart:io';
// import 'package:flutter/foundation.dart';
// import 'package:http/http.dart' as http;
// import 'package:path_provider/path_provider.dart';
// import '../constants.dart';

// enum TranscriptStatus { idle, pending, done, failed }

// class TranscriptionSidecar {
//   final TranscriptStatus status;
//   final String? transcript;
//   final String? language;

//   const TranscriptionSidecar({
//     required this.status,
//     this.transcript,
//     this.language,
//   });

//   static const idle = TranscriptionSidecar(status: TranscriptStatus.idle);

//   factory TranscriptionSidecar.fromJson(Map<String, dynamic> json) {
//     final statusStr = json['status'] as String? ?? 'idle';
//     final status = switch (statusStr) {
//       'done' => TranscriptStatus.done,
//       'pending' => TranscriptStatus.pending,
//       'failed' => TranscriptStatus.failed,
//       _ => TranscriptStatus.idle,
//     };
//     return TranscriptionSidecar(
//       status: status,
//       transcript: json['transcript'] as String?,
//       language: json['language'] as String?,
//     );
//   }

//   Map<String, dynamic> toJson() => {
//     'status': switch (status) {
//       TranscriptStatus.done => 'done',
//       TranscriptStatus.pending => 'pending',
//       TranscriptStatus.failed => 'failed',
//       TranscriptStatus.idle => 'idle',
//     },
//     'transcript': transcript,
//     'language': language,
//   };
// }

// class TranscriptionService {
//   TranscriptionService._();

//   // Groq's limit is 25MB — we use 20MB to stay safely under
//   static const int _maxChunkBytes = 20 * 1024 * 1024;

//   static String sidecarPath(String audioPath) {
//     final dotIndex = audioPath.lastIndexOf('.');
//     if (dotIndex == -1) return '$audioPath.json';
//     return '${audioPath.substring(0, dotIndex)}.json';
//   }

//   static Future<TranscriptionSidecar> loadSidecar(String audioPath) async {
//     try {
//       final file = File(sidecarPath(audioPath));
//       if (!await file.exists()) return TranscriptionSidecar.idle;
//       final content = await file.readAsString();
//       final json = jsonDecode(content) as Map<String, dynamic>;
//       return TranscriptionSidecar.fromJson(json);
//     } catch (e) {
//       debugPrint('[TranscriptionService] loadSidecar error: $e');
//       return TranscriptionSidecar.idle;
//     }
//   }

//   static Future<void> saveSidecar(
//     String audioPath,
//     TranscriptionSidecar sidecar,
//   ) async {
//     try {
//       final file = File(sidecarPath(audioPath));
//       await file.writeAsString(jsonEncode(sidecar.toJson()));
//     } catch (e) {
//       debugPrint('[TranscriptionService] saveSidecar error: $e');
//     }
//   }

//   static Future<void> deleteSidecar(String audioPath) async {
//     try {
//       final file = File(sidecarPath(audioPath));
//       if (await file.exists()) await file.delete();
//     } catch (e) {
//       debugPrint('[TranscriptionService] deleteSidecar error: $e');
//     }
//   }

//   // ─── Groq Whisper flow ────────────────────────────────────────────────────

//   static Future<String> transcribeFile(
//     String audioPath, {
//     String? languageCode,
//   }) async {
//     final file = File(audioPath);
//     if (!await file.exists()) {
//       throw Exception('Audio file not found: $audioPath');
//     }

//     final totalBytes = await file.length();
//     final sizeInMB = totalBytes / (1024 * 1024);
//     debugPrint('[TranscriptionService] File size: ${sizeInMB.toStringAsFixed(1)}MB');

//     // Split into chunks if over 20MB
//     final chunkPaths = await _splitIntoChunks(audioPath, totalBytes);
//     final wasChunked = chunkPaths.length > 1;

//     debugPrint('[TranscriptionService] Chunks: ${chunkPaths.length}');

//     try {
//       final List<String> transcripts = [];

//       for (int i = 0; i < chunkPaths.length; i++) {
//         final chunkPath = chunkPaths[i];
//         final chunkSizeMB = File(chunkPath).lengthSync() / (1024 * 1024);
//         debugPrint(
//           '[TranscriptionService] Transcribing chunk ${i + 1}/${chunkPaths.length} '
//           '(${chunkSizeMB.toStringAsFixed(1)}MB): $chunkPath',
//         );

//         final transcript = await _transcribeChunk(
//           chunkPath,
//           languageCode: languageCode,
//         );
//         transcripts.add(transcript);
//         debugPrint('[TranscriptionService] Chunk ${i + 1} done: $transcript');
//       }

//       return transcripts.join(' ').trim();
//     } finally {
//       if (wasChunked) {
//         await _deleteChunks(chunkPaths, audioPath);
//       }
//     }
//   }

//   // ─── Chunk splitting (pure Dart, no ffmpeg) ───────────────────────────────

//   static Future<List<String>> _splitIntoChunks(
//     String audioPath,
//     int totalBytes,
//   ) async {
//     if (totalBytes <= _maxChunkBytes) return [audioPath];

//     final tmpDir = await getTemporaryDirectory();
//     final ext = audioPath.split('.').last.toLowerCase();
//     final List<String> chunkPaths = [];

//     final raf = await File(audioPath).open(mode: FileMode.read);
//     try {
//       int offset = 0;
//       int chunkIndex = 0;

//       while (offset < totalBytes) {
//         final remaining = totalBytes - offset;
//         final size = remaining < _maxChunkBytes ? remaining : _maxChunkBytes;

//         await raf.setPosition(offset);
//         final bytes = await raf.read(size);

//         final chunkPath =
//             '${tmpDir.path}/groq_chunk_${chunkIndex}_${DateTime.now().millisecondsSinceEpoch}.$ext';
//         await File(chunkPath).writeAsBytes(bytes);
//         chunkPaths.add(chunkPath);

//         debugPrint(
//           '[TranscriptionService] Split chunk $chunkIndex: '
//           '${offset}–${offset + size} bytes → $chunkPath',
//         );

//         offset += size;
//         chunkIndex++;
//       }
//     } finally {
//       await raf.close();
//     }

//     return chunkPaths;
//   }

//   static Future<void> _deleteChunks(
//     List<String> chunkPaths,
//     String originalPath,
//   ) async {
//     for (final path in chunkPaths) {
//       if (path == originalPath) continue;
//       try {
//         final f = File(path);
//         if (await f.exists()) await f.delete();
//       } catch (e) {
//         debugPrint('[TranscriptionService] deleteChunk error for $path: $e');
//       }
//     }
//   }

//   // ─── Single Groq Whisper request (no polling needed) ─────────────────────

//   static Future<String> _transcribeChunk(
//     String audioPath, {
//     String? languageCode,
//   }) async {
//     final uri = Uri.parse(
//       'https://api.groq.com/openai/v1/audio/transcriptions',
//     );

//     final ext = audioPath.split('.').last.toLowerCase();
//     final mimeType = switch (ext) {
//       'mp3' => 'audio/mpeg',
//       'wav' => 'audio/wav',
//       'aac' => 'audio/aac',
//       'mp4' => 'audio/mp4',
//       _ => 'audio/m4a',
//     };

//     final request = http.MultipartRequest('POST', uri)
//       ..headers['Authorization'] = 'Bearer $kOpenAiApiKey'
//       ..fields['model'] = 'whisper-large-v3'
//       ..fields['response_format'] = 'json'
//       ..files.add(
//         await http.MultipartFile.fromPath(
//           'file',
//           audioPath,
//           contentType: http.MediaType.parse(mimeType),
//         ),
//       );

//     if (languageCode != null) {
//       request.fields['language'] = languageCode;
//     }

//     debugPrint('[TranscriptionService] Sending to Groq...');
//     final streamedResponse = await request.send();
//     final response = await http.Response.fromStream(streamedResponse);

//     if (response.statusCode == 200) {
//       final json = jsonDecode(response.body) as Map<String, dynamic>;
//       return (json['text'] as String? ?? '').trim();
//     } else {
//       throw Exception(
//         'Groq transcription failed ${response.statusCode}: ${response.body}',
//       );
//     }
//   }
// }


// GLADIA

// import 'dart:convert';
// import 'dart:io';
// import 'package:flutter/foundation.dart';
// import 'package:http/http.dart' as http;
// import '../constants.dart';
// import 'audio_chunker.dart';

// enum TranscriptStatus { idle, pending, done, failed }

// class TranscriptionSidecar {
//   final TranscriptStatus status;
//   final String? transcript;
//   final String? language;

//   const TranscriptionSidecar({
//     required this.status,
//     this.transcript,
//     this.language,
//   });

//   static const idle = TranscriptionSidecar(status: TranscriptStatus.idle);

//   factory TranscriptionSidecar.fromJson(Map<String, dynamic> json) {
//     final statusStr = json['status'] as String? ?? 'idle';
//     final status = switch (statusStr) {
//       'done' => TranscriptStatus.done,
//       'pending' => TranscriptStatus.pending,
//       'failed' => TranscriptStatus.failed,
//       _ => TranscriptStatus.idle,
//     };
//     return TranscriptionSidecar(
//       status: status,
//       transcript: json['transcript'] as String?,
//       language: json['language'] as String?,
//     );
//   }

//   Map<String, dynamic> toJson() => {
//     'status': switch (status) {
//       TranscriptStatus.done => 'done',
//       TranscriptStatus.pending => 'pending',
//       TranscriptStatus.failed => 'failed',
//       TranscriptStatus.idle => 'idle',
//     },
//     'transcript': transcript,
//     'language': language,
//   };
// }

// class TranscriptionService {
//   TranscriptionService._();

//   static String sidecarPath(String audioPath) {
//     final dotIndex = audioPath.lastIndexOf('.');
//     if (dotIndex == -1) return '$audioPath.json';
//     return '${audioPath.substring(0, dotIndex)}.json';
//   }

//   static Future<TranscriptionSidecar> loadSidecar(String audioPath) async {
//     try {
//       final file = File(sidecarPath(audioPath));
//       if (!await file.exists()) return TranscriptionSidecar.idle;
//       final content = await file.readAsString();
//       final json = jsonDecode(content) as Map<String, dynamic>;
//       return TranscriptionSidecar.fromJson(json);
//     } catch (e) {
//       debugPrint('[TranscriptionService] loadSidecar error: $e');
//       return TranscriptionSidecar.idle;
//     }
//   }

//   static Future<void> saveSidecar(
//     String audioPath,
//     TranscriptionSidecar sidecar,
//   ) async {
//     try {
//       final file = File(sidecarPath(audioPath));
//       await file.writeAsString(jsonEncode(sidecar.toJson()));
//     } catch (e) {
//       debugPrint('[TranscriptionService] saveSidecar error: $e');
//     }
//   }

//   static Future<void> deleteSidecar(String audioPath) async {
//     try {
//       final file = File(sidecarPath(audioPath));
//       if (await file.exists()) await file.delete();
//     } catch (e) {
//       debugPrint('[TranscriptionService] deleteSidecar error: $e');
//     }
//   }

//   // ─── Gladia 3-step flow ───────────────────────────────────────────────────

// static Future<String> transcribeFile(
//   String audioPath, {
//   String? languageCode,
// }) async {
//   final file = File(audioPath);
//   if (!await file.exists()) {
//     throw Exception('Audio file not found: $audioPath');
//   }

//   final sizeInMB = file.lengthSync() / (1024 * 1024);
//   debugPrint('[TranscriptionService] File size: ${sizeInMB.toStringAsFixed(1)}MB');

//   // Check duration — chunk if over Gladia's 8100s limit
//   final duration = await AudioChunker.getDurationSeconds(audioPath);
//   debugPrint('[TranscriptionService] Duration: ${duration?.toStringAsFixed(0)}s');

//   final List<String> chunkPaths;
//   final bool wasChunked;

//   if (duration != null && duration > 8100) {
//     debugPrint('[TranscriptionService] File exceeds limit, chunking...');
//     chunkPaths = await AudioChunker.split(audioPath);
//     wasChunked = true;
//   } else {
//     chunkPaths = [audioPath];
//     wasChunked = false;
//   }

//   try {
//     final List<String> transcripts = [];

//     for (int i = 0; i < chunkPaths.length; i++) {
//       final chunkPath = chunkPaths[i];
//       debugPrint(
//         '[TranscriptionService] Transcribing chunk ${i + 1}/${chunkPaths.length}: $chunkPath',
//       );

//       final audioUrl = await _uploadFile(chunkPath);
//       final transcriptionId = await _submitTranscription(
//         audioUrl,
//         languageCode: languageCode,
//       );
//       final transcript = await _pollUntilDone(transcriptionId);
//       transcripts.add(transcript);

//       debugPrint('[TranscriptionService] Chunk ${i + 1} done: $transcript');
//     }

//     return transcripts.join(' ').trim();
//   } finally {
//     if (wasChunked) {
//       await AudioChunker.deleteChunks(chunkPaths, audioPath);
//     }
//   }
// }

//   static Future<String> _uploadFile(String audioPath) async {
//     final uri = Uri.parse('https://api.gladia.io/v2/upload');

//     final ext = audioPath.split('.').last.toLowerCase();
//     final mimeType = switch (ext) {
//       'mp3' => 'audio/mpeg',
//       'wav' => 'audio/wav',
//       'aac' => 'audio/aac',
//       'mp4' => 'audio/mp4',
//       _ => 'audio/m4a',
//     };

//     final request = http.MultipartRequest('POST', uri)
//       ..headers['x-gladia-key'] = kOpenAiApiKey
//       ..files.add(
//         await http.MultipartFile.fromPath(
//           'audio',
//           audioPath,
//           contentType: http.MediaType.parse(mimeType),
//         ),
//       );

//     final streamedResponse = await request.send();
//     final response = await http.Response.fromStream(streamedResponse);

//     if (response.statusCode == 200 || response.statusCode == 201) {
//       final json = jsonDecode(response.body) as Map<String, dynamic>;
//       return json['audio_url'] as String;
//     } else {
//       throw Exception(
//         'Gladia upload failed ${response.statusCode}: ${response.body}',
//       );
//     }
//   }

//   static Future<String> _submitTranscription(
//     String audioUrl, {
//     String? languageCode,
//   }) async {
//     final uri = Uri.parse('https://api.gladia.io/v2/pre-recorded');

//     final body = <String, dynamic>{
//       'audio_url': audioUrl,
//     };

//     if (languageCode != null) {
//       body['language'] = languageCode;
//     } else {
//       body['detect_language'] = true;
//     }

//     final response = await http.post(
//       uri,
//       headers: {
//         'x-gladia-key': kOpenAiApiKey,
//         'Content-Type': 'application/json',
//       },
//       body: jsonEncode(body),
//     );

//     if (response.statusCode == 200 || response.statusCode == 201) {
//       final json = jsonDecode(response.body) as Map<String, dynamic>;
//       return json['id'] as String;
//     } else {
//       throw Exception(
//         'Gladia submit failed ${response.statusCode}: ${response.body}',
//       );
//     }
//   }

//   static Future<String> _pollUntilDone(String transcriptionId) async {
//     final uri = Uri.parse(
//       'https://api.gladia.io/v2/pre-recorded/$transcriptionId',
//     );

//     while (true) {
//       await Future.delayed(const Duration(seconds: 3));

//       final response = await http.get(
//         uri,
//         headers: {'x-gladia-key': kOpenAiApiKey},
//       );

//       if (response.statusCode == 200) {
//         final json = jsonDecode(response.body) as Map<String, dynamic>;
//         final status = json['status'] as String? ?? '';

//         debugPrint('[TranscriptionService] Poll status: $status');

//         if (status == 'done') {
//           // Extract full transcript from utterances
//           final result = json['result'] as Map<String, dynamic>?;
//           final transcription = result?['transcription'] as Map<String, dynamic>?;
//           final fullTranscript = transcription?['full_transcript'] as String? ?? '';
//           return fullTranscript.trim();
//         } else if (status == 'error') {
//           throw Exception('Gladia error: ${json['error_message']}');
//         }
//         // status == 'queued' or 'processing' → keep polling
//       } else {
//         throw Exception(
//           'Gladia poll failed ${response.statusCode}: ${response.body}',
//         );
//       }
//     }
//   }
// }



// assembly ai:

// import 'dart:convert';
// import 'dart:io';
// import 'package:flutter/foundation.dart';
// import 'package:http/http.dart' as http;
// import '../constants.dart';

// enum TranscriptStatus { idle, pending, done, failed }

// class TranscriptionSidecar {
//   final TranscriptStatus status;
//   final String? transcript;
//   final String? language;

//   const TranscriptionSidecar({
//     required this.status,
//     this.transcript,
//     this.language,
//   });

//   static const idle = TranscriptionSidecar(status: TranscriptStatus.idle);

//   factory TranscriptionSidecar.fromJson(Map<String, dynamic> json) {
//     final statusStr = json['status'] as String? ?? 'idle';
//     final status = switch (statusStr) {
//       'done' => TranscriptStatus.done,
//       'pending' => TranscriptStatus.pending,
//       'failed' => TranscriptStatus.failed,
//       _ => TranscriptStatus.idle,
//     };
//     return TranscriptionSidecar(
//       status: status,
//       transcript: json['transcript'] as String?,
//       language: json['language'] as String?,
//     );
//   }

//   Map<String, dynamic> toJson() => {
//     'status': switch (status) {
//       TranscriptStatus.done => 'done',
//       TranscriptStatus.pending => 'pending',
//       TranscriptStatus.failed => 'failed',
//       TranscriptStatus.idle => 'idle',
//     },
//     'transcript': transcript,
//     'language': language,
//   };
// }

// class TranscriptionService {
//   TranscriptionService._();

//   static String sidecarPath(String audioPath) {
//     final dotIndex = audioPath.lastIndexOf('.');
//     if (dotIndex == -1) return '$audioPath.json';
//     return '${audioPath.substring(0, dotIndex)}.json';
//   }

//   static Future<TranscriptionSidecar> loadSidecar(String audioPath) async {
//     try {
//       final file = File(sidecarPath(audioPath));
//       if (!await file.exists()) return TranscriptionSidecar.idle;
//       final content = await file.readAsString();
//       final json = jsonDecode(content) as Map<String, dynamic>;
//       return TranscriptionSidecar.fromJson(json);
//     } catch (e) {
//       debugPrint('[TranscriptionService] loadSidecar error: $e');
//       return TranscriptionSidecar.idle;
//     }
//   }

//   static Future<void> saveSidecar(
//     String audioPath,
//     TranscriptionSidecar sidecar,
//   ) async {
//     try {
//       final file = File(sidecarPath(audioPath));
//       await file.writeAsString(jsonEncode(sidecar.toJson()));
//     } catch (e) {
//       debugPrint('[TranscriptionService] saveSidecar error: $e');
//     }
//   }

//   static Future<void> deleteSidecar(String audioPath) async {
//     try {
//       final file = File(sidecarPath(audioPath));
//       if (await file.exists()) await file.delete();
//     } catch (e) {
//       debugPrint('[TranscriptionService] deleteSidecar error: $e');
//     }
//   }

//   // ─── AssemblyAI 3-step flow ───────────────────────────────────────────────

//   static Future<String> transcribeFile(
//     String audioPath, {
//     String? languageCode,
//   }) async {
//     final file = File(audioPath);
//     if (!await file.exists()) {
//       throw Exception('Audio file not found: $audioPath');
//     }

//     // Step 1: Upload file to AssemblyAI
//     debugPrint('[TranscriptionService] Uploading to AssemblyAI: $audioPath');
//     final uploadUrl = await _uploadFile(audioPath);
//     debugPrint('[TranscriptionService] Uploaded. URL: $uploadUrl');

//     // Step 2: Submit transcription job
//     final transcriptId = await _submitTranscription(
//       uploadUrl,
//       languageCode: languageCode,
//     );
//     debugPrint('[TranscriptionService] Job submitted. ID: $transcriptId');

//     // Step 3: Poll until complete
//     final transcript = await _pollUntilDone(transcriptId);
//     debugPrint('[TranscriptionService] Done: $transcript');
//     return transcript;
//   }

//   static Future<String> _uploadFile(String audioPath) async {
//     final uri = Uri.parse('https://api.assemblyai.com/v2/upload');
//     final fileBytes = await File(audioPath).readAsBytes();

//     final response = await http.post(
//       uri,
//       headers: {
//         'authorization': kOpenAiApiKey,
//         'content-type': 'application/octet-stream',
//       },
//       body: fileBytes,
//     );

//     if (response.statusCode == 200) {
//       final json = jsonDecode(response.body) as Map<String, dynamic>;
//       return json['upload_url'] as String;
//     } else {
//       throw Exception('Upload failed ${response.statusCode}: ${response.body}');
//     }
//   }

//   static Future<String> _submitTranscription(
//     String audioUrl, {
//     String? languageCode,
//   }) async {
//     final uri = Uri.parse('https://api.assemblyai.com/v2/transcript');

//     final body = <String, dynamic>{
//       'audio_url': audioUrl,
//     };

//     // AssemblyAI uses language_code param
//     if (languageCode != null) {
//       body['language_code'] = languageCode;
//     } else {
//       body['language_detection'] = true; // auto-detect
//     }

//     final response = await http.post(
//       uri,
//       headers: {
//         'authorization': kOpenAiApiKey,
//         'content-type': 'application/json',
//       },
//       body: jsonEncode(body),
//     );

//     if (response.statusCode == 200) {
//       final json = jsonDecode(response.body) as Map<String, dynamic>;
//       return json['id'] as String;
//     } else {
//       throw Exception(
//         'Submit failed ${response.statusCode}: ${response.body}',
//       );
//     }
//   }

//   static Future<String> _pollUntilDone(String transcriptId) async {
//     final uri = Uri.parse(
//       'https://api.assemblyai.com/v2/transcript/$transcriptId',
//     );

//     while (true) {
//       await Future.delayed(const Duration(seconds: 3));

//       final response = await http.get(
//         uri,
//         headers: {'authorization': kOpenAiApiKey},
//       );

//       if (response.statusCode == 200) {
//         final json = jsonDecode(response.body) as Map<String, dynamic>;
//         final status = json['status'] as String;

//         debugPrint('[TranscriptionService] Poll status: $status');

//         if (status == 'completed') {
//           return (json['text'] as String? ?? '').trim();
//         } else if (status == 'error') {
//           throw Exception('AssemblyAI error: ${json['error']}');
//         }
//         // status == 'queued' or 'processing' → keep polling
//       } else {
//         throw Exception(
//           'Poll failed ${response.statusCode}: ${response.body}',
//         );
//       }
//     }
//   }
// }