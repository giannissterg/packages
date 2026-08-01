import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_session/vaster_session.dart';
import 'session_manager_interface.dart';

/// Standard implementation of [SessionManager] managing multi-session state.
class BasicSessionManager implements SessionManager {
  final Map<String, ModelSession> _sessions = {};

  @override
  List<ModelSession> get activeSessions =>
      List.unmodifiable(_sessions.values);

  @override
  List<SessionDescriptor> get activeSessionDescriptors =>
      List.unmodifiable(_sessions.values.map((s) => s.descriptor));

  @override
  Future<ModelSession> createSession({
    required String sessionId,
    required VasterModel model,
    ContextManager? contextManager,
    Map<String, dynamic> metadata = const {},
  }) async {
    if (_sessions.containsKey(sessionId)) {
      throw StateError('Session with id "$sessionId" already exists.');
    }

    final session = BasicModelSession(
      sessionId: sessionId,
      model: model,
      contextManager: contextManager,
      metadata: metadata,
    );

    _sessions[sessionId] = session;
    return session;
  }

  @override
  ModelSession? getSession(String sessionId) {
    return _sessions[sessionId];
  }

  @override
  SessionDescriptor? getSessionDescriptor(String sessionId) {
    return _sessions[sessionId]?.descriptor;
  }

  @override
  Future<bool> closeSession(String sessionId) async {
    final session = _sessions.remove(sessionId);
    if (session != null) {
      session.clearHistory();
      return true;
    }
    return false;
  }

  @override
  Future<void> closeAllSessions() async {
    final ids = List<String>.from(_sessions.keys);
    for (final id in ids) {
      await closeSession(id);
    }
  }
}
