import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_filesystem_manager/vaster_filesystem_manager.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';

import 'prompt_funnel.dart';

/// What the runtime's tool-calling loop needs from the VM — a role
/// interface (ISP: the client owns its interface, not the provider): the
/// [PromptFunnel] for typed continuation turns, the tool symbol table for
/// dispatch, the event bus for tool telemetry, and the VFS for the two
/// built-in syscalls. Nothing else — a tool loop typed as this cannot
/// create agents or shut the VM down.
///
/// [VasterVirtualMachine] implements this facet.
abstract interface class ToolLoopHost implements PromptFunnel {
  /// Active Executable Tool Manager — the linked tool symbol table.
  ToolManager get toolManager;

  /// Active Telemetry Event Bus.
  RuntimeEventBus get eventBus;

  /// Active Virtual Filesystem Manager (built-in VFS syscalls).
  FileSystemManager get fileSystemManager;
}
