import 'package:vaster_agent_manager/vaster_agent_manager.dart';
import 'package:vaster_agent_messaging/vaster_agent_messaging.dart';
import 'package:vaster_budget/vaster_budget.dart';
import 'package:vaster_context_manager/vaster_context_manager.dart';
import 'package:vaster_events/vaster_events.dart';
import 'package:vaster_filesystem/vaster_filesystem.dart';
import 'package:vaster_filesystem_manager/vaster_filesystem_manager.dart';
import 'package:vaster_instruction/vaster_instruction.dart';
import 'package:vaster_model/vaster_model.dart';
import 'package:vaster_policy/vaster_policy.dart';
import 'package:vaster_policy_engine/vaster_policy_engine.dart';
import 'package:vaster_resources/vaster_resources.dart';
import 'package:vaster_runtime/vaster_runtime.dart';
import 'package:vaster_sandbox_manager/vaster_sandbox_manager.dart';
import 'package:vaster_scheduler/vaster_scheduler.dart';
import 'package:vaster_session_manager/vaster_session_manager.dart';
import 'package:vaster_tool_manager/vaster_tool_manager.dart';
import 'model_registry.dart';
import 'program_execution_job.dart';
import 'vm_config.dart';

/// Master interface defining the top-level LLM Virtual Machine.
abstract interface class VasterVirtualMachine {
  /// VM configuration settings.
  VMConfig get config;

  /// Active Session Manager.
  SessionManager get sessionManager;

  /// Active Context Manager.
  ContextManager get contextManager;

  /// Ergonomic context-management facade over [contextManager]:
  /// inspect, add, remove, update, prioritize, pin, compress, expand.
  ContextWorkspace get contextWorkspace;

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

  /// Active Security Policy Engine.
  PolicyEngine get policyEngine;

  /// Active Instruction Scheduler.
  VasterScheduler get scheduler;

  /// Root VM Execution Budget.
  ExecutionBudget get rootBudget;

  /// Submits an ISA program to the VM for multi-pipeline time-sliced execution.
  ProgramExecutionJob submitProgram(
    VasterProgram program, {
    ExecutionPolicy? policy,
    ExecutionBudget? customBudget,
    TaskPriority priority = TaskPriority.normal,
  });

  /// Executes all submitted program jobs concurrently using instruction time-slicing.
  Future<Map<String, RuntimeState>> runScheduledJobs({int stepQuantum = 5});

  /// Registers a concrete [VasterModel] for a given [ModelDescriptor].
  void registerModel(ModelDescriptor descriptor, VasterModel model);

  /// Direct model prompt turn.
  Future<ModelResponse> prompt(
    String promptText, {
    VasterModel? model,
    GenerationConfig? config,
    CancellationToken? cancelToken,
    List<ContextCacheHint>? cacheHints,
  });

  /// Creates a new model session in [sessionManager] with an isolated ContextManager.
  Future<ModelSession> createSession({
    required String sessionId,
    ModelDescriptor? modelDescriptor,
  });

  /// Session-aware prompt turn routing through [sessionId]'s turn history and context.
  Future<ModelResponse> promptInSession(
    String sessionId,
    String promptText, {
    VasterModel? model,
    GenerationConfig? config,
    CancellationToken? cancelToken,
    List<ContextCacheHint>? cacheHints,
  });

  /// Typed continuation turn: sends a full message transcript (including
  /// `tool_use` / `tool_result` parts) plus tool definitions to the model.
  /// This is the ABI-preserving path used by the runtime's tool-calling loop.
  Future<ModelResponse> promptWithHistory(
    List<ChatMessage> messages, {
    VasterModel? model,
    List<ToolDefinition>? tools,
    GenerationConfig? config,
    CancellationToken? cancelToken,
    List<ContextCacheHint>? cacheHints,
  });

  /// Direct model prompt streaming.
  Stream<ModelResponseChunk> promptStream(
    String promptText, {
    VasterModel? model,
    GenerationConfig? config,
    CancellationToken? cancelToken,
    List<ContextCacheHint>? cacheHints,
  });

  /// Mounts a filesystem backend into [fileSystemManager] and bridges files to context.
  void mountFileSystem(String pathPrefix, VasterFileSystem fs);

  /// Registers an [ExecutableTool] into [toolManager].
  void registerTool(ExecutableTool tool);

  /// Registers a [CodeSandbox] into [sandboxManager] and bridges it into an [ExecutableTool].
  void registerSandbox(CodeSandbox sandbox);

  /// Constructs and registers a default isolate-backed [CodeSandbox] for [sandboxId]
  /// supporting [language]. This is a factory convenience so the runtime does not
  /// need to depend on concrete sandbox implementations.
  void mountSandbox(String sandboxId, SandboxLanguage language);

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
