import 'dart:io';
import '../services/transcription_service.dart';

class Recording {
  final String path;
  final String name;
  final Duration duration;
  final DateTime date;

  // ── Transcript state ──────────────────────────────────────────────────────
  /// Current transcription status for this recording.
  TranscriptStatus transcriptStatus;

  /// The transcript text, populated when [transcriptStatus] is [TranscriptStatus.done].
  String? transcript;

  /// The language code used for transcription (e.g. "en", "hi", or null for auto).
  String? transcriptLanguage;

  // ── Local UI state (not persisted) ────────────────────────────────────────
  /// Whether the transcript panel is expanded in the list UI.
  bool isExpanded;

  Recording({
    required this.path,
    required this.name,
    required this.duration,
    required this.date,
    this.transcriptStatus = TranscriptStatus.idle,
    this.transcript,
    this.transcriptLanguage,
    this.isExpanded = false,
  });

  /// Factory method to parse a Recording object from a File.
  /// Expects filename format: REC_yyyyMMdd_HHmmss_DurationMs.ext
  ///
  /// Transcript fields are populated separately via [applyTranscript].
  static Recording? fromFile(File file) {
    try {
      final filename = file.path.split('/').last;
      if (!filename.startsWith('REC_')) return null;

      // Remove extension
      final nameWithoutExt = filename.substring(0, filename.lastIndexOf('.'));
      final parts = nameWithoutExt.split('_');
      if (parts.length < 4) return null;

      // Parse date parts
      final dateStr = parts[1]; // yyyyMMdd
      final timeStr = parts[2]; // HHmmss

      final year = int.parse(dateStr.substring(0, 4));
      final month = int.parse(dateStr.substring(4, 6));
      final day = int.parse(dateStr.substring(6, 8));
      final hour = int.parse(timeStr.substring(0, 2));
      final minute = int.parse(timeStr.substring(2, 4));
      final second = int.parse(timeStr.substring(4, 6));

      final date = DateTime(year, month, day, hour, minute, second);

      // Parse duration
      final durationMs = int.parse(parts[3]);
      final duration = Duration(milliseconds: durationMs);

      return Recording(
        path: file.path,
        name: filename,
        duration: duration,
        date: date,
      );
    } catch (e) {
      // If filename parsing fails, fall back to file system metadata
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
    transcriptLanguage = sidecar.language;
  }
}
