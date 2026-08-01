/// Master LLM Virtual Machine orchestrator combining all Vaster sub-systems into a unified runtime container.
library;

// Export all sub-system domain primitives for developer convenience
export 'package:vaster_agent/vaster_agent.dart';
export 'package:vaster_agent_basic/vaster_agent_basic.dart';
export 'package:vaster_agent_manager/vaster_agent_manager.dart';
export 'package:vaster_agent_manager_advanced/vaster_agent_manager_advanced.dart';
export 'package:vaster_agent_messaging/vaster_agent_messaging.dart';
export 'package:vaster_context/vaster_context.dart';
export 'package:vaster_context_manager/vaster_context_manager.dart';
export 'package:vaster_events/vaster_events.dart';
export 'package:vaster_filesystem/vaster_filesystem.dart';
export 'package:vaster_filesystem_local/vaster_filesystem_local.dart';
export 'package:vaster_filesystem_manager/vaster_filesystem_manager.dart';
export 'package:vaster_filesystem_memory/vaster_filesystem_memory.dart';
export 'package:vaster_model/vaster_model.dart';
export 'package:vaster_resources/vaster_resources.dart';
export 'package:vaster_sandbox/vaster_sandbox.dart';
export 'package:vaster_sandbox_isolate/vaster_sandbox_isolate.dart';
export 'package:vaster_sandbox_manager/vaster_sandbox_manager.dart';
export 'package:vaster_sandbox_process/vaster_sandbox_process.dart';
export 'package:vaster_session/vaster_session.dart';
export 'package:vaster_session_manager/vaster_session_manager.dart';
export 'package:vaster_tool/vaster_tool.dart';
export 'package:vaster_tool_manager/vaster_tool_manager.dart';

// Export Master VM orchestrator types
export 'src/model_registry.dart';
export 'src/vaster_vm_engine.dart';
export 'src/vaster_vm_interface.dart';
export 'src/vm_config.dart';
