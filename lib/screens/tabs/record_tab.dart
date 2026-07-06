import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../../services/recorder_service.dart';
import '../../services/auth_service.dart';
import '../../services/api_service.dart';
import '../../widgets/combine_sheet.dart';
import '../login_screen.dart';

// Public model for latest summary list
class RecentSummary {
  final String id;
  final String title;
  final String text;
  final String dateStr;

  RecentSummary({
    required this.id,
    required this.title,
    required this.text,
    required this.dateStr,
  });
}

class RecordTab extends StatefulWidget {
  const RecordTab({super.key});

  @override
  State<RecordTab> createState() => _RecordTabState();
}

class _RecordTabState extends State<RecordTab>
    with TickerProviderStateMixin {
  final _recorderService = RecorderService();
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _ringAnimation;

  // Shimmer animation for skeleton
  late AnimationController _shimmerController;
  late Animation<double> _shimmerAnimation;

  // Toast animation for "too short" notification
  late AnimationController _toastController;
  late Animation<Offset> _toastSlide;
  late Animation<double> _toastFade;
  Timer? _toastDismissTimer;

  List<RecentSummary> _recentSummaries = [];
  bool _isLoadingSummary = true;
  final Set<String> _expandedItems = {};
  ProcessingState _lastKnownProcessingState = ProcessingState.idle;
  String _activeToastType = 'tooShort';

  @override
  void initState() {
    super.initState();
    _recorderService.addListener(_onRecorderServiceChange);

    // Recording pulse animation
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _ringAnimation = Tween<double>(begin: 1.0, end: 1.6).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeOut),
    );

    // Shimmer animation for skeleton loading
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _shimmerAnimation = Tween<double>(begin: -1.5, end: 2.5).animate(
      CurvedAnimation(parent: _shimmerController, curve: Curves.easeInOut),
    );

    // Toast animation
    _toastController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _toastSlide = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _toastController, curve: Curves.easeOutBack));
    _toastFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _toastController, curve: Curves.easeOut),
    );

    if (_recorderService.isRecording) {
      _pulseController.repeat(reverse: false);
    }

    _fetchRecentSummaries();
  }

  Future<void> _fetchRecentSummaries() async {
    setState(() => _isLoadingSummary = true);
    try {
      final resp = await ApiService().get('/transcribe');
      final data = resp.data;
      if (data is Map<String, dynamic> && data['transcripts'] is List) {
        final list = data['transcripts'] as List;
        final count = list.length > 2 ? 2 : list.length;

        List<RecentSummary> summaries = [];
        for (int i = 0; i < count; i++) {
          final t = list[i];
          final id = t['transcript_id']?.toString() ?? '';
          final rawTitle = t['title']?.toString() ?? '';
          final title = rawTitle.isEmpty || rawTitle == 'Untitled Transcript'
              ? 'Untitled (${id.substring(0, id.length.clamp(0, 8))})'
              : rawTitle;
          final timestamp = t['processing_timestamp'];
          final summaryObj = t['summary'];

          String dateStr = '';
          if (timestamp != null) {
            final dt = DateTime.parse(timestamp.toString()).toLocal();
            dateStr = DateFormat('MMM dd, yyyy').format(dt);
          }

          String text = '';
          if (summaryObj is Map<String, dynamic>) {
            text = summaryObj['summary_text']?.toString() ?? '';
          }

          summaries.add(
            RecentSummary(id: id, title: title, text: text, dateStr: dateStr),
          );
        }

        if (mounted) {
          setState(() {
            _recentSummaries = summaries;
          });
        }
      }
    } catch (e) {
      debugPrint('[RecordTab] error fetching summaries: $e');
    } finally {
      if (mounted) setState(() => _isLoadingSummary = false);
    }
  }

  void _showTooShortToast() {
    _toastDismissTimer?.cancel();
    setState(() => _activeToastType = 'tooShort');
    _toastController.forward(from: 0);
    _toastDismissTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        _toastController.reverse();
        _recorderService.clearError();
      }
    });
  }

  void _showServerErrorToast() {
    _toastDismissTimer?.cancel();
    setState(() => _activeToastType = 'serverError');
    _toastController.forward(from: 0);
    _toastDismissTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        _toastController.reverse();
        _recorderService.clearError();
      }
    });
  }

  void _onRecorderServiceChange() {
    if (!mounted) return;

    final state = _recorderService.processingState;

    setState(() {
      if (_recorderService.isRecording) {
        if (!_pulseController.isAnimating) {
          _pulseController.repeat(reverse: false);
        }
      } else {
        _pulseController.stop();
        _pulseController.value = 0.0;
      }
    });

    // Handle processing state transitions
    if (state == ProcessingState.tooShort &&
        _lastKnownProcessingState != ProcessingState.tooShort) {
      _showTooShortToast();
    } else if (state == ProcessingState.serverError &&
        _lastKnownProcessingState != ProcessingState.serverError) {
      _showServerErrorToast();
    } else if (state == ProcessingState.idle &&
        (_lastKnownProcessingState == ProcessingState.processing ||
         _lastKnownProcessingState == ProcessingState.serverError)) {
      // Processing finished (or retry after serverError succeeded)
      _fetchRecentSummaries();
    }

    _lastKnownProcessingState = state;
  }

  @override
  void dispose() {
    _toastDismissTimer?.cancel();
    _recorderService.removeListener(_onRecorderServiceChange);
    _pulseController.dispose();
    _shimmerController.dispose();
    _toastController.dispose();
    super.dispose();
  }

  void _dismissToast() {
    _toastDismissTimer?.cancel();
    _toastController.reverse();
    _recorderService.clearError();
  }

  Future<void> _toggleRecording() async {
    if (_recorderService.isRecording) {
      await _recorderService.stopRecording();
    } else {
      try {
        await _recorderService.startRecording();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Future<void> _handleLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text(
          'Logout',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
        ),
        content: const Text(
          'Are you sure you want to log out?',
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
              'Logout',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await AuthService().logout();
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false,
        );
      }
    }
  }

  Future<void> _handleImport() async {
    final imported = await RecorderService().importFile();
    if (!imported && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No file selected or import failed.'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _toggleExpand(String id) {
    setState(() {
      if (_expandedItems.contains(id)) {
        _expandedItems.remove(id);
      } else {
        _expandedItems.add(id);
      }
    });
  }

  Future<void> _showCombineSheet() async {
    List<TranscriptItem> items = [];
    try {
      final resp = await ApiService().get('/transcribe');
      final data = resp.data;
      if (data is Map<String, dynamic> && data['transcripts'] is List) {
        for (final t in data['transcripts'] as List) {
          if (t is Map<String, dynamic>) {
            final id = t['transcript_id']?.toString() ?? '';
            final rawTitle = t['title']?.toString() ?? '';
            final title = rawTitle.isEmpty || rawTitle == 'Untitled Transcript'
                ? 'Untitled (${id.substring(0, id.length.clamp(0, 8))})'
                : rawTitle;
            if (id.isNotEmpty) items.add(TranscriptItem(id: id, title: title));
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to load transcripts')),
        );
      }
      return;
    }

    if (items.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No transcripts found')),
        );
      }
      return;
    }

    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => CombineSheet(
        items: items,
        onGenerate: (selectedIds) async {
          Navigator.pop(ctx);
          await _generateCombinedSummary(selectedIds);
        },
      ),
    );
  }

  Future<void> _generateCombinedSummary(List<String> ids) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black54,
      builder: (_) => const LoadingDialog(),
    );

    try {
      final resp = await ApiService().post(
        '/summary/custom',
        data: {'transcript_ids': ids},
      );
      if (!mounted) return;
      Navigator.pop(context);

      final body = resp.data;
      if (body is Map<String, dynamic>) {
        final title = body['title']?.toString() ?? 'Combined Summary';
        final summaryText = body['summary_text']?.toString() ?? '';
        showDialog(
          context: context,
          barrierColor: Colors.black54,
          builder: (ctx) => SummaryResultDialog(
            title: title,
            summaryText: summaryText,
            onCopy: () {
              Clipboard.setData(ClipboardData(text: '$title\n\n$summaryText'));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Summary copied')),
              );
            },
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to generate summary')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRecording = _recorderService.isRecording;
    final processingState = _recorderService.processingState;
    final isProcessing = processingState == ProcessingState.processing;
    final now = DateTime.now();
    final dateString = DateFormat('EEEE, MMMM dd').format(now);

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          SafeArea(
            child: CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24.0,
                      vertical: 20.0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Header
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Voice Notes',
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  dateString,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFF94A3B8),
                                  ),
                                ),
                              ],
                            ),
                            // Import + Logout buttons grouped together
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                GestureDetector(
                                  onTap: _handleImport,
                                  child: Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: const LinearGradient(
                                        colors: [
                                          Color(0xFF818CF8),
                                          Color(0xFFF97316),
                                        ],
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(alpha: 0.1),
                                          blurRadius: 10,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: const Center(
                                      child: Icon(
                                        Icons.folder_open_rounded,
                                        color: Colors.white,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                GestureDetector(
                                  onTap: _handleLogout,
                                  child: Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: const LinearGradient(
                                        colors: [
                                          Color(0xFF818CF8),
                                          Color(0xFFF97316),
                                        ],
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(alpha: 0.1),
                                          blurRadius: 10,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: const Center(
                                      child: Icon(
                                        Icons.logout_rounded,
                                        color: Colors.white,
                                        size: 18,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),

                        const SizedBox(height: 20),

                        // Record Button Area
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                isRecording
                                    ? 'Recording in progress...'
                                    : isProcessing
                                        ? 'Generating summary...'
                                        : 'Tap to start a new recording',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: isProcessing
                                      ? const Color(0xFF6366F1)
                                      : const Color(0xFF94A3B8),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 40),

                              // Animated Mic Button
                              GestureDetector(
                                onTap: isProcessing ? null : _toggleRecording,
                                child: AnimatedBuilder(
                                  animation: _pulseController,
                                  builder: (context, child) {
                                    return Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        if (isRecording)
                                          Opacity(
                                            opacity: 1.0 - _pulseController.value,
                                            child: Transform.scale(
                                              scale: _ringAnimation.value,
                                              child: Container(
                                                width: 140,
                                                height: 140,
                                                decoration: BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  border: Border.all(
                                                    color: const Color(
                                                      0xFFF97316,
                                                    ).withValues(alpha: 0.3),
                                                    width: 2,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        Container(
                                          width: 140,
                                          height: 140,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: const Color(
                                              0xFFF97316,
                                            ).withValues(alpha: 0.05),
                                          ),
                                        ),
                                        Transform.scale(
                                          scale: isRecording
                                              ? _pulseAnimation.value
                                              : 1.0,
                                          child: Container(
                                            width: 110,
                                            height: 110,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              gradient: LinearGradient(
                                                colors: isProcessing
                                                    ? [
                                                        const Color(0xFF94A3B8),
                                                        const Color(0xFFCBD5E1),
                                                      ]
                                                    : [
                                                        const Color(0xFF6366F1),
                                                        const Color(0xFFF97316),
                                                      ],
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: (isProcessing
                                                          ? const Color(0xFF94A3B8)
                                                          : const Color(0xFFF97316))
                                                      .withValues(alpha: 0.4),
                                                  blurRadius: 20,
                                                  spreadRadius: 2,
                                                  offset: const Offset(0, 8),
                                                ),
                                              ],
                                            ),
                                            child: Center(
                                              child: isProcessing
                                                  ? const SizedBox(
                                                      width: 28,
                                                      height: 28,
                                                      child: CircularProgressIndicator(
                                                        color: Colors.white,
                                                        strokeWidth: 2.5,
                                                      ),
                                                    )
                                                  : Icon(
                                                      isRecording
                                                          ? Icons.stop_rounded
                                                          : Icons.mic_none_rounded,
                                                      color: Colors.white,
                                                      size: 40,
                                                    ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ),

                              if (isRecording)
                                Padding(
                                  padding: const EdgeInsets.only(top: 30),
                                  child: _TimerDisplay(
                                    duration: _recorderService.duration,
                                  ),
                                ),
                            ],
                          ),
                        ),

                        // Skeleton OR real summaries
                        if (!isRecording) ...[
                          if (isProcessing) ...[
                            // Skeleton shimmer cards
                            _SkeletonSummaryCard(
                              shimmerAnimation: _shimmerAnimation,
                            ),
                            const SizedBox(height: 12),
                            _SkeletonSummaryCard(
                              shimmerAnimation: _shimmerAnimation,
                            ),
                          ] else if (_isLoadingSummary) ...[
                            _SkeletonSummaryCard(
                              shimmerAnimation: _shimmerAnimation,
                            ),
                            const SizedBox(height: 12),
                            _SkeletonSummaryCard(
                              shimmerAnimation: _shimmerAnimation,
                            ),
                          ] else if (_recentSummaries.isNotEmpty) ...[
                            Column(
                              children: _recentSummaries.map((summary) {
                                final isExpanded = _expandedItems.contains(
                                  summary.id,
                                );
                                return GestureDetector(
                                  onTap: () => _toggleExpand(summary.id),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    margin: const EdgeInsets.only(bottom: 12),
                                    padding: const EdgeInsets.all(20),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(20),
                                      border: Border.all(
                                        color: Colors.grey.withValues(alpha: 0.2),
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(alpha: 0.02),
                                          blurRadius: 10,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: Row(
                                                children: [
                                                  const Icon(
                                                    Icons.auto_awesome,
                                                    color: Color(0xFFF97316),
                                                    size: 16,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Text(
                                                      summary.title.toUpperCase(),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        fontSize: 11,
                                                        fontWeight: FontWeight.bold,
                                                        color: Colors.grey.shade600,
                                                        letterSpacing: 0.5,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Icon(
                                              isExpanded
                                                  ? Icons.keyboard_arrow_up
                                                  : Icons.keyboard_arrow_down,
                                              color: Colors.grey,
                                              size: 20,
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          summary.text.isEmpty
                                              ? 'No summary available.'
                                              : summary.text,
                                          maxLines: isExpanded ? null : 3,
                                          overflow: isExpanded
                                              ? TextOverflow.visible
                                              : TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            height: 1.5,
                                            color: Color(0xFF334155),
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          summary.dateStr,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.grey.shade400,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                        ],

                        // Combine Button
                        if (!isRecording && !isProcessing)
                          GestureDetector(
                            onTap: _showCombineSheet,
                            child: Container(
                              margin: const EdgeInsets.only(top: 4, bottom: 8),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [Color(0xFF6366F1), Color(0xFFF97316)],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ),
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFFF97316).withValues(alpha: 0.3),
                                    blurRadius: 10,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.library_add_check_outlined,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    'Combine Summaries',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Animated Toast (supports both types)
          Positioned(
            bottom: 24,
            left: 24,
            right: 24,
            child: FadeTransition(
              opacity: _toastFade,
              child: SlideTransition(
                position: _toastSlide,
                child: _activeToastType == 'serverError'
                    ? _StatusToast(
                        icon: Icons.cloud_off_rounded,
                        iconColor: const Color(0xFFEF4444),
                        iconBgColor: const Color(0xFFEF4444).withValues(alpha: 0.15),
                        title: 'Server unavailable',
                        subtitle: 'Recording saved as draft. Retry from Library.',
                        onDismiss: _dismissToast,
                      )
                    : _StatusToast(
                        icon: Icons.timer_off_rounded,
                        iconColor: const Color(0xFFF97316),
                        iconBgColor: const Color(0xFFF97316).withValues(alpha: 0.15),
                        title: 'Recording too short',
                        subtitle: 'Record at least 10 seconds of audio.',
                        onDismiss: _dismissToast,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Skeleton shimmer card ───────────────────────────────────────────────────

class _SkeletonSummaryCard extends StatelessWidget {
  final Animation<double> shimmerAnimation;
  const _SkeletonSummaryCard({required this.shimmerAnimation});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: shimmerAnimation,
      builder: (context, child) {
        final gradient = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: const [
            Color(0xFFF1F5F9),
            Color(0xFFE2E8F0),
            Color(0xFFF1F5F9),
          ],
          stops: [
            (shimmerAnimation.value - 1).clamp(0.0, 1.0),
            shimmerAnimation.value.clamp(0.0, 1.0),
            (shimmerAnimation.value + 1).clamp(0.0, 1.0),
          ],
        );

        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE2E8F0)),
            color: const Color(0xFFF8FAFC),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title row skeleton
              Row(
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      gradient: gradient,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Container(
                      height: 10,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        gradient: gradient,
                      ),
                    ),
                  ),
                  const SizedBox(width: 40),
                ],
              ),
              const SizedBox(height: 16),
              // Text body skeleton lines
              Container(
                height: 10,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  gradient: gradient,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                height: 10,
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  gradient: gradient,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                height: 10,
                width: 200,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  gradient: gradient,
                ),
              ),
              const SizedBox(height: 16),
              // Date skeleton
              Container(
                height: 8,
                width: 80,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  gradient: gradient,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Generic Status Toast ────────────────────────────────────────────────────

class _StatusToast extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color iconBgColor;
  final String title;
  final String subtitle;
  final VoidCallback onDismiss;

  const _StatusToast({
    required this.icon,
    required this.iconColor,
    required this.iconBgColor,
    required this.title,
    required this.subtitle,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: iconBgColor,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: onDismiss,
            child: const Icon(
              Icons.close_rounded,
              color: Color(0xFF64748B),
              size: 18,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Timer display ───────────────────────────────────────────────────────────

class _TimerDisplay extends StatelessWidget {
  final Duration duration;
  const _TimerDisplay({required this.duration});

  @override
  Widget build(BuildContext context) {
    final h = duration.inHours.toString().padLeft(2, '0');
    final m = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final s = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return Text(
      '$h:$m:$s',
      style: const TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.bold,
        color: Color(0xFFF97316),
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}
