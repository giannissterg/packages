import 'package:vaster_agent_manager/vaster_agent_manager.dart';
import 'package:vaster_agent_messaging/vaster_agent_messaging.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_filesystem/vaster_filesystem.dart';
import 'package:vaster_filesystem_manager/vaster_filesystem_manager.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_sandbox_manager/vaster_sandbox_manager.dart';
import 'package:vaster_session_manager/vaster_session_manager.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';
import 'model_registry.dart';
import 'vm_config.dart';

/// Master interface defining the top-level LLM Virtual Machine.
abstract interface class VasterVirtualMachine {
  /// VM configuration settings.
  VMConfig get config;

  /// Active Session Manager.
  SessionManager get sessionManager;

  /// Active Context Manager.
  ContextManager get contextManager;

  /// Active Virtual Filesystem Manager.
  FileSystemManager get fileSystemManager;

  /// Active Executable Tool Manager.
  ToolManager get toolManager;

  /// Active Code Sandbox Manager.
  SandboxManager get sandboxManager;

  /// Active Multi-Agent Supervisor Manager.
  AgentManager get agentManager;

  /// Active Telemetry Event Bus.
  RuntimeEventBus get eventBus;

  /// Active Inter-Agent Messaging Hub.
  AgentMessagingHub get messagingHub;

  /// Active Resource Tracker.
  ResourceTracker get resourceTracker;

  /// Active Model Registry.
  ModelRegistry get modelRegistry;

  /// Registers a concrete [VasterModel] for a given [ModelDescriptor].
  void registerModel(ModelDescriptor descriptor, VasterModel model);

  /// Direct model prompt turn.
  Future<ModelResponse> prompt(
    String promptText, {
    VasterModel? model,
    GenerationConfig? config,
    CancellationToken? cancelToken,
  });

  /// Direct model prompt streaming.
  Stream<ModelResponseChunk> promptStream(
    String promptText, {
    VasterModel? model,
    GenerationConfig? config,
    CancellationToken? cancelToken,
  });

  /// Mounts a filesystem backend into [fileSystemManager] and bridges files to context.
  void mountFileSystem(String pathPrefix, VasterFileSystem fs);

  /// Registers an [ExecutableTool] into [toolManager].
  void registerTool(ExecutableTool tool);

  /// Registers a [CodeSandbox] into [sandboxManager] and bridges it into an [ExecutableTool].
  void registerSandbox(CodeSandbox sandbox);

  /// Creates and registers an autonomous agent in [agentManager].
  Future<VasterAgent> createAgent({
    required AgentDescriptor descriptor,
    VasterModel? model,
    String? parentAgentId,
  });

  /// Dispatches an agent task and enforces resource quotas.
  Future<AgentOutput> runAgentTask(
    AgentTask task, {
    String? agentId,
  });

  /// Shuts down VM resources cleanly.
  Future<void> shutdown();
}
