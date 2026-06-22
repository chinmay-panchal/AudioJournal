import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:intl/intl.dart';
import 'package:shimmer/shimmer.dart';
import 'package:share_plus/share_plus.dart';
import '../models/recording.dart';
import '../services/recorder_service.dart';
import '../services/transcription_service.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';
import '../widgets/waveform_widget.dart';

// ─────────────────────────── Palette ────────────────────────────────────────
const _bgDeep = Color(0xFF0A0E1A);
const _bgCard = Color(0xFF111827);
const _surface = Color(0xFF1C2437);
const _surface2 = Color(0xFF243044);
const _accent = Color(0xFF6366F1); // indigo
const _accentLt = Color(0xFF818CF8);
const _danger = Color(0xFFEF4444);
const _textPrim = Colors.white;
const _textSec = Color(0xFF9CA3AF);
const _textMut = Color(0xFF6B7280);
// ─────────────────────────────────────────────────────────────────────────────

// =============================================================================
// Simple model for transcript list items from /transcribe
// =============================================================================
class _TranscriptItem {
  final String id;
  final String title;

  const _TranscriptItem({required this.id, required this.title});
}

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

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.16).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    if (_recorderService.isRecording) {
      _pulseController.repeat(reverse: true);
    }

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
          if (!_pulseController.isAnimating)
            _pulseController.repeat(reverse: true);
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

  // ── Actions ────────────────────────────────────────────────────────────────

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
          _showToast(e.toString(), isError: true);
        }
      }
    }
  }

  Future<void> _importFile() async {
    final imported = await _recorderService.importFile();
    if (mounted && imported) {
      _showToast('File imported — transcription started…');
    }
  }

  Future<void> _playPause(Recording recording) async {
    if (_recorderService.isRecording) return;
    if (_playingPath == recording.path) {
      _isPlaying ? await _audioPlayer.pause() : await _audioPlayer.play();
    } else {
      try {
        await _audioPlayer.stop();
        _playingPath = recording.path;
        await _audioPlayer.setFilePath(recording.path);
        await _audioPlayer.play();
      } catch (e) {
        debugPrint('Playback error: $e');
        if (mounted)
          _showToast('Playback failed. File may be missing.', isError: true);
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
    if (mounted) _showToast('Recording deleted');
  }

  void _copyTranscriptToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    if (mounted) _showToast('Transcript copied');
  }

  void _showToast(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(color: Colors.white)),
        backgroundColor: isError ? _danger : _surface2,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _handleLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => AlertDialog(
        backgroundColor: _surface,
        title: const Text(
          'Logout',
          style: TextStyle(color: _textPrim, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Are you sure you want to log out?',
          style: TextStyle(color: _textSec),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: _textMut)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Logout',
              style: TextStyle(color: _danger, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _audioPlayer.stop();
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _playingPath = null;
        });
      }
      await AuthService().logout();
    }
  }

  // ── Combine & Summarize ───────────────────────────────────────────────────

  Future<void> _showCombineSheet() async {
    // 1. Fetch transcript list
    List<_TranscriptItem> items = [];
    try {
      final resp = await ApiService().get('/transcribe');
      final data = resp.data;
      if (data is Map<String, dynamic> && data['transcripts'] is List) {
        for (final t in data['transcripts'] as List) {
          if (t is Map<String, dynamic>) {
            final id = t['transcript_id']?.toString() ?? '';
            final rawTitle = t['title']?.toString() ?? '';
            final title = rawTitle.isEmpty || rawTitle == 'Untitled Transcript'
                ? 'Untitled (${id.substring(0, 8)})'
                : rawTitle;
            if (id.isNotEmpty) items.add(_TranscriptItem(id: id, title: title));
          }
        }
      }
    } catch (e) {
      debugPrint('[CombineSheet] fetch error: $e');
      if (mounted) _showToast('Failed to load transcripts', isError: true);
      return;
    }

    if (items.isEmpty) {
      if (mounted) _showToast('No transcripts found');
      return;
    }

    if (!mounted) return;

    // 2. Show bottom sheet with stateful checkbox list
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _CombineSheet(
        items: items,
        onGenerate: (selectedIds) async {
          Navigator.pop(ctx);
          await _generateCombinedSummary(selectedIds);
        },
      ),
    );
  }

  Future<void> _generateCombinedSummary(List<String> ids) async {
    // Show loading indicator
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      builder: (_) => const _LoadingDialog(),
    );

    try {
      final resp = await ApiService().post(
        '/summary/custom',
        data: {'transcript_ids': ids},
      );

      if (!mounted) return;
      Navigator.pop(context); // dismiss loading

      final body = resp.data;
      if (body is Map<String, dynamic>) {
        final title = body['title']?.toString() ?? 'Combined Summary';
        final summaryText = body['summary_text']?.toString() ?? '';
        _showSummaryResultDialog(title, summaryText);
      }
    } catch (e) {
      debugPrint('[CombineSummary] error: $e');
      if (mounted) {
        Navigator.pop(context); // dismiss loading
        _showToast('Failed to generate summary', isError: true);
      }
    }
  }

  void _showSummaryResultDialog(String title, String summaryText) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => _SummaryResultDialog(
        title: title,
        summaryText: summaryText,
        onCopy: () {
          Clipboard.setData(ClipboardData(text: '$title\n\n$summaryText'));
          Navigator.pop(ctx);
          _showToast('Summary copied');
        },
      ),
    );
  }

  // ── Formatters ─────────────────────────────────────────────────────────────

  String _formatTimer(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String _formatListDuration(Duration d) {
    final h = d.inHours;
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:$m:$s';
    }
    return '$m:$s';
  }

  String _formatDate(DateTime date) =>
      DateFormat('MMM dd, yyyy  •  hh:mm a').format(date);

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isRecording = _recorderService.isRecording;
    final currentDuration = _recorderService.duration;
    final recordings = _recorderService.recordings;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _bgDeep,
        body: SafeArea(
          child: Column(
            children: [
              // ── Top bar ──────────────────────────────────────────────────
              _TopBar(
                onImport: isRecording ? null : _importFile,
                onLogout: isRecording ? null : _handleLogout,
              ),

              // ── Recorder section ─────────────────────────────────────────
              _RecorderSection(
                isRecording: isRecording,
                currentDuration: currentDuration,
                pulseAnimation: _pulseAnimation,
                onTap: _toggleRecording,
                formatTimer: _formatTimer,
              ),

              const SizedBox(height: 8),

              // ── Recordings list ──────────────────────────────────────────
              Expanded(
                child: _RecordingsList(
                  recordings: recordings,
                  playingPath: _playingPath,
                  isPlaying: _isPlaying,
                  playPosition: _playPosition,
                  playDuration: _playDuration,
                  onPlayPause: _playPause,
                  onDelete: _showDeleteConfirmation,
                  onShare: _shareRecording,
                  onSeek: (ms) => _audioPlayer.seek(Duration(milliseconds: ms)),
                  onToggleExpand: (r) =>
                      setState(() => r.isExpanded = !r.isExpanded),
                  onCopyTranscript: _copyTranscriptToClipboard,
                  onRetryTranscription: (r) =>
                      _recorderService.retryTranscription(r),
                  onRename: (r, name) =>
                      _recorderService.renameRecording(r, name),
                  formatDuration: _formatListDuration,
                  formatDate: _formatDate,
                  onCombine: _showCombineSheet,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDeleteConfirmation(Recording recording) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => _DeleteDialog(
        onConfirm: () {
          Navigator.pop(ctx);
          _deleteRecording(recording);
        },
      ),
    );
  }

  Future<void> _shareRecording(Recording recording) async {
    try {
      final file = XFile(recording.path);
      await Share.shareXFiles([
        file,
      ], text: recording.title ?? _displayTitle(recording));
    } catch (e) {
      debugPrint('[Share] Error: $e');
      if (mounted) _showToast('Could not share recording', isError: true);
    }
  }
}

// =============================================================================
// Combine Sheet  (stateful — needs checkboxes)
// =============================================================================

class _CombineSheet extends StatefulWidget {
  final List<_TranscriptItem> items;
  final void Function(List<String> selectedIds) onGenerate;

  const _CombineSheet({required this.items, required this.onGenerate});

  @override
  State<_CombineSheet> createState() => _CombineSheetState();
}

class _CombineSheetState extends State<_CombineSheet> {
  late final Set<String> _selected;

  @override
  void initState() {
    super.initState();
    // Start with nothing selected
    _selected = {};
  }

  bool get _allSelected => _selected.length == widget.items.length;

  void _toggleAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected.addAll(widget.items.map((i) => i.id));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: EdgeInsets.only(bottom: bottomPad),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Handle ────────────────────────────────────────────────────────
          const SizedBox(height: 12),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),

          // ── Header ────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [_accent, Color(0xFF7C3AED)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.auto_awesome_rounded,
                    color: Colors.white,
                    size: 17,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Combine & Summarize',
                        style: TextStyle(
                          color: _textPrim,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'Select recordings to combine into one summary',
                        style: TextStyle(color: _textMut, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                // Select all toggle
                GestureDetector(
                  onTap: _toggleAll,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _allSelected
                          ? _accent.withValues(alpha: 0.18)
                          : _surface2,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _allSelected ? _accentLt : Colors.white12,
                      ),
                    ),
                    child: Text(
                      _allSelected ? 'Deselect all' : 'Select all',
                      style: TextStyle(
                        color: _allSelected ? _accentLt : _textSec,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),
          Container(height: 1, color: Colors.white.withValues(alpha: 0.06)),

          // ── Checkbox list ─────────────────────────────────────────────────
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.38,
            ),
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: widget.items.length,
              itemBuilder: (ctx, i) {
                final item = widget.items[i];
                final checked = _selected.contains(item.id);
                return InkWell(
                  onTap: () => setState(() {
                    checked
                        ? _selected.remove(item.id)
                        : _selected.add(item.id);
                  }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: checked ? _accent : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: checked ? _accent : Colors.white24,
                              width: 1.5,
                            ),
                          ),
                          child: checked
                              ? const Icon(
                                  Icons.check_rounded,
                                  color: Colors.white,
                                  size: 14,
                                )
                              : null,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            item.title,
                            style: TextStyle(
                              color: checked ? _textPrim : _textSec,
                              fontSize: 13.5,
                              fontWeight: checked
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          Container(height: 1, color: Colors.white.withValues(alpha: 0.06)),
          const SizedBox(height: 14),

          // ── Footer: count + Generate button ───────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
            child: Row(
              children: [
                // Selected count badge
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: _selected.isEmpty
                        ? _surface2
                        : _accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _selected.isEmpty
                        ? 'None selected'
                        : '${_selected.length} selected',
                    style: TextStyle(
                      color: _selected.isEmpty ? _textMut : _accentLt,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                // Generate button
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: _selected.isEmpty ? 0.4 : 1.0,
                  child: GestureDetector(
                    onTap: _selected.isEmpty
                        ? null
                        : () => widget.onGenerate(_selected.toList()),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [_accent, Color(0xFF7C3AED)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: _selected.isEmpty
                            ? []
                            : [
                                BoxShadow(
                                  color: _accent.withValues(alpha: 0.35),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.auto_awesome_rounded,
                            color: Colors.white,
                            size: 15,
                          ),
                          SizedBox(width: 7),
                          Text(
                            'Generate',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// =============================================================================
// Loading Dialog
// =============================================================================

class _LoadingDialog extends StatelessWidget {
  const _LoadingDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Padding(
                padding: EdgeInsets.all(14),
                child: CircularProgressIndicator(
                  color: _accentLt,
                  strokeWidth: 2.5,
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Generating summary…',
              style: TextStyle(
                color: _textPrim,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Combining selected recordings with AI',
              style: TextStyle(color: _textMut, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Summary Result Dialog
// =============================================================================

class _SummaryResultDialog extends StatelessWidget {
  final String title;
  final String summaryText;
  final VoidCallback onCopy;

  const _SummaryResultDialog({
    required this.title,
    required this.summaryText,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Header ──────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 12, 0),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF34D399).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.auto_awesome_rounded,
                        size: 12,
                        color: Color(0xFF34D399),
                      ),
                      SizedBox(width: 5),
                      Text(
                        'Combined Summary',
                        style: TextStyle(
                          color: Color(0xFF34D399),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                // Copy button
                Tooltip(
                  message: 'Copy summary',
                  child: InkWell(
                    onTap: onCopy,
                    borderRadius: BorderRadius.circular(8),
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(
                        Icons.copy_rounded,
                        size: 18,
                        color: _textMut,
                      ),
                    ),
                  ),
                ),
                // Close button
                InkWell(
                  onTap: () => Navigator.pop(context),
                  borderRadius: BorderRadius.circular(8),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.close_rounded, size: 18, color: _textMut),
                  ),
                ),
              ],
            ),
          ),

          // ── Title ────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                title,
                style: const TextStyle(
                  color: _textPrim,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),
          Container(
            height: 1,
            margin: const EdgeInsets.symmetric(horizontal: 20),
            color: Colors.white.withValues(alpha: 0.07),
          ),
          const SizedBox(height: 4),

          // ── Scrollable body ───────────────────────────────────────────────
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.45,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: _buildFormattedText(summaryText),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormattedText(String content) {
    final lines = content.split('\n');
    final List<Widget> widgets = [];

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        if (widgets.isNotEmpty) widgets.add(const SizedBox(height: 8));
        continue;
      }

      if (line.startsWith('### ')) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Text(
              line.substring(4).replaceAll(RegExp(r'[#*`_]'), '').trim(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      } else if (line.startsWith('## ')) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 6),
            child: Text(
              line.substring(3).replaceAll(RegExp(r'[#*`_]'), '').trim(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      } else if (line.startsWith('# ')) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 8),
            child: Text(
              line.substring(2).replaceAll(RegExp(r'[#*`_]'), '').trim(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      } else if (line.startsWith('- ') || line.startsWith('* ')) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '• ',
                  style: TextStyle(color: _accentLt, fontSize: 13),
                ),
                Expanded(
                  child: Text(
                    line.substring(2).trim(),
                    style: const TextStyle(
                      color: Color(0xFFD1D5DB),
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              line.replaceAll('**', ''),
              style: const TextStyle(
                color: Color(0xFFD1D5DB),
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }
}

// =============================================================================
// Top Bar
// =============================================================================

class _TopBar extends StatelessWidget {
  final VoidCallback? onImport;
  final VoidCallback? onLogout;
  const _TopBar({required this.onImport, required this.onLogout});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [_accent, Color(0xFFA855F7)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(11),
            ),
            child: const Icon(Icons.mic, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AI voice notes',
                style: TextStyle(
                  color: _textPrim,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
              Text(
                'AI-powered transcription',
                style: TextStyle(color: _textMut, fontSize: 11),
              ),
            ],
          ),
          const Spacer(),
          Tooltip(
            message: 'Import audio file',
            child: InkWell(
              onTap: onImport,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                ),
                child: Icon(
                  Icons.folder_open_rounded,
                  color: onImport == null ? _textMut : _textSec,
                  size: 20,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'Log Out',
            child: InkWell(
              onTap: onLogout,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: _surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                ),
                child: Icon(
                  Icons.logout_rounded,
                  color: onLogout == null ? _textMut : _danger.withOpacity(0.8),
                  size: 20,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Recorder Section
// =============================================================================

class _RecorderSection extends StatelessWidget {
  final bool isRecording;
  final Duration currentDuration;
  final Animation<double> pulseAnimation;
  final VoidCallback onTap;
  final String Function(Duration) formatTimer;

  const _RecorderSection({
    required this.isRecording,
    required this.currentDuration,
    required this.pulseAnimation,
    required this.onTap,
    required this.formatTimer,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isRecording
              ? [const Color(0xFF1A0E1C), const Color(0xFF1C1226)]
              : [_surface, const Color(0xFF1A2035)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isRecording
              ? _danger.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.07),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: isRecording
                ? _danger.withValues(alpha: 0.12)
                : Colors.black.withValues(alpha: 0.3),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatTimer(currentDuration),
            style: TextStyle(
              color: isRecording ? _danger : _textPrim,
              fontSize: 52,
              fontWeight: FontWeight.w200,
              fontFamily: 'monospace',
              letterSpacing: 3,
            ),
          ),
          SizedBox(
            height: 80,
            child: VoiceWaveformWidget(isRecording: isRecording),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: isRecording
                      ? _danger.withValues(alpha: 0.12)
                      : _surface2,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isRecording
                        ? _danger.withValues(alpha: 0.4)
                        : Colors.white12,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isRecording) ...[
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: _danger,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: _danger.withValues(alpha: 0.6),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 7),
                    ],
                    Text(
                      isRecording ? 'Recording…' : 'Tap to record',
                      style: TextStyle(
                        color: isRecording ? _danger : _textSec,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              ScaleTransition(
                scale: pulseAnimation,
                child: GestureDetector(
                  onTap: onTap,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        width: 76,
                        height: 76,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isRecording
                              ? _danger.withValues(alpha: 0.15)
                              : _accent.withValues(alpha: 0.1),
                        ),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: isRecording
                                ? [_danger, const Color(0xFFDC2626)]
                                : [_accent, const Color(0xFF7C3AED)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: isRecording
                                  ? _danger.withValues(alpha: 0.45)
                                  : _accent.withValues(alpha: 0.4),
                              blurRadius: 18,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Icon(
                          isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                          color: Colors.white,
                          size: 30,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Recordings List
// =============================================================================

class _RecordingsList extends StatelessWidget {
  final List<Recording> recordings;
  final String? playingPath;
  final bool isPlaying;
  final Duration playPosition;
  final Duration playDuration;
  final Future<void> Function(Recording) onPlayPause;
  final void Function(Recording) onDelete;
  final Future<void> Function(Recording) onShare;
  final ValueChanged<int> onSeek;
  final void Function(Recording) onToggleExpand;
  final ValueChanged<String> onCopyTranscript;
  final void Function(Recording) onRetryTranscription;
  final void Function(Recording, String) onRename;
  final String Function(Duration) formatDuration;
  final String Function(DateTime) formatDate;
  final VoidCallback onCombine;

  const _RecordingsList({
    required this.recordings,
    required this.playingPath,
    required this.isPlaying,
    required this.playPosition,
    required this.playDuration,
    required this.onPlayPause,
    required this.onDelete,
    required this.onShare,
    required this.onSeek,
    required this.onToggleExpand,
    required this.onCopyTranscript,
    required this.onRetryTranscription,
    required this.onRename,
    required this.formatDuration,
    required this.formatDate,
    required this.onCombine,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Section header ─────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 16, 10),
          child: Row(
            children: [
              const Text(
                'Saved Recordings',
                style: TextStyle(
                  color: _textPrim,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${recordings.length}',
                  style: const TextStyle(
                    color: _accentLt,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(),
              // ── Combine & Summarize button ─────────────────────────────
              Tooltip(
                message: 'Combine & Summarize',
                child: InkWell(
                  onTap: onCombine,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF312E81), Color(0xFF4C1D95)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _accentLt.withValues(alpha: 0.3),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.auto_awesome_rounded,
                          size: 13,
                          color: _accentLt,
                        ),
                        SizedBox(width: 5),
                        Text(
                          'Combine',
                          style: TextStyle(
                            color: _accentLt,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        // ── List ──────────────────────────────────────────────────────────
        Expanded(
          child: recordings.isEmpty
              ? const _EmptyState()
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: recordings.length,
                  itemBuilder: (context, index) {
                    final r = recordings[index];
                    final isItemPlaying = playingPath == r.path;
                    return _RecordingCard(
                      key: ValueKey(r.path),
                      recording: r,
                      isItemPlaying: isItemPlaying,
                      isPlaying: isPlaying,
                      playPosition: playPosition,
                      playDuration: playDuration,
                      onPlayPause: () => onPlayPause(r),
                      onDelete: () => onDelete(r),
                      onShare: () => onShare(r),
                      onSeek: onSeek,
                      onToggleExpand: () => onToggleExpand(r),
                      onCopyTranscript: onCopyTranscript,
                      onRetryTranscription: () => onRetryTranscription(r),
                      onRename: (name) => onRename(r, name),
                      formatDuration: formatDuration,
                      formatDate: formatDate,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// =============================================================================
// Empty State
// =============================================================================

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: _surface,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white10),
            ),
            child: const Icon(
              Icons.graphic_eq_rounded,
              color: _textMut,
              size: 32,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'No recordings yet',
            style: TextStyle(
              color: _textSec,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Tap the mic button to get started',
            style: TextStyle(color: _textMut, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Recording Card
// =============================================================================

String _displayTitle(Recording recording) {
  final aiTitle = recording.title;
  if (aiTitle != null && aiTitle.isNotEmpty) return aiTitle;

  final name = recording.name;
  if (name.startsWith('REC_')) {
    final parts = name.split('_');
    if (parts.length >= 3) {
      try {
        final dateStr = parts[1];
        final timeStr = parts[2];
        final year = int.parse(dateStr.substring(0, 4));
        final month = int.parse(dateStr.substring(4, 6));
        final day = int.parse(dateStr.substring(6, 8));
        final hour = int.parse(timeStr.substring(0, 2));
        final min = int.parse(timeStr.substring(2, 4));
        return DateFormat(
          "MMM d '·' h:mm a",
        ).format(DateTime(year, month, day, hour, min));
      } catch (_) {}
    }
    return 'Recording';
  }

  return name.replaceAll(RegExp(r'\.[^.]+$'), '').replaceAll('_', ' ').trim();
}

class _RecordingCard extends StatelessWidget {
  final Recording recording;
  final bool isItemPlaying;
  final bool isPlaying;
  final Duration playPosition;
  final Duration playDuration;
  final VoidCallback onPlayPause;
  final VoidCallback onDelete;
  final VoidCallback onShare;
  final ValueChanged<int> onSeek;
  final VoidCallback onToggleExpand;
  final ValueChanged<String> onCopyTranscript;
  final VoidCallback onRetryTranscription;
  final ValueChanged<String> onRename;
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
    required this.onShare,
    required this.onSeek,
    required this.onToggleExpand,
    required this.onCopyTranscript,
    required this.onRetryTranscription,
    required this.onRename,
    required this.formatDuration,
    required this.formatDate,
  });

  void _showRenameDialog(BuildContext context) {
    final displayName = recording.name.replaceAll(RegExp(r'\.[^.]+$'), '');
    final controller = TextEditingController(text: displayName);
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => _RenameDialog(
        controller: controller,
        onConfirm: () {
          final name = controller.text.trim();
          if (name.isNotEmpty) {
            onRename(name);
            Navigator.pop(ctx);
          }
        },
        onCancel: () => Navigator.pop(ctx),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _displayTitle(recording);
    final hasPendingTranscript =
        recording.transcriptStatus == TranscriptStatus.pending;
    final hasTranscript =
        recording.transcriptStatus == TranscriptStatus.done &&
        ((recording.summary?.isNotEmpty ?? false) ||
            (recording.transcript?.isNotEmpty ?? false));

    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isItemPlaying
              ? _accent.withValues(alpha: 0.5)
              : Colors.white.withValues(alpha: 0.06),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: isItemPlaying
                ? _accent.withValues(alpha: 0.14)
                : Colors.black.withValues(alpha: 0.25),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _PlayButton(
                  isItemPlaying: isItemPlaying,
                  isPlaying: isPlaying,
                  onTap: onPlayPause,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _textPrim,
                          fontWeight: FontWeight.w600,
                          fontSize: 14.5,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          _MetaBadge(
                            icon: Icons.timer_outlined,
                            label: formatDuration(recording.duration),
                          ),
                          const SizedBox(width: 8),
                          if (hasPendingTranscript)
                            _MetaBadge(
                              icon: Icons.auto_awesome_rounded,
                              label: 'Transcribing…',
                              color: const Color(0xFFFBBF24),
                            )
                          else if (hasTranscript)
                            _MetaBadge(
                              icon: Icons.check_circle_outline_rounded,
                              label: 'Transcribed',
                              color: const Color(0xFF34D399),
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        formatDate(recording.date),
                        style: const TextStyle(color: _textMut, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _IconBtn(
                      icon: Icons.edit_outlined,
                      onTap: () => _showRenameDialog(context),
                      tooltip: 'Rename',
                    ),
                    _IconBtn(
                      icon: Icons.share_rounded,
                      onTap: onShare,
                      tooltip: 'Share',
                      color: _textMut,
                    ),
                    _IconBtn(
                      icon: recording.isExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      onTap: onToggleExpand,
                      tooltip: recording.isExpanded ? 'Collapse' : 'Expand',
                      color: hasTranscript ? _accentLt : _textMut,
                    ),
                    _IconBtn(
                      icon: Icons.delete_outline_rounded,
                      onTap: onDelete,
                      tooltip: 'Delete',
                      color: _danger.withValues(alpha: 0.75),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (isItemPlaying) ...[
            const _CardDivider(),
            _PlaybackSlider(
              position: playPosition,
              duration: playDuration,
              onSeek: onSeek,
              formatDuration: formatDuration,
            ),
          ],
          if (recording.isExpanded) ...[
            if (!isItemPlaying) const _CardDivider(),
            _TranscriptPanel(
              recording: recording,
              onCopy: onCopyTranscript,
              onRetry: onRetryTranscription,
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// Play Button
// =============================================================================

class _PlayButton extends StatelessWidget {
  final bool isItemPlaying;
  final bool isPlaying;
  final VoidCallback onTap;

  const _PlayButton({
    required this.isItemPlaying,
    required this.isPlaying,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: isItemPlaying
              ? const LinearGradient(
                  colors: [_accent, Color(0xFF7C3AED)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          color: isItemPlaying ? null : _surface2,
          boxShadow: isItemPlaying
              ? [
                  BoxShadow(
                    color: _accent.withValues(alpha: 0.4),
                    blurRadius: 12,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Icon(
          isItemPlaying && isPlaying
              ? Icons.pause_rounded
              : Icons.play_arrow_rounded,
          color: Colors.white,
          size: 26,
        ),
      ),
    );
  }
}

// =============================================================================
// Meta Badge
// =============================================================================

class _MetaBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _MetaBadge({
    required this.icon,
    required this.label,
    this.color = _textMut,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: color),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Small icon button
// =============================================================================

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final Color color;

  const _IconBtn({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.color = _textMut,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(icon, size: 19, color: color),
        ),
      ),
    );
  }
}

// =============================================================================
// Card divider
// =============================================================================

class _CardDivider extends StatelessWidget {
  const _CardDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      color: Colors.white.withValues(alpha: 0.07),
    );
  }
}

// =============================================================================
// Playback Slider
// =============================================================================

class _PlaybackSlider extends StatelessWidget {
  final Duration position;
  final Duration duration;
  final ValueChanged<int> onSeek;
  final String Function(Duration) formatDuration;

  const _PlaybackSlider({
    required this.position,
    required this.duration,
    required this.onSeek,
    required this.formatDuration,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Row(
        children: [
          Text(
            formatDuration(position),
            style: const TextStyle(color: _textMut, fontSize: 10.5),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 5.5,
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: _accentLt,
                inactiveTrackColor: _surface2,
                thumbColor: Colors.white,
                overlayColor: _accent.withValues(alpha: 0.2),
              ),
              child: Slider(
                value: position.inMilliseconds.toDouble().clamp(
                  0.0,
                  duration.inMilliseconds.toDouble(),
                ),
                max: duration.inMilliseconds > 0
                    ? duration.inMilliseconds.toDouble()
                    : 1.0,
                onChanged: (v) => onSeek(v.toInt()),
              ),
            ),
          ),
          Text(
            formatDuration(duration),
            style: const TextStyle(color: _textMut, fontSize: 10.5),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Transcript Panel
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
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    switch (recording.transcriptStatus) {
      case TranscriptStatus.pending:
        return const _PendingTranscript();

      case TranscriptStatus.done:
        final text = (recording.summary?.isNotEmpty == true)
            ? recording.summary!
            : (recording.transcript?.isNotEmpty == true)
            ? recording.transcript!
            : '';
        if (text.isEmpty) {
          return const Text(
            'No speech detected.',
            style: TextStyle(
              color: _textMut,
              fontSize: 13,
              fontStyle: FontStyle.italic,
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF34D399).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.auto_awesome_rounded,
                        size: 12,
                        color: Color(0xFF34D399),
                      ),
                      SizedBox(width: 5),
                      Text(
                        'AI Summary',
                        style: TextStyle(
                          color: Color(0xFF34D399),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Tooltip(
                  message: 'Copy to clipboard',
                  child: InkWell(
                    onTap: () => onCopy(text),
                    borderRadius: BorderRadius.circular(8),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.copy_rounded,
                        size: 16,
                        color: _textMut,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildFormattedText(text),
            if (recording.transcriptLanguage != null &&
                recording.transcriptLanguage!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Language: ${recording.transcriptLanguage}',
                style: const TextStyle(color: _textMut, fontSize: 11),
              ),
            ],
          ],
        );

      case TranscriptStatus.failed:
        return GestureDetector(
          onTap: onRetry,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _danger.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _danger.withValues(alpha: 0.25)),
            ),
            child: const Row(
              children: [
                Icon(Icons.error_outline_rounded, color: _danger, size: 18),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Transcription failed — tap to retry',
                    style: TextStyle(
                      color: _danger,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Icon(Icons.refresh_rounded, color: _danger, size: 18),
              ],
            ),
          ),
        );

      case TranscriptStatus.idle:
        return const Row(
          children: [
            Icon(Icons.text_snippet_outlined, color: _textMut, size: 16),
            SizedBox(width: 8),
            Text(
              'No transcript available',
              style: TextStyle(color: _textMut, fontSize: 13),
            ),
          ],
        );
    }
  }

  Widget _buildFormattedText(String content) {
    final lines = content.split('\n');
    final List<Widget> widgets = [];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) {
        if (widgets.isNotEmpty) widgets.add(const SizedBox(height: 8));
        continue;
      }

      if (line.startsWith('### ')) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Text(
              line.substring(4).replaceAll(RegExp(r'[#*`_]'), '').trim(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      } else if (line.startsWith('## ')) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 6),
            child: Text(
              line.substring(3).replaceAll(RegExp(r'[#*`_]'), '').trim(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      } else if (line.startsWith('# ')) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 8),
            child: Text(
              line.substring(2).replaceAll(RegExp(r'[#*`_]'), '').trim(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      } else if (line.startsWith('- ') || line.startsWith('* ')) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '• ',
                  style: TextStyle(color: _accentLt, fontSize: 13),
                ),
                Expanded(
                  child: Text(
                    line.substring(2).trim(),
                    style: const TextStyle(
                      color: Color(0xFFD1D5DB),
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              line.replaceAll('**', ''),
              style: const TextStyle(
                color: Color(0xFFD1D5DB),
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }
}

// =============================================================================
// Pending Transcript Shimmer
// =============================================================================

class _PendingTranscript extends StatelessWidget {
  const _PendingTranscript();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: _surface2,
      highlightColor: const Color(0xFF374151),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 140,
                height: 11,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _line(double.infinity),
          const SizedBox(height: 7),
          _line(double.infinity),
          const SizedBox(height: 7),
          _line(200),
        ],
      ),
    );
  }

  Widget _line(double w) => Container(
    width: w,
    height: 10,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(6),
    ),
  );
}

// =============================================================================
// Rename Dialog
// =============================================================================

class _RenameDialog extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const _RenameDialog({
    required this.controller,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Rename Recording',
              style: TextStyle(
                color: _textPrim,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(color: _textPrim),
              decoration: InputDecoration(
                hintText: 'Enter name…',
                hintStyle: const TextStyle(color: _textMut),
                filled: true,
                fillColor: _surface2,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _accent, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onCancel,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _textSec,
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: onConfirm,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('Save'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Delete Dialog
// =============================================================================

class _DeleteDialog extends StatelessWidget {
  final VoidCallback onConfirm;
  const _DeleteDialog({required this.onConfirm});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: _danger.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.delete_outline_rounded,
                color: _danger,
                size: 28,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Delete Recording?',
              style: TextStyle(
                color: _textPrim,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'This action cannot be undone.',
              style: TextStyle(color: _textSec, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _textSec,
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: onConfirm,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _danger,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('Delete'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
