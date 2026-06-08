import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:intl/intl.dart';
import 'package:shimmer/shimmer.dart';
import '../models/recording.dart';
import '../services/recorder_service.dart';
import '../services/transcription_service.dart';
import '../constants.dart';
import '../widgets/waveform_widget.dart';

class RecorderScreen extends StatefulWidget {
  const RecorderScreen({super.key});

  @override
  State<RecorderScreen> createState() => _RecorderScreenState();
}

class _RecorderScreenState extends State<RecorderScreen>
    with SingleTickerProviderStateMixin {
  final _recorderService = RecorderService();
  final _audioPlayer = AudioPlayer();

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  String? _playingPath;
  bool _isPlaying = false;
  Duration _playPosition = Duration.zero;
  Duration _playDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _recorderService.addListener(_onRecorderServiceChange);

    // Pulsing animation for the record button
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.18).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    if (_recorderService.isRecording) {
      _pulseController.repeat(reverse: true);
    }

    // Audio playback state listeners
    _audioPlayer.playerStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state.playing;
          if (state.processingState == ProcessingState.completed) {
            _isPlaying = false;
            _playPosition = Duration.zero;
          }
        });
      }
    });

    _audioPlayer.positionStream.listen((pos) {
      if (mounted) setState(() => _playPosition = pos);
    });

    _audioPlayer.durationStream.listen((dur) {
      if (mounted) setState(() => _playDuration = dur ?? Duration.zero);
    });
  }

  void _onRecorderServiceChange() {
    if (mounted) {
      setState(() {
        if (_recorderService.isRecording) {
          if (!_pulseController.isAnimating) {
            _pulseController.repeat(reverse: true);
          }
        } else {
          _pulseController.stop();
          _pulseController.value = 0.0;
        }
      });
    }
  }

  @override
  void dispose() {
    _recorderService.removeListener(_onRecorderServiceChange);
    _pulseController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _toggleRecording() async {
    if (_recorderService.isRecording) {
      await _recorderService.stopRecording();
    } else {
      if (_isPlaying) {
        await _audioPlayer.stop();
        setState(() {
          _isPlaying = false;
          _playingPath = null;
        });
      }
      try {
        await _recorderService.startRecording();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(e.toString()),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    }
  }

  Future<void> _importFile() async {
    final imported = await _recorderService.importFile();
    if (mounted) {
      if (imported) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File imported. Transcription started…'),
            backgroundColor: Color(0xFF374151),
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        // Silently ignore — user may have just cancelled the picker.
      }
    }
  }

  Future<void> _playPause(Recording recording) async {
    if (_recorderService.isRecording) return;

    if (_playingPath == recording.path) {
      if (_isPlaying) {
        await _audioPlayer.pause();
      } else {
        await _audioPlayer.play();
      }
    } else {
      try {
        await _audioPlayer.stop();
        _playingPath = recording.path;
        await _audioPlayer.setFilePath(recording.path);
        await _audioPlayer.play();
      } catch (e) {
        debugPrint('Error playing recording: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Playback failed. File might be missing or corrupt.',
              ),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    }
  }

  Future<void> _deleteRecording(Recording recording) async {
    if (_playingPath == recording.path) {
      await _audioPlayer.stop();
      _playingPath = null;
      _isPlaying = false;
    }
    await _recorderService.deleteRecording(recording);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Recording deleted'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  void _copyTranscriptToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Transcript copied to clipboard'),
          duration: Duration(seconds: 1),
          backgroundColor: Color(0xFF374151),
        ),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Formatters
  // ---------------------------------------------------------------------------

  String _formatTimer(Duration duration) {
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  String _formatListDuration(Duration duration) {
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      final hours = duration.inHours.toString().padLeft(2, '0');
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  String _formatDate(DateTime date) {
    return DateFormat('MMM dd, yyyy • hh:mm a').format(date);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isRecording = _recorderService.isRecording;
    final currentDuration = _recorderService.duration;
    final recordings = _recorderService.recordings;
    final selectedLanguage = _recorderService.selectedLanguage;

    return Scaffold(
      backgroundColor: const Color(0xFF111827),
      appBar: AppBar(
        title: const Text(
          'Voice Recorder',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 22,
            letterSpacing: 0.5,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        actions: [
          // ── Upload / import button ─────────────────────────────────────────
          Tooltip(
            message: 'Import audio file',
            child: IconButton(
              icon: const Icon(Icons.folder_open_outlined, color: Colors.white70),
              onPressed: isRecording ? null : _importFile,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 20),

            // ── Timer Display ────────────────────────────────────────────────
            Text(
              _formatTimer(currentDuration),
              style: TextStyle(
                color: isRecording ? Colors.redAccent : Colors.white,
                fontSize: 62,
                fontWeight: FontWeight.w300,
                fontFamily: 'monospace',
                letterSpacing: 2.0,
              ),
            ),

            // ── Waveform ─────────────────────────────────────────────────────
            VoiceWaveformWidget(isRecording: isRecording),

            const SizedBox(height: 12),

            // ── Language selector ────────────────────────────────────────────
            // _LanguageToggle(
            //   selected: selectedLanguage,
            //   onChanged: isRecording
            //       ? null
            //       : (lang) {
            //           _recorderService.selectedLanguage = lang;
            //         },
            // ),

            const SizedBox(height: 20),

            // ── Record button ────────────────────────────────────────────────
            Center(
              child: ScaleTransition(
                scale: _pulseAnimation,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (isRecording)
                      Container(
                        width: 105,
                        height: 105,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.redAccent.withValues(alpha: 0.15),
                        ),
                      ),
                    GestureDetector(
                      onTap: _toggleRecording,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        width: 84,
                        height: 84,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isRecording
                              ? Colors.red
                              : const Color(0xFF374151),
                          boxShadow: [
                            BoxShadow(
                              color: isRecording
                              ? Colors.red.withValues(alpha: 0.5)
                              : Colors.black.withValues(alpha: 0.4),
                              blurRadius: isRecording ? 20 : 10,
                              spreadRadius: isRecording ? 3 : 1,
                            ),
                          ],
                        ),
                        child: Icon(
                          isRecording ? Icons.stop : Icons.mic,
                          color: Colors.white,
                          size: 38,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 15),

            Text(
              isRecording ? 'Recording active...' : 'Tap mic to start',
              style: TextStyle(
                color: isRecording
                    ? Colors.redAccent.withValues(alpha: 0.8)
                    : Colors.grey[400],
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),

            const SizedBox(height: 25),

            // ── Section title ────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: Row(
                children: [
                  const Text(
                    'Saved Recordings',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F2937),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${recordings.length}',
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 10),

            // ── Recordings list ──────────────────────────────────────────────
            Expanded(
              child: recordings.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.audiotrack,
                            color: Colors.grey[700],
                            size: 48,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'No recordings yet',
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: recordings.length,
                      itemBuilder: (context, index) {
                        final recording = recordings[index];
                        final isItemPlaying =
                            _playingPath == recording.path;
                        return _RecordingCard(
                          key: ValueKey(recording.path),
                          recording: recording,
                          isItemPlaying: isItemPlaying,
                          isPlaying: _isPlaying,
                          playPosition: _playPosition,
                          playDuration: _playDuration,
                          onPlayPause: () => _playPause(recording),
                          onDelete: () => _showDeleteConfirmation(recording),
                          onSeek: (ms) => _audioPlayer.seek(
                            Duration(milliseconds: ms),
                          ),
                          onToggleExpand: () {
                            setState(
                              () => recording.isExpanded =
                                  !recording.isExpanded,
                            );
                          },
                          onCopyTranscript: _copyTranscriptToClipboard,
                          onRetryTranscription: () =>
                              _recorderService.retryTranscription(recording),
                          formatDuration: _formatListDuration,
                          formatDate: _formatDate,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _showDeleteConfirmation(Recording recording) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1F2937),
          title: const Text(
            'Delete Recording',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'Are you sure you want to delete this recording? This action cannot be undone.',
            style: TextStyle(color: Colors.grey),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white54),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
              ),
              onPressed: () {
                Navigator.pop(context);
                _deleteRecording(recording);
              },
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }
}

// =============================================================================
// Language Toggle Widget
// =============================================================================

class _LanguageToggle extends StatelessWidget {
  final TranscriptionLanguage selected;
  final ValueChanged<TranscriptionLanguage>? onChanged;

  const _LanguageToggle({required this.selected, this.onChanged});

  @override
  Widget build(BuildContext context) {
    const langs = TranscriptionLanguage.values;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1F2937),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: langs.map((lang) {
          final isSelected = lang == selected;
          return GestureDetector(
            onTap: onChanged == null ? null : () => onChanged!(lang),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: isSelected
                    ? Colors.indigoAccent.withValues(alpha: 0.85)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                lang.label,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.grey[400],
                  fontWeight:
                      isSelected ? FontWeight.w700 : FontWeight.w400,
                  fontSize: 13,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// =============================================================================
// Recording Card Widget
// =============================================================================

class _RecordingCard extends StatelessWidget {
  final Recording recording;
  final bool isItemPlaying;
  final bool isPlaying;
  final Duration playPosition;
  final Duration playDuration;
  final VoidCallback onPlayPause;
  final VoidCallback onDelete;
  final ValueChanged<int> onSeek;
  final VoidCallback onToggleExpand;
  final ValueChanged<String> onCopyTranscript;
  final VoidCallback onRetryTranscription;
  final String Function(Duration) formatDuration;
  final String Function(DateTime) formatDate;

  const _RecordingCard({
    super.key,
    required this.recording,
    required this.isItemPlaying,
    required this.isPlaying,
    required this.playPosition,
    required this.playDuration,
    required this.onPlayPause,
    required this.onDelete,
    required this.onSeek,
    required this.onToggleExpand,
    required this.onCopyTranscript,
    required this.onRetryTranscription,
    required this.formatDuration,
    required this.formatDate,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1F2937),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isItemPlaying
              ? Colors.indigo.withValues(alpha: 0.4)
              : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: Column(
        children: [
          // ── Main list tile ─────────────────────────────────────────────────
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 6,
            ),
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isItemPlaying
                    ? Colors.indigo.withValues(alpha: 0.2)
                    : const Color(0xFF374151),
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: Icon(
                  isItemPlaying && isPlaying
                      ? Icons.pause
                      : Icons.play_arrow,
                  color: isItemPlaying ? Colors.indigoAccent : Colors.white,
                ),
                onPressed: onPlayPause,
              ),
            ),
            title: Text(
              recording.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4.0),
              child: Text(
                formatDate(recording.date),
                style: TextStyle(color: Colors.grey[400], fontSize: 12),
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  formatDuration(recording.duration),
                  style: TextStyle(
                    color: Colors.grey[400],
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                // Expand/collapse toggle
                IconButton(
                  icon: AnimatedRotation(
                    turns: recording.isExpanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.expand_more,
                      color: Colors.grey[400],
                      size: 22,
                    ),
                  ),
                  onPressed: onToggleExpand,
                  tooltip: recording.isExpanded
                      ? 'Collapse transcript'
                      : 'Expand transcript',
                ),
                IconButton(
                  icon: Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent.withValues(alpha: 0.8),
                  ),
                  onPressed: onDelete,
                ),
              ],
            ),
          ),

          // ── Playback slider (when this card is playing) ───────────────────
          if (isItemPlaying)
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12),
              child: Row(
                children: [
                  Text(
                    formatDuration(playPosition),
                    style: TextStyle(color: Colors.grey[400], fontSize: 11),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3.0,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6.0,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14.0,
                        ),
                        activeTrackColor: Colors.indigoAccent,
                        inactiveTrackColor: Colors.grey[700],
                        thumbColor: Colors.indigoAccent,
                      ),
                      child: Slider(
                        value: playPosition.inMilliseconds
                            .toDouble()
                            .clamp(
                              0.0,
                              playDuration.inMilliseconds.toDouble(),
                            ),
                        max: playDuration.inMilliseconds > 0
                            ? playDuration.inMilliseconds.toDouble()
                            : 1.0,
                        onChanged: (value) => onSeek(value.toInt()),
                      ),
                    ),
                  ),
                  Text(
                    formatDuration(playDuration),
                    style: TextStyle(color: Colors.grey[400], fontSize: 11),
                  ),
                ],
              ),
            ),

          // ── Transcript panel (when expanded) ─────────────────────────────
          if (recording.isExpanded)
            _TranscriptPanel(
              recording: recording,
              onCopy: onCopyTranscript,
              onRetry: onRetryTranscription,
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// Transcript Panel Widget
// =============================================================================

class _TranscriptPanel extends StatelessWidget {
  final Recording recording;
  final ValueChanged<String> onCopy;
  final VoidCallback onRetry;

  const _TranscriptPanel({
    required this.recording,
    required this.onCopy,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(left: 12, right: 12, bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    switch (recording.transcriptStatus) {
      case TranscriptStatus.pending:
        return _PendingTranscript();

      case TranscriptStatus.done:
        final text = recording.transcript ?? '';
        if (text.isEmpty) {
          return Text(
            'No speech detected.',
            style: TextStyle(
              color: Colors.grey[500],
              fontSize: 13,
              fontStyle: FontStyle.italic,
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      height: 1.55,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Copy transcript',
                  child: InkWell(
                    onTap: () => onCopy(text),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.copy_rounded,
                        size: 18,
                        color: Colors.grey[500],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (recording.transcriptLanguage != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Language: ${recording.transcriptLanguage}',
                  style: TextStyle(
                    color: Colors.grey[600],
                    fontSize: 11,
                  ),
                ),
              ),
          ],
        );

      case TranscriptStatus.failed:
        return GestureDetector(
          onTap: onRetry,
          child: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Transcription failed. Tap to retry.',
                  style: TextStyle(
                    color: Colors.redAccent.withValues(alpha: 0.9),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        );

      case TranscriptStatus.idle:
        return Row(
          children: [
            Icon(Icons.text_snippet_outlined, color: Colors.grey[600], size: 16),
            const SizedBox(width: 8),
            Text(
              'No transcript available.',
              style: TextStyle(color: Colors.grey[600], fontSize: 13),
            ),
          ],
        );
    }
  }
}

// =============================================================================
// Shimmer loading indicator for pending transcription
// =============================================================================

class _PendingTranscript extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: const Color(0xFF374151),
      highlightColor: const Color(0xFF4B5563),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 110,
                height: 12,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _shimmerLine(double.infinity),
          const SizedBox(height: 6),
          _shimmerLine(double.infinity),
          const SizedBox(height: 6),
          _shimmerLine(160),
        ],
      ),
    );
  }

  Widget _shimmerLine(double width) {
    return Container(
      width: width,
      height: 11,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
      ),
    );
  }
}
