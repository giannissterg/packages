import 'package:vaster_agent_messaging/vaster_agent_messaging.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_filesystem/vaster_filesystem.dart';
import 'package:vaster_filesystem_manager/vaster_filesystem_manager.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_session_manager/vaster_session_manager.dart';

/// The VM capabilities checkpoint capture/restore actually uses (B5 —
/// the facet law): sessions, context, filesystems, inboxes, and the two
/// re-provisioning verbs. A checkpoint composes subsystem exports; its
/// type must not claim it can run agents or shut the VM down.
///
/// `restoreRuntime` is the one checkpoint operation that keeps the
/// master interface: it CONSTRUCTS a runtime, and the runtime programs
/// against the whole VM by law.
abstract interface class SnapshotHost {
  SessionManager get sessionManager;
  ContextManager get contextManager;
  FileSystemManager get fileSystemManager;
  AgentMessagingHub get messagingHub;

  Future<ModelSession> createSession({
    required String sessionId,
    ModelDescriptor? modelDescriptor,
  });

  String mountFileSystem(String pathPrefix, VasterFileSystem fs);
}
