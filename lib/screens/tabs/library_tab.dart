import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import '../../services/api_service.dart';
import '../../services/recorder_service.dart';
import '../../services/transcription_service.dart';
import '../../widgets/drafts_sheet.dart';

class _TranscriptItem {
  final String id;
  final String title;
  final String summaryText;
  final String dateStr;

  _TranscriptItem({
    required this.id,
    required this.title,
    required this.summaryText,
    required this.dateStr,
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

  int get _draftCount => _recorderService.recordings
      .where((r) => r.transcriptStatus == TranscriptStatus.failed)
      .length;

  @override
  void initState() {
    super.initState();
    _recorderService.addListener(_onServiceChange);
    _fetchTranscripts();
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
      final resp = await ApiService().get('/transcribe');
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

            if (id.isNotEmpty) {
              items.add(_TranscriptItem(
                id: id,
                title: title,
                summaryText: summaryText,
                dateStr: dateStr,
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

  Future<void> _handleShare(_TranscriptItem item) async {
    try {
      final text = '${item.title}\n\n${item.summaryText}';
      await Share.share(text);
    } catch (e) {
      debugPrint('Error sharing: $e');
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
                                        mainAxisAlignment:
                                            MainAxisAlignment.end,
                                        children: [
                                          OutlinedButton.icon(
                                            onPressed: () =>
                                                _handleShare(item),
                                            icon: const Icon(
                                                Icons.share_outlined,
                                                size: 16,
                                                color: Colors.black87),
                                            label: const Text('Share',
                                                style: TextStyle(
                                                    color: Colors.black87)),
                                            style: OutlinedButton.styleFrom(
                                              side: BorderSide(
                                                  color: Colors.grey
                                                      .withValues(alpha: 0.3)),
                                              shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          8)),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 16),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          OutlinedButton.icon(
                                            onPressed: () =>
                                                _handleDelete(item),
                                            icon: const Icon(
                                                Icons.delete_outline,
                                                size: 16,
                                                color: Colors.red),
                                            label: const Text('Delete',
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
                                                      horizontal: 16),
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
