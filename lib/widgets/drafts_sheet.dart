import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart' as ja;
import '../services/recorder_service.dart';
import '../services/transcription_service.dart';
import '../models/recording.dart';

class DraftsSheet extends StatefulWidget {
  final VoidCallback? onChanged;
  const DraftsSheet({super.key, this.onChanged});

  @override
  State<DraftsSheet> createState() => _DraftsSheetState();
}

class _DraftsSheetState extends State<DraftsSheet> {
  final _recorderService = RecorderService();
  final Set<String> _retryingPaths = {};
  
  // Audio playback state
  final ja.AudioPlayer _audioPlayer = ja.AudioPlayer();
  String? _playingPath;

  List<Recording> get _drafts => _recorderService.recordings
      .where((r) => r.transcriptStatus == TranscriptStatus.failed)
      .toList();

  @override
  void initState() {
    super.initState();
    _recorderService.addListener(_onServiceChange);
    
    // Listen to player state to reset UI when audio finishes
    _audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ja.ProcessingState.completed) {
        setState(() => _playingPath = null);
      }
    });
  }

  @override
  void dispose() {
    _recorderService.removeListener(_onServiceChange);
    _audioPlayer.dispose();
    super.dispose();
  }

  void _onServiceChange() {
    if (!mounted) return;
    final state = _recorderService.processingState;

    setState(() {
      // If processing completed (idle) or failed again (serverError),
      // clear retrying indicators
      if (state == ProcessingState.idle ||
          state == ProcessingState.serverError) {
        _retryingPaths.clear();
      }
    });

    // If idle after processing, signal parent to refresh
    if (state == ProcessingState.idle) {
      widget.onChanged?.call();
    }
  }

  void _retryDraft(Recording rec) {
    if (_playingPath == rec.path) {
      _stopAudio();
    }
    setState(() => _retryingPaths.add(rec.path));
    _recorderService.retryTranscription(rec);
  }

  Future<void> _toggleAudio(String path) async {
    if (_playingPath == path) {
      await _stopAudio();
    } else {
      await _playAudio(path);
    }
  }

  Future<void> _playAudio(String path) async {
    try {
      await _audioPlayer.setFilePath(path);
      setState(() => _playingPath = path);
      await _audioPlayer.play();
    } catch (e) {
      debugPrint('Error playing draft audio: $e');
      setState(() => _playingPath = null);
    }
  }

  Future<void> _stopAudio() async {
    await _audioPlayer.stop();
    setState(() => _playingPath = null);
  }

  Future<void> _deleteDraft(Recording rec) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Delete Draft',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
        ),
        content: const Text(
          'This will permanently delete the audio file. Continue?',
          style: TextStyle(color: Colors.black54),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _recorderService.deleteRecording(rec);
      widget.onChanged?.call();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final drafts = _drafts;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF97316).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.drafts_outlined,
                    color: Color(0xFFF97316),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Drafts',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.black,
                        ),
                      ),
                      Text(
                        '${drafts.length} unsync${drafts.length == 1 ? 'ed' : 'ed'} recording${drafts.length == 1 ? '' : 's'}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          const Divider(height: 1),

          // List or empty state
          if (drafts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Column(
                children: [
                  Icon(
                    Icons.check_circle_outline_rounded,
                    color: Colors.green.shade400,
                    size: 48,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'All recordings synced',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF334155),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'No pending drafts',
                    style: TextStyle(
                      fontSize: 13,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                itemCount: drafts.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final rec = drafts[index];
                  final isRetrying = _retryingPaths.contains(rec.path);
                  final isPlaying = _playingPath == rec.path;

                  return Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isRetrying
                            ? const Color(0xFF6366F1).withValues(alpha: 0.3)
                            : Colors.grey.withValues(alpha: 0.2),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.02),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        // Icon
                        Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: isRetrying
                                ? const Color(0xFF6366F1).withValues(alpha: 0.1)
                                : const Color(0xFFEF4444).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: isRetrying
                              ? const Padding(
                                  padding: EdgeInsets.all(10),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFF6366F1),
                                  ),
                                )
                              : GestureDetector(
                                  onTap: () => _toggleAudio(rec.path),
                                  child: Icon(
                                    isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
                                    color: const Color(0xFFEF4444),
                                    size: 24,
                                  ),
                                ),
                        ),
                        const SizedBox(width: 12),

                        // Info
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                rec.title ?? rec.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                  color: Colors.black87,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                isRetrying ? 'Syncing...' : 'Failed to sync',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isRetrying
                                      ? const Color(0xFF6366F1)
                                      : const Color(0xFFEF4444),
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Actions
                        if (!isRetrying) ...[
                          // Retry button
                          GestureDetector(
                            onTap: () => _retryDraft(rec),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [Color(0xFF6366F1), Color(0xFFF97316)],
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                'Retry',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Delete button
                          GestureDetector(
                            onTap: () => _deleteDraft(rec),
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: const Color(0xFFEF4444).withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(
                                Icons.delete_outline_rounded,
                                color: Color(0xFFEF4444),
                                size: 18,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),

          // Bottom safe area padding
          SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
        ],
      ),
    );
  }
}
