import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../services/api_service.dart';
import '../../services/recorder_service.dart';
import '../../services/transcription_service.dart';
import '../../widgets/drafts_sheet.dart';
import 'package:just_audio/just_audio.dart' as ja;

class _TranscriptItem {
  final String id;
  final String title;
  final String summaryText;
  final String dateStr;
  final String? audioUrl;

  _TranscriptItem({
    required this.id,
    required this.title,
    required this.summaryText,
    required this.dateStr,
    this.audioUrl,
  });
}

class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});

  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  bool _isLoading = true;
  List<_TranscriptItem> _allItems = [];
  List<_TranscriptItem> _filteredItems = [];
  String _searchQuery = '';
  final Set<String> _expandedItems = {};
  final _recorderService = RecorderService();
  final Map<String, String> _localAudioPaths = {};
  final Map<String, bool> _isDownloading = {};
  
  // Audio playback state
  String? _playingItemId;
  final _audioPlayer = ja.AudioPlayer();

  int get _draftCount => _recorderService.recordings
      .where((r) => r.transcriptStatus == TranscriptStatus.failed)
      .length;

  @override
  void initState() {
    super.initState();
    _recorderService.addListener(_onServiceChange);
    
    // Listen to player completion
    _audioPlayer.playerStateStream.listen((state) {
      if (state.processingState == ja.ProcessingState.completed) {
        if (mounted) setState(() => _playingItemId = null);
      }
    });

    _fetchTranscripts();
  }

  Future<void> _checkLocalFiles(List<_TranscriptItem> items) async {
    final tempDir = await getTemporaryDirectory();
    for (final item in items) {
      if (item.audioUrl != null) {
        final ext = item.audioUrl!.contains('.wav') ? '.wav' : '.m4a';
        final savePath = '${tempDir.path}/${item.id}$ext';
        if (await File(savePath).exists()) {
          _localAudioPaths[item.id] = savePath;
        }
      }
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _recorderService.removeListener(_onServiceChange);
    super.dispose();
  }

  void _onServiceChange() {
    if (mounted) setState(() {}); // Refresh badge count
  }

  Future<void> _fetchTranscripts() async {
    setState(() => _isLoading = true);
    try {
      final resp = await ApiService().get('/transcribe/');
      final data = resp.data;
      final List<_TranscriptItem> items = [];

      if (data is Map<String, dynamic> && data['transcripts'] is List) {
        for (final t in data['transcripts'] as List) {
          if (t is Map<String, dynamic>) {
            final id = t['transcript_id']?.toString() ?? '';
            final rawTitle = t['title']?.toString() ?? '';
            final title = rawTitle.isEmpty || rawTitle == 'Untitled Transcript'
                ? 'Untitled (${id.substring(0, id.length.clamp(0, 8))})'
                : rawTitle;

            String summaryText = '';
            if (t['summary'] is Map<String, dynamic>) {
              summaryText = t['summary']['summary_text']?.toString() ?? '';
            }

            String dateStr = '';
            if (t['processing_timestamp'] != null) {
              final dt = DateTime.parse(t['processing_timestamp'].toString())
                  .toLocal();
              dateStr = DateFormat('MMM dd').format(dt);
            }
            
            String? audioUrl = t['audio_url']?.toString();
            if (audioUrl != null && !audioUrl.startsWith('http')) {
              if (!audioUrl.startsWith('/')) {
                audioUrl = '/$audioUrl';
              }
            }

            if (id.isNotEmpty) {
              items.add(_TranscriptItem(
                id: id,
                title: title,
                summaryText: summaryText,
                dateStr: dateStr,
                audioUrl: audioUrl,
              ));
            }
          }
        }
      }

      if (mounted) {
        setState(() {
          _allItems = items;
          _filteredItems = items;
        });
        _checkLocalFiles(items);
      }
    } catch (e) {
      debugPrint('[LibraryTab] fetch error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _onSearchChanged(String query) {
    setState(() {
      _searchQuery = query;
      if (query.isEmpty) {
        _filteredItems = _allItems;
      } else {
        _filteredItems = _allItems
            .where(
                (item) => item.title.toLowerCase().contains(query.toLowerCase()))
            .toList();
      }
    });
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

  final Map<String, bool> _isDownloadingShare = {};

  Future<void> _handleShare(_TranscriptItem item, BuildContext buttonContext) async {
    // Capture the share button's render rect before any async gap (iOS popover anchor).
    final box = buttonContext.findRenderObject() as RenderBox?;
    final shareOrigin = box != null
        ? box.localToGlobal(Offset.zero) & box.size
        : const Rect.fromLTWH(0, 0, 1, 1);

    setState(() {
      _isDownloadingShare[item.id] = true;
    });

    try {
      // Fetch full transcript text from backend
      String fullTranscript = '';
      try {
        final resp = await ApiService().get('/transcribe/${item.id}');
        if (resp.data != null && resp.data['transcript'] != null) {
          final segments = resp.data['transcript']['full_transcript_data'] as List?;
          if (segments != null) {
            fullTranscript = segments.map((s) {
              final speaker = s['speaker']?.toString();
              final text = s['text']?.toString() ?? '';
              return (speaker != null && speaker.isNotEmpty)
                  ? '$speaker: $text'
                  : text;
            }).join('\n\n');
          }
        }
      } catch (e) {
        debugPrint('Failed to fetch full transcript: $e');
      }

      final text = '${item.title}\n\nSummary:\n${item.summaryText}\n\nTranscript:\n${fullTranscript.isNotEmpty ? fullTranscript : "(Failed to load transcript)"}';



      if (item.audioUrl == null) {
        await Share.share(text, sharePositionOrigin: shareOrigin);
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final ext = item.audioUrl!.contains('.wav') ? '.wav' : '.m4a';
      final savePath = '${tempDir.path}/${item.id}$ext';

      final file = File(savePath);
      if (!await file.exists()) {
        await Dio().download(item.audioUrl!, savePath);
      }

      await Share.shareXFiles(
        [XFile(savePath)],
        text: text,
        sharePositionOrigin: shareOrigin,
      );
    } catch (e) {
      debugPrint('Error sharing: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to prepare audio for sharing'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDownloadingShare[item.id] = false;
        });
      }
    }
  }

  Future<void> _handleDownloadPlay(_TranscriptItem item) async {
    if (item.audioUrl == null) return;

    if (_playingItemId == item.id) {
      await _audioPlayer.stop();
      setState(() => _playingItemId = null);
      return;
    }

    if (_localAudioPaths.containsKey(item.id)) {
      // Play local file
      try {
        await _audioPlayer.stop();
        await _audioPlayer.setFilePath(_localAudioPaths[item.id]!);
        setState(() => _playingItemId = item.id);
        await _audioPlayer.play();
      } catch (e) {
        debugPrint('Error playing audio: $e');
      }
      return;
    }

    // Download file
    setState(() => _isDownloading[item.id] = true);
    try {
      final tempDir = await getTemporaryDirectory();
      final ext = item.audioUrl!.contains('.wav') ? '.wav' : '.m4a';
      final savePath = '${tempDir.path}/${item.id}$ext';
      
      await Dio().download(item.audioUrl!, savePath);
      
      if (mounted) {
        setState(() {
          _localAudioPaths[item.id] = savePath;
          _isDownloading[item.id] = false;
        });
      }
    } catch (e) {
      debugPrint('Error downloading audio: $e');
      if (mounted) {
        setState(() => _isDownloading[item.id] = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to download audio'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _handleDelete(_TranscriptItem item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Delete Recording',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
        ),
        content: const Text(
          'This will permanently delete the transcript and its summary from the server.',
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

    if (confirm != true) return;

    try {
      final resp = await ApiService().delete('/transcribe/${item.id}');
      if (resp.statusCode == 200) {
        if (mounted) {
          setState(() {
            _allItems.removeWhere((i) => i.id == item.id);
            _filteredItems.removeWhere((i) => i.id == item.id);
            _expandedItems.remove(item.id);
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Transcript deleted successfully'),
              backgroundColor: Color(0xFF334155),
            ),
          );
        }
      } else {
        throw Exception('Status ${resp.statusCode}');
      }
    } catch (e) {
      debugPrint('[LibraryTab] delete error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to delete: ${e.toString().contains('404') ? 'Not found' : 'Server error'}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showDraftsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraftsSheet(
        onChanged: () {
          // Refresh library list after draft changes
          _fetchTranscripts();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final draftCount = _draftCount;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Library',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.black,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${_allItems.length} recording${_allItems.length == 1 ? '' : 's'}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Drafts button
                  GestureDetector(
                    onTap: _showDraftsSheet,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: draftCount > 0
                                ? const Color(0xFFF97316).withValues(alpha: 0.1)
                                : const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: draftCount > 0
                                  ? const Color(0xFFF97316).withValues(alpha: 0.3)
                                  : Colors.grey.withValues(alpha: 0.2),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.drafts_outlined,
                                size: 16,
                                color: draftCount > 0
                                    ? const Color(0xFFF97316)
                                    : Colors.grey.shade600,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Drafts',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: draftCount > 0
                                      ? const Color(0xFFF97316)
                                      : Colors.grey.shade600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Badge
                        if (draftCount > 0)
                          Positioned(
                            top: -6,
                            right: -6,
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(
                                color: Color(0xFFEF4444),
                                shape: BoxShape.circle,
                              ),
                              constraints: const BoxConstraints(
                                minWidth: 18,
                                minHeight: 18,
                              ),
                              child: Text(
                                '$draftCount',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Search Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  onChanged: _onSearchChanged,
                  style: const TextStyle(fontSize: 14),
                  decoration: const InputDecoration(
                    icon: Icon(Icons.search, color: Colors.grey, size: 20),
                    hintText: 'Search recordings or summaries...',
                    hintStyle: TextStyle(color: Colors.grey, fontSize: 14),
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // List View
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFFF97316),
                      ),
                    )
                  : _filteredItems.isEmpty
                      ? const Center(
                          child: Text(
                            'No recordings found.',
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 8,
                          ),
                          itemCount: _filteredItems.length,
                          itemBuilder: (context, index) {
                            final item = _filteredItems[index];
                            final isExpanded =
                                _expandedItems.contains(item.id);

                            return GestureDetector(
                              onTap: () => _toggleExpand(item.id),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                margin: const EdgeInsets.only(bottom: 12),
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: Colors.grey.withValues(alpha: 0.2),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color:
                                          Colors.black.withValues(alpha: 0.02),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Item Header
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFF97316)
                                                .withValues(alpha: 0.1),
                                            shape: BoxShape.circle,
                                          ),
                                          child: const Icon(
                                            Icons.volume_up_outlined,
                                            color: Color(0xFFF97316),
                                            size: 16,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                item.title,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 15,
                                                  color: Colors.black87,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                item.dateStr,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.grey,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        Icon(
                                          isExpanded
                                              ? Icons.keyboard_arrow_up
                                              : Icons.keyboard_arrow_down,
                                          color: Colors.grey,
                                        ),
                                      ],
                                    ),

                                    // Expanded Content
                                    if (isExpanded) ...[
                                      const SizedBox(height: 16),
                                      const Divider(),
                                      const SizedBox(height: 12),
                                      Row(
                                        children: [
                                          const Icon(Icons.auto_awesome,
                                              color: Color(0xFFF97316),
                                              size: 14),
                                          const SizedBox(width: 8),
                                          Text(
                                            'AI SUMMARY',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.grey.shade600,
                                              letterSpacing: 0.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        item.summaryText.isEmpty
                                            ? 'Processing summary...'
                                            : item.summaryText,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          height: 1.5,
                                          color: Color(0xFF334155),
                                        ),
                                      ),
                                      const SizedBox(height: 16),
                                      Row(
                                        children: [
                                          if (item.audioUrl != null) ...[
                                            Expanded(
                                              child: OutlinedButton.icon(
                                                onPressed: () => _handleDownloadPlay(item),
                                                icon: _isDownloading[item.id] == true
                                                    ? const SizedBox(
                                                        width: 16,
                                                        height: 16,
                                                        child: CircularProgressIndicator(strokeWidth: 2),
                                                      )
                                                    : Icon(
                                                        _playingItemId == item.id ? Icons.stop : (_localAudioPaths.containsKey(item.id) ? Icons.play_arrow : Icons.download),
                                                        size: 16,
                                                        color: const Color(0xFFF97316),
                                                      ),
                                                label: Text(
                                                  _playingItemId == item.id ? 'Stop' : (_localAudioPaths.containsKey(item.id) ? 'Play' : 'Download'),
                                                  style: const TextStyle(color: Color(0xFFF97316)),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                                style: OutlinedButton.styleFrom(
                                                  side: const BorderSide(color: Color(0xFFF97316)),
                                                  shape: RoundedRectangleBorder(
                                                      borderRadius: BorderRadius.circular(8)),
                                                  padding: const EdgeInsets.symmetric(horizontal: 4),
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                          ],
                                          Expanded(
                                            child: Builder(
                                              builder: (btnCtx) => OutlinedButton.icon(
                                                onPressed: () => _handleShare(item, btnCtx),
                                                icon: _isDownloadingShare[item.id] == true
                                                    ? const SizedBox(
                                                        width: 16,
                                                        height: 16,
                                                        child: CircularProgressIndicator(strokeWidth: 2),
                                                      )
                                                    : const Icon(
                                                        Icons.share_outlined,
                                                        size: 16,
                                                        color: Colors.black87),
                                                label: const Text('Share',
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                        color: Colors.black87)),
                                                style: OutlinedButton.styleFrom(
                                                  side: BorderSide(
                                                      color: Colors.grey
                                                          .withValues(alpha: 0.3)),
                                                  shape: RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(8)),
                                                  padding: const EdgeInsets.symmetric(horizontal: 4),
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: OutlinedButton.icon(
                                              onPressed: () =>
                                                  _handleDelete(item),
                                              icon: const Icon(
                                                  Icons.delete_outline,
                                                  size: 16,
                                                  color: Colors.red),
                                              label: const Text('Delete',
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                      color: Colors.red)),
                                              style: OutlinedButton.styleFrom(
                                                side: BorderSide(
                                                    color: Colors.red
                                                        .withValues(alpha: 0.3)),
                                                shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            8)),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 4),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
