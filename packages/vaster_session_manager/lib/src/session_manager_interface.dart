import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_session/vaster_session.dart';

/// Interface defining the multi-session management runtime.
abstract interface class SessionManager {
  /// Unmodifiable view of active session descriptors.
  List<SessionDescriptor> get activeSessionDescriptors;

  /// Unmodifiable view of active model sessions.
  List<ModelSession> get activeSessions;

  /// Creates a new model session.
  Future<ModelSession> createSession({
    required String sessionId,
    required VasterModel model,
    ContextManager? contextManager,
    Map<String, dynamic> metadata = const {},
  });

  /// Registers an existing [ModelSession] with [sessionId].
  void registerSession(String sessionId, ModelSession session);

  /// Retrieves an existing [ModelSession] by ID.
  ModelSession? getSession(String sessionId);

  /// Retrieves a [SessionDescriptor] by ID.
  SessionDescriptor? getSessionDescriptor(String sessionId);

  /// Closes and removes an active session by ID.
  Future<bool> closeSession(String sessionId);

  /// Closes all active sessions.
  Future<void> closeAllSessions();
}
