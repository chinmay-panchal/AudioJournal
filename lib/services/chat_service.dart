import 'package:flutter/foundation.dart';
import '../models/chat_models.dart';
import 'api_service.dart';

class ChatService extends ChangeNotifier {
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;
  ChatService._internal();

  final ApiService _api = ApiService();

  // ── State ────────────────────────────────────────────────────────────────
  String? _activeSessionId;
  List<ChatMessage> _messages = [];
  bool _isLoading = false;
  String? _errorMessage;
  String? _targetDate;

  String? get activeSessionId => _activeSessionId;
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  String? get targetDate => _targetDate;

  // ---------------------------------------------------------------------------
  // Start a fresh session (call when user taps a new date)
  // ---------------------------------------------------------------------------
  void startNewSession() {
    _activeSessionId = null;
    _messages = [];
    _errorMessage = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // POST /chat/ask
  // ---------------------------------------------------------------------------
  Future<void> ask(String question) async {
    if (question.trim().isEmpty) return;

    // Optimistically add user message
    final tempUserMsg = ChatMessage(
      id: 'temp_${DateTime.now().millisecondsSinceEpoch}',
      role: 'user',
      content: question,
      createdAt: DateTime.now(),
    );
    _messages = [..._messages, tempUserMsg];
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      debugPrint('[Chat] === Sending message ===');
      debugPrint('[Chat] question: "$question"');
      debugPrint('[Chat] session_id: $_activeSessionId');
      debugPrint('[Chat] target_date: $_targetDate');
      final response = await _api.post<Map<String, dynamic>>(
        '/chat/ask',
        data: {
          'question': question,
          'session_id': _activeSessionId,
          if (_targetDate != null) 'target_date': _targetDate,
        },
      );

      final data = response.data!;
      _activeSessionId = data['session_id'] as String?;
      debugPrint('[Chat] ✅ Got response. new session_id: $_activeSessionId');

      final history = (data['history'] as List<dynamic>? ?? [])
          .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
          .toList();
      debugPrint('[Chat] History length: ${history.length}');

      _messages = history;
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      debugPrint('[Chat] ❌ ask() error: $e');
      // Remove optimistic message on failure
      _messages = _messages.where((m) => m.id != tempUserMsg.id).toList();
      _errorMessage = 'Failed to get a response. Please try again.';
      _isLoading = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------------
  // GET /chat/sessions — list past sessions (optionally by date)
  // ---------------------------------------------------------------------------
  Future<List<ChatSession>> fetchSessions({String? targetDate}) async {
    _targetDate = targetDate;
    debugPrint('[Chat] Fetching sessions with target_date: $targetDate');
    try {
      final response = await _api.get<dynamic>(
        '/chat/sessions',
        queryParameters: {
          if (targetDate != null) 'target_date': targetDate,
        },
      );

      // The endpoint returns a plain JSON array, but defensively handle
      // cases where it may be wrapped in a map (e.g. { "sessions": [...] })
      List<dynamic> list;
      final data = response.data;
      if (data is List) {
        list = data;
      } else if (data is Map) {
        if (data.containsKey('sessions')) {
          list = data['sessions'] as List<dynamic>;
        } else if (data.containsKey('data') && data['data'] is List) {
          list = data['data'] as List<dynamic>;
        } else {
          list = [];
        }
      } else {
        list = [];
      }

      final result = list
          .map((s) => ChatSession.fromJson(s as Map<String, dynamic>))
          .toList();
      debugPrint('[Chat] fetchSessions returned ${result.length} session(s)');
      return result;
    } catch (e) {
      debugPrint('[Chat] ❌ fetchSessions() error: $e');
      return [];
    }
  }


  // ---------------------------------------------------------------------------
  // Resume an existing session (loads its history into state)
  // ---------------------------------------------------------------------------
  void resumeSession(ChatSession session) {
    _activeSessionId = session.id;
    _messages = List.from(session.history);
    _errorMessage = null;
    notifyListeners();
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}
