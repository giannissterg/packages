import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_vm_api/vaster_vm_api.dart';

/// One session's durable state: its identity and full turn history.
///
/// The model name is informational (telemetry, sanity checks) — a restore
/// binds the session to the resuming VM's model, which may legitimately be a
/// different backend (record on claude, resume on a replay tape).
final class SessionSnapshot {
  final String sessionId;
  final String modelName;
  final List<ChatMessage> history;

  const SessionSnapshot({
    required this.sessionId,
    required this.modelName,
    required this.history,
  });

  /// Captures every active session of [vm].
  static List<SessionSnapshot> captureAll(SnapshotHost vm) => [
        for (final session in vm.sessionManager.activeSessions)
          SessionSnapshot(
            sessionId: session.sessionId,
            modelName: session.model.modelName,
            history: List.of(session.history),
          ),
      ];

  /// Restores this session into [vm]: the VM provisions it with its standard
  /// wiring (context manager, compressors, history projection), then the
  /// captured turns are replayed into it.
  Future<void> restoreInto(SnapshotHost vm) async {
    final session = await vm.createSession(sessionId: sessionId);
    for (final message in history) {
      session.appendMessage(message);
    }
  }

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'modelName': modelName,
        'history': [for (final m in history) m.toJson()],
      };

  factory SessionSnapshot.fromJson(Map<String, dynamic> json) => SessionSnapshot(
        sessionId: json['sessionId'] as String,
        modelName: json['modelName'] as String? ?? 'unknown',
        history: [
          for (final m in json['history'] as List? ?? const [])
            ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)),
        ],
      );
}
