import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/chat_models.dart';
import '../../models/recording.dart';
import '../../services/api_service.dart';
import '../../services/chat_service.dart';
import '../../services/recorder_service.dart';

class CalendarTab extends StatefulWidget {
  const CalendarTab({super.key});

  @override
  State<CalendarTab> createState() => _CalendarTabState();
}

class _CalendarTabState extends State<CalendarTab> {
  // ── Calendar state ────────────────────────────────────────────────────────
  DateTime _focusedMonth = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime _selectedDay = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    DateTime.now().day,
  );

  // ── Services ──────────────────────────────────────────────────────────────
  final RecorderService _recorderService = RecorderService();

  // ── Chat state ────────────────────────────────────────────────────────────
  final ChatService _chatService = ChatService();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _loadingSessions = false;
  ChatSession? _existingSession;
  List<ChatSession> _daySessions = [];
  bool _sessionStarted = false;

  // ── Backend transcript dates (for dots) ───────────────────────────────────
  List<DateTime> _backendTranscriptDates = [];

  @override
  void initState() {
    super.initState();
    _chatService.addListener(_onChatUpdate);
    _loadSessionForDate(_selectedDay);
    _fetchTranscriptDates();
  }

  @override
  void dispose() {
    _chatService.removeListener(_onChatUpdate);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _fetchTranscriptDates() async {
    try {
      final resp = await ApiService().get('/transcribe');
      final data = resp.data;
      final Set<DateTime> dates = {};

      if (data is Map<String, dynamic> && data['transcripts'] is List) {
        for (final t in data['transcripts'] as List) {
          if (t is Map<String, dynamic> && t['processing_timestamp'] != null) {
            final dt = DateTime.parse(t['processing_timestamp'].toString()).toLocal();
            dates.add(DateTime(dt.year, dt.month, dt.day));
          }
        }
      }

      if (mounted) {
        setState(() {
          _backendTranscriptDates = dates.toList();
        });
      }
    } catch (e) {
      debugPrint('[CalendarTab] fetch dates error: $e');
    }
  }

  void _onChatUpdate() {
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  // ── Load existing session for selected date ───────────────────────────────
  Future<void> _loadSessionForDate(DateTime date) async {
    setState(() {
      _loadingSessions = true;
      _existingSession = null;
      _sessionStarted = false;
    });
    _chatService.startNewSession();

    final dateStr = DateFormat('yyyy-MM-dd').format(date);
    final sessions = await _chatService.fetchSessions(targetDate: dateStr);

    if (mounted) {
      setState(() {
        _loadingSessions = false;
        _daySessions = sessions;
        if (sessions.isNotEmpty) {
          // Resume the most recent session for this date
          _existingSession = sessions.first;
          _chatService.resumeSession(sessions.first);
          _sessionStarted = true;
        }
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  Future<void> _refreshSessions() async {
    final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDay);
    debugPrint('[History] Fetching sessions for date: $dateStr');
    final sessions = await _chatService.fetchSessions(targetDate: dateStr);
    debugPrint('[History] Got ${sessions.length} sessions from backend');
    for (int i = 0; i < sessions.length; i++) {
      debugPrint('[History]   [$i] id=${sessions[i].id} title="${sessions[i].title}" msgs=${sessions[i].messageCount}');
    }
    if (mounted) {
      setState(() {
        _daySessions = sessions;
      });
    }
  }

  void _showHistoryModal() async {
    debugPrint('[History] === History button tapped ===');
    debugPrint('[History] Selected day: ${DateFormat('yyyy-MM-dd').format(_selectedDay)}');
    debugPrint('[History] Active session before refresh: ${_chatService.activeSessionId}');
    // Show a loading indicator while fetching latest sessions
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(color: Color(0xFFF97316)),
      ),
    );

    await _refreshSessions();
    if (!mounted) return;

    Navigator.pop(context); // hide loading indicator

    // Capture sessions before going async into showModalBottomSheet
    final sessions = _daySessions;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true, // allows controlling the height
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.85,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                // Handle bar
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.black12,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 16, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Chat History',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          _chatService.startNewSession();
                          setState(() => _sessionStarted = false);
                        },
                        icon: const Icon(Icons.add, size: 18, color: Color(0xFFF97316)),
                        label: const Text(
                          'New Chat',
                          style: TextStyle(
                            color: Color(0xFFF97316),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        style: TextButton.styleFrom(
                          backgroundColor: const Color(0xFFF97316).withValues(alpha: 0.1),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Colors.black12),
                // Body
                Expanded(
                  child: sessions.isEmpty
                      ? const Center(
                          child: Text(
                            'No past chats for this date.',
                            style: TextStyle(color: Colors.grey, fontSize: 16),
                          ),
                        )
                      : ListView.builder(
                          controller: scrollController,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: sessions.length,
                          itemBuilder: (context, index) {
                            final session = sessions[index];
                            final isSelected = _chatService.activeSessionId == session.id;
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                              leading: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? const Color(0xFFF97316).withValues(alpha: 0.15)
                                      : Colors.grey.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  Icons.chat_bubble_outline,
                                  size: 18,
                                  color: isSelected ? const Color(0xFFF97316) : Colors.grey,
                                ),
                              ),
                              title: Text(
                                session.title.isNotEmpty ? session.title : 'Chat',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                                  color: isSelected ? const Color(0xFFF97316) : Colors.black87,
                                ),
                              ),
                              subtitle: Text(
                                '${session.messageCount} messages',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isSelected
                                      ? const Color(0xFFF97316).withValues(alpha: 0.7)
                                      : Colors.grey,
                                ),
                              ),
                              trailing: isSelected
                                  ? const Icon(Icons.check_circle_rounded,
                                      color: Color(0xFFF97316), size: 20)
                                  : const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
                              onTap: () {
                                Navigator.pop(context);
                                _chatService.resumeSession(session);
                                setState(() => _sessionStarted = true);
                                WidgetsBinding.instance
                                    .addPostFrameCallback((_) => _scrollToBottom());
                              },
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ── Select a day ──────────────────────────────────────────────────────────
  void _selectDay(DateTime day) {
    if (_isSameDay(day, _selectedDay)) return;
    _messageController.clear();
    setState(() => _selectedDay = day);
    _loadSessionForDate(day);
  }

  // ── Send message ──────────────────────────────────────────────────────────
  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _chatService.isLoading) return;

    _messageController.clear();
    setState(() => _sessionStarted = true);
    await _chatService.ask(text);
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool _hasRecordingOnDay(DateTime day) {
    return _backendTranscriptDates.any((d) => _isSameDay(d, day));
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Calendar grid helpers ─────────────────────────────────────────────────
  int get _firstWeekdayOfMonth {
    return DateTime(_focusedMonth.year, _focusedMonth.month, 1).weekday % 7;
  }

  int get _daysInMonth {
    return DateTime(_focusedMonth.year, _focusedMonth.month + 1, 0).day;
  }

  void _prevMonth() {
    setState(() {
      _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month - 1);
    });
  }

  void _nextMonth() {
    setState(() {
      _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month + 1);
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final keyboardOpen = keyboardInset > 50;

    return AnimatedBuilder(
      animation: Listenable.merge([_chatService, _recorderService]),
      builder: (context, _) {
        final messages = _chatService.messages;
        final isLoading = _chatService.isLoading;

        return ColoredBox(
          color: Colors.white,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: EdgeInsets.only(bottom: keyboardInset),
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Header (hidden when keyboard open) ──────────────────────
                  if (!keyboardOpen)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const Text(
                            'Calendar',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.black,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Browse & chat with your recordings',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF94A3B8),
                            ),
                          ),
                        ],
                      ),
                    ),

                  // ── Calendar (hidden when keyboard open) ────────────────────
                  if (!keyboardOpen) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: _buildCalendar(),
                    ),
                    const SizedBox(height: 8),
                  ],

                  // ── Chat section (always Expanded) ──────────────────────────
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.grey.withValues(alpha: 0.2),
                          ),
                        ),
                        child: Column(
                          children: [
                            // Chat header
                            _buildChatHeader(),
                            const Divider(height: 1, thickness: 0.5),
                            // Messages
                            Expanded(
                              child: _loadingSessions
                                  ? const Center(
                                      child: CircularProgressIndicator(
                                        color: Color(0xFFF97316),
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : _buildMessageList(messages, isLoading),
                            ),
                            // Input bar
                            _buildInputBar(isLoading),
                          ],
                        ),
                      ),
                    ),
                  ),

                ],
              ),
            ),
          ),
        );
      },
    );
  }


  // ── Calendar widget ────────────────────────────────────────────────────────
  Widget _buildCalendar() {
    const days = ['Su', 'Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa'];
    final monthLabel = DateFormat('MMMM yyyy').format(_focusedMonth);
    final totalCells = _firstWeekdayOfMonth + _daysInMonth;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Month nav
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              GestureDetector(
                onTap: _prevMonth,
                child: const Icon(
                  Icons.chevron_left,
                  color: Colors.grey,
                  size: 22,
                ),
              ),
              Text(
                monthLabel,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: Colors.black87,
                ),
              ),
              GestureDetector(
                onTap: _nextMonth,
                child: const Icon(
                  Icons.chevron_right,
                  color: Colors.grey,
                  size: 22,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Day labels
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: days
                .map(
                  (d) => SizedBox(
                    width: 32,
                    child: Text(
                      d,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 6),
          // Date grid
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: totalCells,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 2,
              crossAxisSpacing: 0,
              mainAxisExtent: 36,
            ),
            itemBuilder: (context, index) {
              if (index < _firstWeekdayOfMonth) return const SizedBox();
              final day = index - _firstWeekdayOfMonth + 1;
              final date = DateTime(
                _focusedMonth.year,
                _focusedMonth.month,
                day,
              );
              final isSelected = _isSameDay(date, _selectedDay);
              final isToday = _isSameDay(date, DateTime.now());
              final hasRec = _hasRecordingOnDay(date);

              return GestureDetector(
                onTap: () => _selectDay(date),
                child: Container(
                  margin: const EdgeInsets.all(1),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFFF97316)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: isToday && !isSelected
                        ? Border.all(
                            color: const Color(0xFFF97316),
                            width: 1.5,
                          )
                        : null,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '$day',
                        style: TextStyle(
                          fontSize: 13,
                          color: isSelected
                              ? Colors.white
                              : isToday
                                  ? const Color(0xFFF97316)
                                  : Colors.black87,
                          fontWeight: isSelected || isToday
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                      if (hasRec)
                        Container(
                          margin: const EdgeInsets.only(top: 2),
                          width: 4,
                          height: 4,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Colors.white
                                : const Color(0xFFF97316),
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ── Chat header ────────────────────────────────────────────────────────────
  Widget _buildChatHeader() {
    final dateLabel = DateFormat('MMM d').format(_selectedDay);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF818CF8), Color(0xFFF97316)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.smart_toy_rounded,
              color: Colors.white,
              size: 16,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Ask AI — $dateLabel',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
              color: Colors.black87,
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: _showHistoryModal,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.history, size: 12, color: Colors.grey),
                  SizedBox(width: 4),
                  Text(
                    'History',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Message list ───────────────────────────────────────────────────────────
  Widget _buildMessageList(List<ChatMessage> messages, bool isLoading) {
    if (messages.isEmpty && !isLoading) {
      return _buildEmptyChat();
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      itemCount: messages.length + (isLoading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == messages.length) {
          // Loading indicator bubble
          return _buildTypingIndicator();
        }
        final msg = messages[index];
        return _buildMessageBubble(msg);
      },
    );
  }

  Widget _buildEmptyChat() {
    final hasRecordings = _hasRecordingOnDay(_selectedDay);
    final dateLabel = DateFormat('MMM d').format(_selectedDay);

    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // AI greeting bubble
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(16),
                ),
              ),
              child: Text(
                hasRecordings
                    ? 'You have recordings on $dateLabel. Ask me anything about them.'
                    : 'No recordings on $dateLabel. Select a day with recordings to chat.',
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.black87,
                  height: 1.45,
                ),
              ),
            ),
            if (hasRecordings) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _buildSuggestionChip('What did I discuss?'),
                  _buildSuggestionChip('Key action items?'),
                  _buildSuggestionChip('Give me a summary'),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSuggestionChip(String label) {
    return GestureDetector(
      onTap: () {
        _messageController.text = label;
        _sendMessage();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFFF97316).withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: const Color(0xFFF97316).withValues(alpha: 0.3),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFFF97316),
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    final isUser = msg.isUser;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[
            Container(
              width: 26,
              height: 26,
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF818CF8), Color(0xFFF97316)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.smart_toy_rounded,
                color: Colors.white,
                size: 12,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isUser ? const Color(0xFFF97316) : const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
              ),
              child: Text(
                msg.content,
                style: TextStyle(
                  fontSize: 14,
                  color: isUser ? Colors.white : Colors.black87,
                  height: 1.45,
                ),
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF818CF8), Color(0xFFF97316)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.smart_toy_rounded,
              color: Colors.white,
              size: 12,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(4),
                bottomRight: Radius.circular(16),
              ),
            ),
            child: const _TypingDots(),
          ),
        ],
      ),
    );
  }

  // ── Input bar ──────────────────────────────────────────────────────────────
  Widget _buildInputBar(bool isLoading) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(maxHeight: 100),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F9FA),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.grey.withValues(alpha: 0.15),
                ),
              ),
              child: TextField(
                controller: _messageController,
                maxLines: null,
                minLines: 1,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(fontSize: 14, color: Colors.black87),
                decoration: const InputDecoration(
                  hintText: 'Ask about your recordings…',
                  hintStyle: TextStyle(
                    color: Color(0xFFBDC7D5),
                    fontSize: 14,
                  ),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: isLoading ? null : _sendMessage,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.transparent,
                shape: BoxShape.circle,
              ),
              child: isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.grey,
                      ),
                    )
                  : const Icon(
                      Icons.send_rounded,
                      color: Color(0xFFF97316),
                      size: 20,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Animated typing dots ───────────────────────────────────────────────────────
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final offset = (i / 3);
            final t = (_controller.value + offset) % 1.0;
            final scale = 0.6 + 0.4 * (1 - (t * 2 - 1).abs().clamp(0.0, 1.0));
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Transform.scale(
                scale: scale,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.5),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
