import 'dart:io';
import '../services/transcription_service.dart';

class Recording {
  final String path;
  final String name;
  Duration duration;
  final DateTime date;

  // ── Transcript state ──────────────────────────────────────────────────────
  TranscriptStatus transcriptStatus;
  String? transcript;
  String? summary;
  String? title;
  String? transcriptLanguage;

  // ── Local UI state (not persisted) ────────────────────────────────────────
  bool isExpanded;

  Recording({
    required this.path,
    required this.name,
    required this.duration,
    required this.date,
    this.transcriptStatus = TranscriptStatus.idle,
    this.transcript,
    this.summary,
    this.title,
    this.transcriptLanguage,
    this.isExpanded = false,
  });

  static Recording? fromFile(File file) {
    try {
      final filename = file.path.split('/').last;
      final nameWithoutExt = filename.substring(0, filename.lastIndexOf('.'));

      // ── REC_ format — parse date and duration from filename ──────────────
      if (filename.startsWith('REC_')) {
        final parts = nameWithoutExt.split('_');
        if (parts.length >= 4) {
          final dateStr = parts[1];
          final timeStr = parts[2];
          final year = int.parse(dateStr.substring(0, 4));
          final month = int.parse(dateStr.substring(4, 6));
          final day = int.parse(dateStr.substring(6, 8));
          final hour = int.parse(timeStr.substring(0, 2));
          final minute = int.parse(timeStr.substring(2, 4));
          final second = int.parse(timeStr.substring(4, 6));
          final date = DateTime(year, month, day, hour, minute, second);
          final durationMs = int.parse(parts[3]);
          return Recording(
            path: file.path,
            name: nameWithoutExt,
            duration: Duration(milliseconds: durationMs),
            date: date,
          );
        }
      }

      // ── Renamed file — fallback to file system date ───────────────────────
      final stat = file.statSync();
      return Recording(
        path: file.path,
        name: nameWithoutExt,
        duration: Duration.zero,
        date: stat.modified,
      );
    } catch (e) {
      try {
        final stat = file.statSync();
        return Recording(
          path: file.path,
          name: file.path.split('/').last,
          duration: Duration.zero,
          date: stat.modified,
        );
      } catch (_) {
        return null;
      }
    }
  }

  /// Applies sidecar data to this recording's transcript fields.
  void applyTranscript(TranscriptionSidecar sidecar) {
    transcriptStatus = sidecar.status;
    transcript = sidecar.transcript;
    summary = sidecar.summary;
    title = sidecar.title;
    transcriptLanguage = sidecar.language;
  }
}
