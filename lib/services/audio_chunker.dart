import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

class AudioChunker {
  AudioChunker._();

  static const int chunkDurationSeconds = 3600; // 60 min

  /// Gets duration in seconds using just_audio (already in your project).
  static Future<double?> getDurationSeconds(String audioPath) async {
    final player = AudioPlayer();
    try {
      final duration = await player.setFilePath(audioPath);
      return duration?.inMilliseconds != null
          ? duration!.inMilliseconds / 1000.0
          : null;
    } catch (e) {
      debugPrint('[AudioChunker] getDurationSeconds error: $e');
      return null;
    } finally {
      await player.dispose();
    }
  }

  /// Splits file into chunks by byte proportion.
  /// Returns list of chunk paths. If no split needed, returns [audioPath].
  static Future<List<String>> split(String audioPath) async {
    final duration = await getDurationSeconds(audioPath);
    if (duration == null) throw Exception('Could not read audio duration');

    final totalChunks = (duration / chunkDurationSeconds).ceil();
    debugPrint('[AudioChunker] Duration: ${duration.toStringAsFixed(0)}s → $totalChunks chunk(s)');

    if (totalChunks <= 1) return [audioPath];

    final file = File(audioPath);
    final totalBytes = await file.length();
    final chunkBytes = (totalBytes / totalChunks).ceil();

    final tmpDir = await getTemporaryDirectory();
    final ext = audioPath.split('.').last.toLowerCase();
    final List<String> chunkPaths = [];

    final raf = await file.open(mode: FileMode.read);
    try {
      for (int i = 0; i < totalChunks; i++) {
        final start = i * chunkBytes;
        final end = ((i + 1) * chunkBytes).clamp(0, totalBytes);
        final size = end - start;

        await raf.setPosition(start);
        final bytes = await raf.read(size);

        final chunkPath =
            '${tmpDir.path}/chunk_${i}_${DateTime.now().millisecondsSinceEpoch}.$ext';
        await File(chunkPath).writeAsBytes(bytes);
        chunkPaths.add(chunkPath);

        debugPrint('[AudioChunker] Chunk $i: $start–$end bytes → $chunkPath');
      }
    } finally {
      await raf.close();
    }

    return chunkPaths;
  }

  /// Deletes chunk temp files, skipping the original.
  static Future<void> deleteChunks(
    List<String> chunkPaths,
    String originalPath,
  ) async {
    for (final path in chunkPaths) {
      if (path == originalPath) continue;
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (e) {
        debugPrint('[AudioChunker] deleteChunks error for $path: $e');
      }
    }
  }
}